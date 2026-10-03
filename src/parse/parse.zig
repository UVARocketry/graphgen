const lex = @import("lexer.zig");
const bc = @import("bytecode.zig");
const std = @import("std");
const files = @import("../fileref.zig");
const Diagnostic = files.Diagnostic;
const Allocator = std.mem.Allocator;

// core idea with parsing:
//
// if it parses it will execute perfectly fine,
// this leaves keyrefs as the only potential messing up factor, and we have the
// keyref table for that

// two passes:
//
// first pass emits full bytecode for everything (it allows functions and valuerefs
// to be defined out of order so there's some cleanup passes after it finishes main
// pass)
//
// second pass emits the actual type. wait lowkey pass 2 could just be part of pass 1.
// ok, so pass 2 can only be merged with pass 1 if we disallow naming a vlaueref after
// using it. like i dont think that's a super unfair thing, it does feel like it could
// be confusing to reference a valueref before creating it, this also prevents
// recursive value referencing

// TODO: uhhh lowkey dont think we need to even emit an ast, we can just emit bytecode

/// this only applies to components *of expressions*
pub const AstType = enum {
    keyref,
    number,

    negate,
    add,
    sub,
    mult,
    div,

    gte,
    gt,
    lte,
    lt,

    func_call,

    // the axis selectors reducers (:max, :min, etc)
    selectionof,
    maxof,
    minof,
    meanof,
    firstof,
    lastof,
    prevof,

    axisref,
};

// two passes:
//
// first pass emits partial bytecode (so for function calls and bytecode refs and axis
// refs and value refs, we put in a placeholder bytecode), it also makes note of all
// available functions, their actual bytecode values, all available refs etc
//
// second pass goes over, emits the real type, also emits bytecode

// TODO: functions need a list of their parameter count, they also should have a list
// of parameter names so that we can give a nice error ("not enough params, you need
// {this} parameter").
// Also, i think we can do the cross file diagnostics without chaning FileRef at all
// bc we can just have the diagnostic engine search for which file a ptr is in and
// then do that (gg ez)
// Also, we need some way for local parsing to work while still emitting
// the global binary correctly hmmmm (this includes importing, eg
// `import "std" as std` should yield std.function() in one file
// but if another file has `import "std" as a`, it should yield
// a.function() and everything should work (maybe each function that's created has
// a rename list where each file gets a different rename)
pub const ScopeItem = struct {
    pub const Type = enum {
        function,
        valueref,

        pub fn nameFor(tp: Type) []const u8 {
            return switch (tp) {
                .function => "function",
                .valueref => "value reference",
            };
        }
    };

    bytecodeRef: ?bc.BytecodeRef,

    name: []const u8,
    tp: Type,
    /// where this thing was defined, null if it was only forward referenced
    /// (eg a call to a function that is defined further down the file)
    def: ?files.FileRef = null,
};

pub const Pass1Error = error{
    What,
    Undefined,
    TooManyParams,
    UnknownAccessType,
    ExcessArguments,
    TooFewArguments,
    MissingParenthese,
    MissingEndOfStatement,
    KeywordAsIdentifier,
    AlreadyDefined,
    UnexpectedToken,
} || lex.LexerError;

const ParseContext = enum {
    none,
    paren,
    function,

    pub fn parenAllowed(self: ParseContext) bool {
        return self == .function or self == .paren;
    }
    pub fn commaAllowed(self: ParseContext) bool {
        return self == .function;
    }
};

