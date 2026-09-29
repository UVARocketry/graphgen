const lex = @import("lexer.zig");
const bc = @import("bytecode.zig");
const std = @import("std");
const files = @import("../fileref.zig");
const Diagnostic = files.Diagnostic;
const Allocator = std.mem.Allocator;

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
pub const ScopeItem = struct {
    name: []const u8,
    tp: enum {
        function,
        valueref,
    },
};

pub const Pass1Error = error{
    MissingEndOfStatement,
    KeywordAsIdentifier,
    UnexpectedToken,
} || lex.LexerError;

pub const ParserPass1 = struct {
    lexer: lex.Lexer,
    bytecodeStream: bc.BytecodeBuilder,
    scope: std.ArrayList(ScopeItem),
    keyrefTable: std.ArrayList([]const u8),
    const Parser = ParserPass1;
    var stackSize: u32 = 0;

    fn dbgstack(self: *const Parser) void {
        _ = self;
        for (0..stackSize) |_| {
            std.debug.print("  ", .{});
        }
    }
    pub fn parseObject(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        stackSize += 1;
        defer stackSize -= 1;

        self.dbgstack();
        std.debug.print("OBJ\n", .{});

        var currentToken = try self.lexer.getNextToken(diagnostic);
        while (currentToken != .eof) {
            switch (currentToken) {
                .ident => {
                    try self.parseValue(alloc, diagnostic);
                },
                .newline => {
                    currentToken = try self.lexer.getNextToken(diagnostic);
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

    pub fn getAccessType(self: *Parser, diagnostic: *Diagnostic) Pass1Error!bc.PushTypes2.AccessType {
        stackSize += 1;
        defer stackSize -= 1;
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
            diagnostic.addRef(.{
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
            diagnostic.addRef(.{
                .staticMessage = "while parsing reference",
                .ref = .from(currentTokenStr),
            });
            return error.UnexpectedToken;
        }

        const A = bc.PushTypes2.AccessType;
        const value: A = for (@typeInfo(A).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, self.lexer.currentTokenString)) {
                break @enumFromInt(field.value);
            }
        } else {
            var w = diagnostic.writer();
            defer w.deinit();
            try w.writer.print(
                \\parse error: Unknown access type '{s}', expected one of 
            ,
                .{self.lexer.currentTokenString},
            );
            const fields = @typeInfo(A).@"enum".fields;
            try w.writer.print("'{s}'", .{fields[0].name});
            for (fields[1..]) |field| {
                try w.writer.print(", '{s}'", .{field.name});
            }
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(self.lexer.currentTokenString);
            diagnostic.addRef(.{
                .staticMessage = "while parsing reference",
                .ref = .from(currentTokenStr),
            });
            return error.UnknownAccessType;
        };

        return value;
    }

    pub fn emitValueref(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        stackSize += 1;
        defer stackSize -= 1;
        const valueRefname = self.lexer.currentString;

        const scopeIndex = for (self.scope.items, 0..) |item, i| {
            if (item.tp != .valueref) continue;
            if (std.mem.eql(u8, item.name, valueRefname)) break i;
        } else blk: {
            try self.scope.append(alloc, .{
                .name = valueRefname,
                .tp = .valueref,
            });
            break :blk self.scope.items.len - 1;
        };

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
            .start = @intCast(scopeIndex),
            .len = 0,
        });
    }

    pub fn emitFunctionCall(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        stackSize += 1;
        defer stackSize -= 1;
        const fnName = self.lexer.currentTokenString;

        const scopeIndex = for (self.scope.items, 0..) |item, i| {
            if (item.tp != .function) continue;
            if (std.mem.eql(u8, item.name, fnName)) break i;
        } else blk: {
            try self.scope.append(alloc, .{
                .name = fnName,
                .tp = .function,
            });
            break :blk self.scope.items.len - 1;
        };

        const lparen = try self.lexer.getNextToken(diagnostic);

        if (lparen != .lparen) {
            var w = diagnostic.writer();
            defer w.deinit();
            try w.writer.print(
                \\parse error: Expected a '(' after function name '{s}', instead got '{s}'
            ,
                .{ fnName, self.lexer.currentTokenString },
            );
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(self.lexer.currentTokenString);
            return error.MissingParenthese;
        }

        var argsCount: u16 = 0;

        const specialOp: bc.BytecodeOp.OpTypes =
            inline for (std.meta.fieldNames(bc.BytecodeOp.OpTypes)) |field| {
                if (std.mem.startsWith(u8, field, "sp_")) {
                    if (std.mem.eql(u8, "sp_" + fnName, field)) {
                        const op = @field(bc.BytecodeOp.OpTypes, field);
                        break op;
                    }
                }
            } else null;

        const expectedCount: ?u16 =
            if (specialOp) |op| op.argCountOf() else null;

        while (true) {
            const peek = try self.lexer.peekNextToken(diagnostic);
            if (peek.tp == .rparen) {
                break;
            }
            const startMark = self.lexer.mark();
            try self.parseBytecodeReal(
                alloc,
                lex.Operator.precedenceMax(),
                .left_to_right,
                true,
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
                try self.lexer.getNextToken(diagnostic);
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
        }
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
                .start = @intCast(scopeIndex),
                .len = 0,
            },
            .argsPassed = argsCount,
        });
    }

    pub fn emitKeyref(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        stackSize += 1;
        defer stackSize -= 1;
        const keyrefName = self.lexer.currentTokenString;

        const keyrefIndex = for (self.keyrefTable, 0..) |name, i| {
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
            .keyrefId = keyrefIndex,
        });
    }

    pub fn parseBytecodeReal(
        self: *Parser,
        alloc: Allocator,
        precedence: u32,
        associativity: lex.Operator.Associativity,
        inFunction: bool,
        diagnostic: *Diagnostic,
    ) Pass1Error!void {
        stackSize += 1;
        defer stackSize -= 1;
        const token = try self.lexer.getNextToken(diagnostic);

        switch (token) {
            .keyref => {
                try self.emitKeyref(alloc, diagnostic);
            },
            .valuerefdecl => {
                try self.emitValueref(alloc, diagnostic);
            },
            .op_minus => {
                try self.parseBytecodeReal(alloc, precedence, associativity, inFunction, diagnostic);
                try self.bytecodeStream.addOp(alloc, .{
                    .isKeyref = false,
                    .rest = .{
                        .operation = .negate,
                    },
                });
            },
            .ident => {
                try self.emitFunctionCall(alloc, diagnostic);
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
            else => unreachable,
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

        while (true) {
            const opTok = try self.lexer.peekNextToken(diagnostic);
            if (opTok.tp == .comma and inFunction) break;
            if (opTok.tp == .rparen and inFunction) break;
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
                diagnostic.addRef(.{
                    .staticMessage = "after parsing expression component",
                    .ref = .from(self.lexer.currentTokenString),
                });
            }

            const op = opTok.tp.toOperator();

            const add = switch (op.associativity()) {
                .left_to_right => 1,
                .right_to_left => 0,
            };

            if (op.precedence() + add <= precedence) {
                _ = try self.lexer.getNextToken(diagnostic);

                try self.parseBytecodeReal(
                    alloc,
                    op.precedence(),
                    op.associativity(),
                    inFunction,
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
                };

                try self.bytecodeStream.addOp(alloc, .{
                    .isKeyref = false,
                    .rest = .{
                        .operation = opReal,
                    },
                });
            }
        }
    }

    pub fn parseBytecode(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        try self.parseBytecodeReal(
            alloc,
            lex.Operator.precedenceMax(),
            .left_to_right,
            false,
            diagnostic,
        );
    }

    pub fn parseValue(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        stackSize += 1;
        defer stackSize -= 1;

        self.dbgstack();
        std.debug.print("VALUE\n", .{});

        const identName = self.lexer.currentTokenString;

        const maybeValueRef = try self.lexer.peekNextToken(diagnostic);
        if (maybeValueRef.tp == .valuerefdecl) {
            _ = try self.lexer.getNextToken(diagnostic);
            try self.scope.append(alloc, .{
                .name = self.lexer.currentString.?,
                .tp = .valueref,
            });
        }

        const token = try self.lexer.getNextToken(diagnostic);
        switch (token) {
            .string => {},
            .lbrace => {
                try self.parseObject(alloc, diagnostic);
            },
            .ident => {},
            .nakedvalueref => {},
            .equal => {},
            else => {
                if (maybeValueRef.tp == .valuerefdecl) {
                    var w = diagnostic.writer();
                    defer w.deinit();

                    try w.writer.print(
                        "parse error: Unexpected token '{s}'. Expected a string, left bracket (to start an object definition), identifier (for an enum value), a value reference ('!#name'), or an equals sign (to start an interpreted statement).",
                        .{
                            self.lexer.currentTokenString,
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
                        "parse error: Unexpected token '{s}'. Expected a string, left bracket (to start an object definition), identifier (for an enum value), a value reference ('!#name'), an equals sign (to start an interpreted statement), or a value reference declaration ('#name') followed by one of the other listed tokens.",
                        .{
                            self.lexer.currentTokenString,
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

    pub fn pass(self: *Parser, alloc: Allocator, diagnostic: *Diagnostic) Pass1Error!void {
        var currentToken = try self.lexer.getNextToken(diagnostic);
        while (currentToken != .eof) {
            std.debug.print("{t}\n", .{currentToken});
            switch (currentToken) {
                .ident => {
                    try self.parseValue(alloc, diagnostic);
                },
                .kwd_fn => {},
                .kwd_import => {},
                .kwd_foreign => {},
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
    }
};