pub const ParserPass1 = struct {
    lexer: lex.Lexer,
    bytecodeStream: bc.BytecodeBuilder,
    scope: std.ArrayList(ScopeItem),
    keyrefTable: std.ArrayList([]const u8),
    paramNameBuf: [32][]const u8 = undefined,
    paramNames: std.ArrayList([]const u8),
    bytecodeStarts: std.ArrayList(struct {
        linemarker: files.FileRef,
        start: u32,
    }),

    const Parser = ParserPass1;

    pub fn findScopeItem(self: *const Parser, name: []const u8, tp: ScopeItem.Type) ?usize {
        const found: ?usize = for (self.scope.items, 0..) |item, i| {
            if (item.tp != tp) continue;
            if (std.mem.eql(u8, item.name, name)) break i;
        } else null;
        return found;
    }

    pub fn deinit(self: *Parser, gpa: Allocator) void {
        self.bytecodeStream.arr.deinit(gpa);
        self.scope.deinit(gpa);
        self.keyrefTable.deinit(gpa);
        self.bytecodeStarts.deinit(gpa);
    }

    /// gets the index of an item in the scope table, creating a forward
    /// reference placeholder if it doesnt exist yet
    pub fn referenceScopeItem(
        self: *Parser,
        alloc: Allocator,
        name: []const u8,
        tp: ScopeItem.Type,
    ) !u16 {
        if (self.findScopeItem(name, tp)) |i| {
            return @intCast(i);
        }
        try self.scope.append(alloc, .{
            .bytecodeRef = null,
            .name = name,
            .tp = tp,
        });
        return @intCast(self.scope.items.len - 1);
    }

    /// adds a definition to the scope table, erroring if the same thing was
    /// already defined before. returns the index of the definition
    pub fn defineScopeItem(
        self: *Parser,
        alloc: Allocator,
        name: []const u8,
        tp: ScopeItem.Type,
        def: files.FileRef,
        diagnostic: *Diagnostic,
    ) Pass1Error!u16 {
        if (self.findScopeItem(name, tp)) |i| {
            if (self.scope.items[i].def) |firstDef| {
                var w = diagnostic.writer();
                defer w.deinit();
                try w.writer.print(
                    \\parse error: {s} '{s}' has already been defined!
                ,
                    .{ tp.nameFor(), name },
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = def;
                try diagnostic.addRef(.{
                    .staticMessage = "first definition:",
                    .ref = firstDef,
                });
                return error.AlreadyDefined;
            }
            // it was forward referenced, so this definition just fills it in
            self.scope.items[i].def = def;
            return @intCast(i);
        }
        try self.scope.append(alloc, .{
            .bytecodeRef = null,
            .name = name,
            .tp = tp,
            .def = def,
        });
        return @intCast(self.scope.items.len - 1);
    }

    pub fn parseObject(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        var currentToken = try self.lexer.getNextToken(diagnostic);
        while (currentToken != .eof) {
            switch (currentToken) {
                .ident => {
                    try self.parseValue(alloc, diagnostic);
                },
                .newline => {
                    currentToken = try self.lexer.getNextToken(diagnostic);
                    continue;
                },
                .rbrace => return,
                else => {
                    const name = @tagName(currentToken);
                    if (std.mem.startsWith(u8, name, "kwd_")) {
                        var w = diagnostic.writer();
                        defer w.deinit();
                        try w.writer.print(
                            \\parse error: Expected an identifier for an object key, instead got the keyword '{s}'
                            \\  NOTE: keywords cannot be used as identifiers
                        ,
                            .{self.lexer.currentTokenString},
                        );
                        diagnostic.message = try w.toOwnedSlice();
                        diagnostic.from = .from(self.lexer.currentTokenString);
                        return error.KeywordAsIdentifier;
                    }
                    var w = diagnostic.writer();
                    defer w.deinit();
                    try w.writer.print(
                        \\parse error: Unexpected token '{s}', expected an identifier for an object key
                        \\  NOTE: keywords cannot be used as identifiers
                    ,
                        .{self.lexer.currentTokenString},
                    );
                    diagnostic.message = try w.toOwnedSlice();
                    diagnostic.from = .from(self.lexer.currentTokenString);
                    return error.UnexpectedToken;
                },
            }
            currentToken = try self.lexer.getNextToken(diagnostic);
            if (currentToken == .rbrace) {
                return;
            }
            if (currentToken != .newline and currentToken != .eof) {
                var w = diagnostic.writer();
                defer w.deinit();
                try w.writer.print(
                    "parse error: Expected a newline after finishing a statement, instead got '{s}'",
                    .{self.lexer.currentTokenString},
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(self.lexer.currentTokenString);
                return error.MissingEndOfStatement;
            }
            currentToken = try self.lexer.getNextToken(diagnostic);
        }
    }

    pub fn getAccessType(self: *Parser, diagnostic: *Diagnostic) Pass1Error!bc.BytecodeOp.PushTypes.AccessType {
        const currentTokenStr = self.lexer.currentTokenString;
        const next = try self.lexer.peekNextToken(diagnostic);
        if (next.tp != .colon) {
            return .current;
        }

        _ = try self.lexer.getNextToken(diagnostic);

        const word = try self.lexer.getNextToken(diagnostic);
        const wordStr = @tagName(word);
        const isKwd = std.mem.startsWith(u8, wordStr, "kwd_");

        if (isKwd) {
            var w = diagnostic.writer();
            defer w.deinit();
            try w.writer.print(
                \\parse error: Expected an identifier for a keyref access type (eg max, min, first, etc), instead got the keyword '{s}'
                \\  NOTE: keywords cannot be used as identifiers
            ,
                .{self.lexer.currentTokenString},
            );
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(self.lexer.currentTokenString);
            try diagnostic.addRef(.{
                .staticMessage = "while parsing reference",
                .ref = .from(currentTokenStr),
            });
            return error.KeywordAsIdentifier;
        }
        if (word != .ident) {
            var w = diagnostic.writer();
            defer w.deinit();
            try w.writer.print(
                \\parse error: Expected an identifier for a keyref access type (eg max, min, first, etc), instead got the token '{s}'
            ,
                .{self.lexer.currentTokenString},
            );
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(self.lexer.currentTokenString);
            try diagnostic.addRef(.{
                .staticMessage = "while parsing reference",
                .ref = .from(currentTokenStr),
            });
            return error.UnexpectedToken;
        }

        const A = bc.BytecodeOp.PushTypes.AccessType;
        const info_A: std.builtin.Type.Enum = @typeInfo(A).@"enum";
        const value: A = inline for (info_A.field_names, info_A.field_values) |name, value| {
            if (std.mem.eql(u8, name, self.lexer.currentTokenString)) {
                break @fromBackingInt(@intCast(value));
            }
        } else {
            var w = diagnostic.writer();
            defer w.deinit();
            try w.writer.print(
                \\parse error: Unknown access type '{s}', expected one of 
            ,
                .{self.lexer.currentTokenString},
            );
            try w.writer.print("'{s}'", .{info_A.field_names[0]});
            inline for (info_A.field_names[1..]) |name| {
                try w.writer.print(", '{s}'", .{name});
            }
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(self.lexer.currentTokenString);
            try diagnostic.addRef(.{
                .staticMessage = "while parsing reference",
                .ref = .from(currentTokenStr),
            });
            return error.UnknownAccessType;
        };

        return value;
    }

    pub fn emitValueref(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        const valueRefname = self.lexer.currentString.?;

        const scopeIndex = try self.referenceScopeItem(alloc, valueRefname, .valueref);

        const access = try self.getAccessType(diagnostic);

        try self.bytecodeStream.addOp(alloc, .{
            .isKeyref = true,
            .rest = .{
                .keyref = .{
                    .tp = .axis,
                    .rest = .{ .axis = access },
                },
            },
        });
        try self.bytecodeStream.addType(bc.BytecodeOp.PushTypes.AxisArg, alloc, .{
            .start = scopeIndex,
            .len = 0,
        });
    }

    pub fn emitFunctionCallOrParam(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        const fnName = self.lexer.currentTokenString;

        const paramIndex = for (self.paramNames.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, fnName)) break i;
        } else null;

        if (paramIndex) |param| {
            try self.bytecodeStream.addOp(alloc, .{
                .isKeyref = true,
                .rest = .{
                    .keyref = .{ .tp = .fn_arg, .rest = undefined },
                },
            });
            try self.bytecodeStream.addType(bc.BytecodeOp.PushTypes.FnArg, alloc, .{
                .argIndex = @intCast(self.paramNames.items.len - param - 1),
            });
            return;
        }

        const scopeIndex = try self.referenceScopeItem(alloc, fnName, .function);

        const lparen = try self.lexer.getNextToken(diagnostic);

        if (lparen != .lparen) {
            var w = diagnostic.writer();
            defer w.deinit();
            try w.writer.print(
                \\parse error: Expected a '(' after function name '{s}', instead got '{s}'
            ,
                .{ fnName, self.lexer.currentTokenString },
            );
            if (self.paramNames.items.len > 0) {
                try w.writer.print(
                    \\
                    \\  NOTE: Expecting a function call because '{s}' is not one of the listed parameters in the current function
                ,
                    .{fnName},
                );
            }
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(self.lexer.currentTokenString);
            try diagnostic.addRef(.{
                .staticMessage = "while parsing function call for",
                .ref = .from(fnName),
            });
            return error.MissingParenthese;
        }

        var argsCount: u16 = 0;

        const infoOpTypes = @typeInfo(bc.BytecodeOp.OpTypes).@"enum";
        const specialOp: ?bc.BytecodeOp.OpTypes =
            inline for (infoOpTypes.field_names, infoOpTypes.field_values) |name, value| {
                if (std.mem.startsWith(u8, name, "sp_")) {
                    const start = if (name.len < 3) name.len else 3;
                    if (std.mem.eql(u8, fnName, name[start..])) {
                        const op: bc.BytecodeOp.OpTypes = @fromBackingInt(@intCast(value));
                        break op;
                    }
                }
            } else null;

        const expectedCount: ?u16 =
            if (specialOp) |op| op.argCountOf() else null;

        for (0..1000) |_| {
            const peek = try self.lexer.peekNextToken(diagnostic);
            if (peek.tp == .rparen) {
                break;
            }
            const startMark = self.lexer.mark();
            _ = try self.parseBytecodeReal(
                alloc,
                lex.Operator.precedenceMax(),
                .function,
                diagnostic,
            );
            const endMark = self.lexer.mark();

            argsCount += 1;

            if (expectedCount) |exp| {
                if (argsCount > exp) {
                    var w = diagnostic.writer();
                    defer w.deinit();
                    try w.writer.print(
                        \\parse error: Too many arguments passed to builtin function '{s}', which expects {} arguments
                    ,
                        .{ fnName, exp },
                    );
                    diagnostic.message = try w.toOwnedSlice();
                    diagnostic.from = .from(
                        self.lexer.stringFromMarks(startMark, endMark),
                    );
                    return error.ExcessArguments;
                }
            }

            const next = try self.lexer.peekNextToken(diagnostic);

            if (next.tp == .rparen) {
                break;
            }
            if (next.tp == .comma) {
                _ = try self.lexer.getNextToken(diagnostic);
                continue;
            }
            if (next.tp.isEos()) {
                var w = diagnostic.writer();
                defer w.deinit();
                try w.writer.print(
                    \\parse error: Expected a ')' after function call '{s}', instead got a newline
                ,
                    .{fnName},
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(next.currentTokenString);
                return error.MissingParenthese;
            }

            var w = diagnostic.writer();
            defer w.deinit();
            try w.writer.print(
                \\parse error: Expected a ')' after function call '{s}', instead got '{s}'
            ,
                .{ fnName, next.currentTokenString },
            );
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(next.currentTokenString);
            return error.MissingParenthese;
        } else unreachable;
        // rparen
        _ = try self.lexer.getNextToken(diagnostic);

        if (expectedCount) |exp| {
            if (argsCount < exp) {
                var w = diagnostic.writer();
                defer w.deinit();
                try w.writer.print(
                    \\parse error: Too few arguments passed to builtin function '{s}', which expects {} arguments, but got {} arguments
                ,
                    .{ fnName, exp, argsCount },
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(self.lexer.currentTokenString);
                return error.TooFewArguments;
            }

            if (specialOp) |sp| {
                try self.bytecodeStream.addOp(alloc, .{
                    .isKeyref = false,
                    .rest = .{ .operation = sp },
                });
                return;
            } else unreachable;
        }

        try self.bytecodeStream.addOp(alloc, .{
            .isKeyref = false,
            .rest = .{
                .operation = .call,
            },
        });
        try self.bytecodeStream.addType(bc.BytecodeOp.OpTypes.FnCallArgs, alloc, .{
            .bytecode = .{
                .start = scopeIndex,
                .len = 0,
            },
            .argsPassed = argsCount,
        });
    }

    pub fn emitKeyref(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        const keyrefName = self.lexer.currentTokenString;

        const keyrefIndex = for (self.keyrefTable.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, keyrefName)) break i;
        } else blk: {
            try self.keyrefTable.append(alloc, keyrefName);
            break :blk self.keyrefTable.items.len - 1;
        };

        const access = try self.getAccessType(diagnostic);

        try self.bytecodeStream.addOp(alloc, .{
            .isKeyref = true,
            .rest = .{
                .keyref = .{
                    .tp = .keyref,
                    .rest = .{ .keyref = access },
                },
            },
        });
        try self.bytecodeStream.addType(bc.BytecodeOp.PushTypes.KeyrefArg, alloc, .{
            .keyrefId = @intCast(keyrefIndex),
        });
    }

    pub fn parseBytecodeReal(
        self: *Parser,
        alloc: Allocator,
        precedence: u32,
        parseContext: ParseContext,
        diagnostic: *Diagnostic,
    ) Pass1Error!bc.BytecodeRef {
        const token = try self.lexer.getNextToken(diagnostic);
        const start = self.bytecodeStream.arr.items.len;

        switch (token) {
            .keyref => {
                try self.emitKeyref(alloc, diagnostic);
            },
            .valuerefdecl => {
                try self.emitValueref(alloc, diagnostic);
            },
            .op_minus => {
                _ = try self.parseBytecodeReal(
                    alloc,
                    lex.Operator.negation.precedence(),
                    parseContext,
                    diagnostic,
                );
                try self.bytecodeStream.addOp(alloc, .{
                    .isKeyref = false,
                    .rest = .{
                        .operation = .negate,
                    },
                });
            },
            .ident => {
                try self.emitFunctionCallOrParam(alloc, diagnostic);
            },
            .number => {
                try self.bytecodeStream.addOp(alloc, .{
                    .isKeyref = true,
                    .rest = .{
                        .keyref = .{
                            .tp = .value,
                            .rest = undefined,
                        },
                    },
                });

                try self.bytecodeStream.addType(f32, alloc, self.lexer.currentNumber.?);
            },
            .lparen => {
                const lparenStr = self.lexer.currentTokenString;
                _ = try self.parseBytecodeReal(
                    alloc,
                    lex.Operator.precedenceMax(),
                    .paren,
                    diagnostic,
                );

                const rparen = try self.lexer.getNextToken(diagnostic);
                if (rparen != .rparen) {
                    var w = diagnostic.writer();
                    defer w.deinit();

                    try w.writer.print(
                        "parse error: Expected a ')' to close a '(', instead got '{s}'",
                        .{
                            self.lexer.currentTokenString,
                        },
                    );
                    diagnostic.message = try w.toOwnedSlice();
                    diagnostic.from = .from(self.lexer.currentTokenString);
                    try diagnostic.addRef(.{
                        .staticMessage = "from left parenthese",
                        .ref = .from(lparenStr),
                    });
                    return error.UnexpectedToken;
                }
            },
            else => {
                var w = diagnostic.writer();
                defer w.deinit();

                try w.writer.print(
                    "parse error: Expected something to start an expression (a keyref, a value reference, an identifier, a number, a '(', or a '-'), instead got '{s}'",
                    .{
                        self.lexer.currentTokenString,
                    },
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(self.lexer.currentTokenString);
                return error.UnexpectedToken;
            },
        }

        // 1 + 2 * 3 * 4
        //     _____
        //     _________
        // _____________
        // parseBytecodeReal:
        //  emit 1
        //  see +
        //  parseBytecodeReal:
        //      emit 2
        //      see *
        //      parseBytecodeReal:
        //          emit 3
        //          see *, exit
        //      emit *
        //      see *
        //      parseBytecodeReal
        //          emit 4
        //          EOS, exit
        //      emit *
        //  emit +
        //  exit on seeing equal precedence because left associative

        for (0..1000) |_| {
            const opTok = try self.lexer.peekNextToken(diagnostic);
            if (opTok.tp == .comma and parseContext.commaAllowed()) break;
            if (opTok.tp == .rparen and parseContext.parenAllowed()) break;
            if (opTok.tp.isEos()) break;
            if (!opTok.tp.isOp()) {
                var w = diagnostic.writer();
                defer w.deinit();

                try w.writer.print(
                    "parse error: Expected an operator or a newline while parsing expression, instead got '{s}'",
                    .{
                        opTok.currentTokenString,
                    },
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(opTok.currentTokenString);
                try diagnostic.addRef(.{
                    .staticMessage = "after parsing expression component",
                    .ref = .from(self.lexer.currentTokenString),
                });
                return error.UnexpectedToken;
            }

            const op = opTok.tp.toOperator();

            const add: u32 = switch (op.associativity()) {
                .left_to_right => 1,
                .right_to_left => 0,
            };

            if (op.precedence() + add <= precedence) {
                _ = try self.lexer.getNextToken(diagnostic);

                _ = try self.parseBytecodeReal(
                    alloc,
                    op.precedence(),
                    parseContext,
                    diagnostic,
                );

                const opReal: bc.BytecodeOp.OpTypes = switch (op) {
                    .times => .times,
                    .div => .div,
                    .plus => .plus,
                    .minus => .minus,
                    .gt => .gt,
                    .lt => .lt,
                    .gte => .gte,
                    .lte => .lte,
                    .negation => unreachable,
                };

                try self.bytecodeStream.addOp(alloc, .{
                    .isKeyref = false,
                    .rest = .{
                        .operation = opReal,
                    },
                });
            } else break;
        } else unreachable;
        const len = self.bytecodeStream.arr.items.len - start;
        return .{
            .start = @intCast(start),
            .len = @intCast(len),
        };
    }

    pub fn parseBytecode(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!bc.BytecodeRef {
        return try self.parseBytecodeReal(
            alloc,
            lex.Operator.precedenceMax(),
            .none,
            diagnostic,
        );
    }

    pub fn parseValue(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        const identName = self.lexer.currentTokenString;

        const maybeValueRef = try self.lexer.peekNextToken(diagnostic);
        const scopeIndex =
            if (maybeValueRef.tp == .valuerefdecl) blk: {
                _ = try self.lexer.getNextToken(diagnostic);
                break :blk try self.defineScopeItem(
                    alloc,
                    self.lexer.currentString.?,
                    .valueref,
                    .from(self.lexer.currentTokenString),
                    diagnostic,
                );
            } else null;

        const token = try self.lexer.getNextToken(diagnostic);
        var bytecodeRef: ?bc.BytecodeRef = null;
        switch (token) {
            .string => {},
            .op_minus => {
                const minusStr = self.lexer.currentTokenString;
                const num = try self.lexer.getNextToken(diagnostic);
                if (num != .number) {
                    var w = diagnostic.writer();
                    defer w.deinit();

                    try w.writer.print(
                        "parse error: Unexpected token '{s}'. Expected a number after a '-' (eg -0.8)",
                        .{
                            self.lexer.currentTokenString,
                        },
                    );
                    diagnostic.message = try w.toOwnedSlice();
                    diagnostic.from = .from(self.lexer.currentTokenString);
                    try diagnostic.addRef(.{
                        .staticMessage = "after",
                        .ref = .from(minusStr),
                    });
                    return error.UnexpectedToken;
                }
            },
            .lbrace => {
                try self.parseObject(alloc, diagnostic);
            },
            .number => {},
            .ident => {},
            .nakedvalueref => {},
            .op_eq => {
                try self.bytecodeStarts.append(alloc, .{
                    .start = @intCast(self.bytecodeStream.arr.items.len),
                    .linemarker = .from(identName),
                });
                bytecodeRef = try self.parseBytecode(alloc, diagnostic);
            },
            else => {
                if (maybeValueRef.tp == .valuerefdecl) {
                    var w = diagnostic.writer();
                    defer w.deinit();

                    try w.writer.print(
                        "parse error: Unexpected token '{s}'. Expected a string, left bracket (to start an object definition), identifier (for an enum value), a value reference ('!#name'), or an equals sign (to start an interpreted statement). ({t})",
                        .{
                            self.lexer.currentTokenString,
                            token,
                        },
                    );
                    diagnostic.message = try w.toOwnedSlice();
                    diagnostic.from = .from(self.lexer.currentTokenString);
                    try diagnostic.addRef(.{
                        .staticMessage = "while parsing key",
                        .ref = .from(identName),
                    });
                    return error.UnexpectedToken;
                } else {
                    var w = diagnostic.writer();
                    defer w.deinit();

                    try w.writer.print(
                        "parse error: Unexpected token '{s}'. Expected a string, left bracket (to start an object definition), identifier (for an enum value), a value reference ('!#name'), an equals sign (to start an interpreted statement), or a value reference declaration ('#name') followed by one of the other listed tokens. ({t})",
                        .{
                            self.lexer.currentTokenString,
                            token,
                        },
                    );
                    diagnostic.message = try w.toOwnedSlice();
                    diagnostic.from = .from(self.lexer.currentTokenString);
                    try diagnostic.addRef(.{
                        .staticMessage = "while parsing key",
                        .ref = .from(identName),
                    });
                    return error.UnexpectedToken;
                }
            },
        }

        if (scopeIndex) |i| {
            if (bytecodeRef) |ref| {
                self.scope.items[i].bytecodeRef = ref;
            }
        }

        const next = try self.lexer.peekNextToken(diagnostic);
        if (!next.tp.isEos()) {
            var w = diagnostic.writer();
            defer w.deinit();

            try w.writer.print(
                "parse error: Expected an end of statement (newline or end of file) after assigned value ({s}) for key '{s}', instead got '{s}'!",
                .{
                    self.lexer.currentTokenString,
                    identName,
                    next.currentTokenString,
                },
            );
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(next.currentTokenString);
            try diagnostic.addRef(.{
                .staticMessage = "while parsing key",
                .ref = .from(identName),
            });
            return error.MissingEndOfStatement;
        }
    }

    pub fn parseFunctionDefinition(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        const fnKeywordStr = self.lexer.currentTokenString;
        const name = try self.lexer.getNextToken(diagnostic);
        try self.bytecodeStarts.append(alloc, .{
            .start = @intCast(self.bytecodeStream.arr.items.len),
            .linemarker = .from(self.lexer.currentTokenString),
        });

        if (name != .ident) {
            const isKwd = std.mem.startsWith(u8, @tagName(name), "kwd_");
            var w = diagnostic.writer();
            defer w.deinit();
            if (isKwd) {
                try w.writer.print(
                    \\parse error: Expected an identifier for a function name, instead got the keyword '{s}'
                    \\  NOTE: keywords cannot be used as identifiers
                ,
                    .{self.lexer.currentTokenString},
                );
            } else {
                try w.writer.print(
                    "parse error: Expected an identifier for a function name, instead got the token '{s}'",
                    .{self.lexer.currentTokenString},
                );
            }
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(self.lexer.currentTokenString);
            try diagnostic.addRef(.{
                .staticMessage = "expected function, because of",
                .ref = .from(fnKeywordStr),
            });
            if (isKwd) {
                return error.KeywordAsIdentifier;
            }
            return error.UnexpectedToken;
        }

        const fnName = self.lexer.currentTokenString;

        const scopeIndex = try self.defineScopeItem(
            alloc,
            fnName,
            .function,
            .from(fnName),
            diagnostic,
        );

        const lparen = try self.lexer.getNextToken(diagnostic);

        if (lparen != .lparen) {
            var w = diagnostic.writer();
            defer w.deinit();
            if (lparen.isEos()) {
                try w.writer.print(
                    \\parse error: Expected a '(' after function name '{s}', instead got a newline
                    \\  NOTE: the name and its parameter list must be on the same line
                ,
                    .{fnName},
                );
            } else {
                try w.writer.print(
                    "parse error: Expected a '(' after function name '{s}', instead got '{s}'",
                    .{ fnName, self.lexer.currentTokenString },
                );
            }
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(self.lexer.currentTokenString);
            try diagnostic.addRef(.{
                .staticMessage = "while parsing function definition for ",
                .ref = .from(fnName),
            });
            return error.MissingParenthese;
        }

        var paramIndex: usize = 0;

        defer while (self.paramNames.items.len > 0) {
            _ = self.paramNames.pop();
        };

        for (0..1000) |_| {
            const next = try self.lexer.peekNextToken(diagnostic);
            if (next.tp == .rparen) {
                break;
            }

            const param = try self.lexer.getNextToken(diagnostic);
            if (param != .ident) {
                const isKwd = std.mem.startsWith(u8, @tagName(param), "kwd_");
                var w = diagnostic.writer();
                defer w.deinit();
                if (param.isEos()) {
                    try w.writer.print(
                        \\parse error: Expected an identifier for parameter {} of function '{s}', instead got a newline
                        \\  NOTE: check that the parameter list of this function is closed with a ')'
                    ,
                        .{ paramIndex + 1, fnName },
                    );
                } else if (isKwd) {
                    try w.writer.print(
                        \\parse error: Expected an identifier for parameter {} of function '{s}', instead got the keyword '{s}'
                        \\  NOTE: keywords cannot be used as identifiers
                    ,
                        .{ paramIndex + 1, fnName, self.lexer.currentTokenString },
                    );
                } else {
                    try w.writer.print(
                        "parse error: Expected an identifier for parameter {} of function '{s}', instead got the token '{s}'",
                        .{ paramIndex + 1, fnName, self.lexer.currentTokenString },
                    );
                }
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(self.lexer.currentTokenString);
                try diagnostic.addRef(.{
                    .staticMessage = "while parsing parameter list of",
                    .ref = .from(fnName),
                });
                if (isKwd) {
                    return error.KeywordAsIdentifier;
                }
                if (param.isEos()) {
                    return error.MissingParenthese;
                }
                return error.UnexpectedToken;
            }

            if (self.paramNames.unusedCapacitySlice().len == 0) {
                var w = diagnostic.writer();
                defer w.deinit();
                try w.writer.print(
                    \\parse error: Too many parameter declarations for function '{s}'
                    \\  NOTE: Maximum number of parameters is {}
                ,
                    .{ fnName, self.paramNameBuf.len },
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(self.lexer.currentTokenString);
                try diagnostic.addRef(.{
                    .staticMessage = "while parsing parameter list",
                    .ref = .from(fnName),
                });
                return error.TooManyParams;
            }

            self.paramNames.appendAssumeCapacity(self.lexer.currentTokenString);

            paramIndex += 1;

            const commaMaybe = try self.lexer.peekNextToken(diagnostic);
            if (commaMaybe.tp == .comma) {
                _ = try self.lexer.getNextToken(diagnostic);
                continue;
            }
            if (commaMaybe.tp == .rparen) {
                break;
            }

            {
                var w = diagnostic.writer();
                defer w.deinit();
                if (commaMaybe.tp.isEos()) {
                    try w.writer.print(
                        \\parse error: Expected a ',' or ')' after parameter {} of function '{s}', instead got a newline
                        \\  NOTE: check that the parameter list of this function is closed with a ')'
                    ,
                        .{ paramIndex, fnName },
                    );
                } else {
                    try w.writer.print(
                        "parse error: Expected a ',' or ')' after parameter {} of function '{s}', instead got '{s}'",
                        .{ paramIndex, fnName, commaMaybe.currentTokenString },
                    );
                }
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(commaMaybe.currentTokenString);
                try diagnostic.addRef(.{
                    .staticMessage = "while parsing parameter list",
                    .ref = .from(fnName),
                });
                if (commaMaybe.tp.isEos()) {
                    return error.MissingParenthese;
                }
                return error.UnexpectedToken;
            }
        } else unreachable;
        const rparen = try self.lexer.getNextToken(diagnostic);
        if (rparen != .rparen) {
            var w = diagnostic.writer();
            defer w.deinit();
            if (rparen.isEos()) {
                try w.writer.print(
                    \\parse error: Expected a ')' to close the parameter list of function '{s}', instead got a newline
                ,
                    .{fnName},
                );
            } else {
                try w.writer.print(
                    "parse error: Expected a ')' to close the parameter list of function '{s}', instead got '{s}'",
                    .{ fnName, self.lexer.currentTokenString },
                );
            }
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(self.lexer.currentTokenString);
            try diagnostic.addRef(.{
                .staticMessage = "while parsing function definition",
                .ref = .from(fnName),
            });
            return error.MissingParenthese;
        }

        const equal = try self.lexer.getNextToken(diagnostic);
        if (equal != .op_eq) {
            var w = diagnostic.writer();
            defer w.deinit();
            if (equal.isEos()) {
                try w.writer.print(
                    \\parse error: Expected a '=' to start the body of function '{s}', instead got a newline
                ,
                    .{fnName},
                );
            } else {
                try w.writer.print(
                    "parse error: Expected a '=' to start the body of function '{s}', instead got '{s}'",
                    .{ fnName, self.lexer.currentTokenString },
                );
            }
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(self.lexer.currentTokenString);
            try diagnostic.addRef(.{
                .staticMessage = "while parsing function definition",
                .ref = .from(fnName),
            });
            return error.UnexpectedToken;
        }

        self.scope.items[scopeIndex].bytecodeRef = try self.parseBytecode(alloc, diagnostic);
    }

    fn findClosestUsageString(self: *Parser, bytecodePos: u32) ![]const u8 {
        if (bytecodePos > self.bytecodeStream.arr.items.len) {
            return error.What;
        }

        for (self.bytecodeStarts.items, 0..) |item, i| {
            if (i + 1 > self.bytecodeStarts.items.len) return item.linemarker.str;
            if (self.bytecodeStarts.items[i + 1].start > bytecodePos) {
                return item.linemarker.str;
            }
        }
        unreachable;
    }

    pub fn pass(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!ParserPass2 {
        var currentToken = try self.lexer.getNextToken(diagnostic);
        while (currentToken != .eof) {
            switch (currentToken) {
                .ident => {
                    try self.parseValue(alloc, diagnostic);
                },
                .kwd_fn => {
                    try self.parseFunctionDefinition(alloc, diagnostic);
                },
                .kwd_import => unreachable,
                .kwd_foreign => unreachable,
                .newline => {
                    currentToken = try self.lexer.getNextToken(diagnostic);
                    continue;
                },
                else => unreachable,
            }
            currentToken = try self.lexer.getNextToken(diagnostic);
            if (currentToken != .newline and currentToken != .eof) {
                var w = diagnostic.writer();
                defer w.deinit();
                try w.writer.print(
                    "parse error: Expected a newline after finishing a statement, instead got '{s}'",
                    .{self.lexer.currentTokenString},
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(self.lexer.currentTokenString);
                return error.MissingEndOfStatement;
            }
            currentToken = try self.lexer.getNextToken(diagnostic);
        }

        // pass to ensure that all valuerefs and functions were properly defined
        for (self.scope.items) |item| {
            if (item.def == null) {
                var w = diagnostic.writer();
                defer w.deinit();
                try w.writer.print(
                    "parse error: {s} '{s}' is not defined anywhere",
                    .{ item.tp.nameFor(), item.name },
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(item.name);
                return error.Undefined;
            }
        }

        var reader: bc.BytecodeReader = .{
            .bytecode = self.bytecodeStream.arr.items,
            .pos = 0,
        };

        // pass to convert all the bytecode into actually executable
        // bytecode (aka resolve all the temporary refs that were left earlier
        // for function calls and axes). properly resolving the keyref values
        // happens later
        while (reader.pos < reader.bytecode.len) {
            const op = reader.eatOp();
            if (op.isKeyref) {
                switch (op.rest.keyref.tp) {
                    .axis => {
                        const argPos = reader.pos;
                        const T = bc.BytecodeReader.GetTypeForPush(.axis);
                        comptime std.debug.assert(T == bc.BytecodeRef);
                        const args = reader.eatPushArgs(.axis);

                        const scopeId = args.start;

                        const ref = self.scope.items[scopeId].bytecodeRef orelse {
                            var w = diagnostic.writer();
                            defer w.deinit();
                            try w.writer.print(
                                "parse error: Keyref '{s}' is not defined as a reference to bytecode!",
                                .{self.scope.items[scopeId].name},
                            );
                            diagnostic.message = try w.toOwnedSlice();
                            diagnostic.from = .from(self.scope.items[scopeId].name);
                            try diagnostic.addRef(.{
                                .staticMessage = "first definition:",
                                .ref = .from(try self.findClosestUsageString(argPos)),
                            });
                            return error.Undefined;
                        };

                        const region = self.bytecodeStream.arr.items[argPos .. argPos + @sizeOf(bc.BytecodeRef)];
                        const value: []const u8 = @ptrCast(&ref);
                        @memcpy(region, value);
                    },
                    else => {
                        reader.pos += bc.BytecodeReader.getTypeSizeForPush(op.rest.keyref.tp);
                    },
                }
            } else {
                switch (op.rest.operation) {
                    .call => {
                        const argPos = reader.pos;

                        const A = bc.BytecodeOp.OpTypes.FnCallArgs;
                        const args = reader.eatType(A);

                        const scopeId = args.bytecode.start;

                        const ref = self.scope.items[scopeId].bytecodeRef orelse unreachable;

                        const realArgPos = argPos + @bitOffsetOf(A, "bytecode");
                        comptime std.debug.assert(
                            @FieldType(A, "bytecode") == bc.BytecodeRef,
                        );

                        const region = self.bytecodeStream.arr.items[realArgPos .. realArgPos + @sizeOf(bc.BytecodeRef)];
                        const value: []const u8 = @ptrCast(&ref);
                        @memcpy(region, value);
                    },
                    else => {},
                }
            }
        }

        return undefined;
    }
};

pub const ParserPass2 = struct {
    lexer: lex.Lexer,
    bytecodePos: u32,
    scope: std.ArrayList(ScopeItem),
    keyrefTable: std.ArrayList([]const u8),
    const Parser = ParserPass2;

    pub fn pass(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        var currentToken = try self.lexer.getNextToken(diagnostic);
        while (currentToken != .eof) {
            switch (currentToken) {
                .ident => {
                    try self.parseValue(alloc, diagnostic);
                },
                .kwd_fn => {
                    try self.parseFn(alloc, diagnostic);
                },
                .kwd_import => unreachable,
                .kwd_foreign => unreachable,
                .newline => {
                    currentToken = try self.lexer.getNextToken(diagnostic);
                    continue;
                },
                else => unreachable,
            }
            currentToken = try self.lexer.getNextToken(diagnostic);
            if (currentToken != .newline and currentToken != .eof) {
                var w = diagnostic.writer();
                defer w.deinit();
                try w.writer.print(
                    "parse error: Expected a newline after finishing a statement, instead got '{s}'",
                    .{self.lexer.currentTokenString},
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(self.lexer.currentTokenString);
                return error.MissingEndOfStatement;
            }
            currentToken = try self.lexer.getNextToken(diagnostic);
        }

        for (self.scope.items) |item| {
            if (item.def == null) {
                var w = diagnostic.writer();
                defer w.deinit();
                try w.writer.print(
                    "parse error: {s} '{s}' is not defined anywhere",
                    .{ item.tp.nameFor(), item.name },
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(item.name);
                return error.Undefined;
            }
        }
    }
};
