const std = @import("std");
const files = @import("../fileref.zig");

// pretty basic lexer in this file tbh. there are a few simplifying assumptions
// (at least for now):
//
// - no multiline strings
// - no special characters in strings

pub const TokenType = enum {
    string,
    ident,
    lparen,
    rparen,
    lbrace,
    rbrace,

    equal,
    number,

    kwd_fn,
    kwd_import,
    kwd_foreign,

    keyref,

    op_eq,

    valuerefdecl,
    nakedvalueref,

    colon,

    comma,

    at,

    op_times,
    op_div,
    op_plus,
    op_minus,
    op_gt,
    op_lt,
    op_gte,
    op_lte,

    newline,

    eof,

    pub fn isEos(self: TokenType) bool {
        return self == .eof or self == .newline;
    }

    pub fn isOp(self: TokenType) bool {
        const tag = @tagName(self);
        if (std.mem.startsWith(u8, tag, "op_")) return true;
        return false;
    }

    pub fn isKwd(self: TokenType) bool {
        const tag = @tagName(self);
        if (std.mem.startsWith(u8, tag, "kwd_")) return true;
        return false;
    }

    pub fn toOperator(self: TokenType) Operator {
        return switch (self) {
            .op_times => .times,
            .op_div => .div,
            .op_plus => .plus,
            .op_minus => .minus,
            .op_gt => .gt,
            .op_lt => .lt,
            .op_gte => .gte,
            .op_lte => .lte,
            else => unreachable,
        };
    }
};

pub const Operator = enum {
    pub const Associativity = enum {
        left_to_right,
        right_to_left,
    };
    times,
    div,
    plus,
    minus,
    gt,
    lt,
    gte,
    lte,

    pub fn associativity(op: Operator) Associativity {
        // just yoinked c's operator precedence
        // https://en.cppreference.com/c/language/operator_precedence
        return switch (op) {
            .times, .div, .plus, .minus, .gt, .lt, .gte, .lte => .left_to_right,
        };
    }
    pub fn precedenceMax() u32 {
        return 6;
    }
    pub fn precedence(op: Operator) u32 {
        // just yoinked c's operator precedence
        // https://en.cppreference.com/c/language/operator_precedence
        return switch (op) {
            .times, .div => 3,
            .plus, .minus => 4,
            .gt, .lt, .gte, .lte => 5,
        };
    }
};

comptime {
    for (std.meta.fieldNames(Operator)) |field| {
        std.debug.assert(std.meta.fieldIndex(TokenType, "op_" ++ field) != null);
    }
    for (std.meta.fieldNames(TokenType)) |field| {
        if (std.mem.eql(u8, field, "op_eq")) {
            continue;
        }
        if (std.mem.startsWith(u8, field, "op_")) {
            std.debug.assert(std.meta.fieldIndex(Operator, field[3..]) != null);
        }
    }
}

pub const FullToken = struct {
    tp: TokenType,
    currentString: ?[]const u8 = null,
    currentTokenString: []const u8 = "",
    currentNumber: ?f32 = null,
};

const Mark = struct {
    index: u32,
};

pub const LexerError = error{
    ExtraFloatingPointDot,
    UnexpectedAlphaCharacter,
    UnknownCharacter,
} || std.Io.Writer.Error || std.mem.Allocator.Error || std.fmt.ParseFloatError;

pub const Lexer = struct {
    currentString: ?[]const u8 = null,
    currentTokenString: []const u8 = "",
    currentNumber: ?f32 = null,
    file: []const u8,
    index: u32,

    pub fn init(file: []const u8) Lexer {
        return .{
            .file = file,
            .index = 0,
            .currentNumber = null,
            .currentString = null,
        };
    }

    pub fn mark(self: *const Lexer) Mark {
        return .{
            .index = self.index,
        };
    }
    pub fn stringFromMarks(self: *const Lexer, mark1: Mark, mark2: Mark) []const u8 {
        return self.file[mark1.index..mark2.index];
    }

    pub fn reset(self: *Lexer) void {
        self.index = 0;
        self.currentString = null;
        self.currentNumber = null;
        self.currentTokenString = "";
    }

    pub fn peekNextToken(self: *Lexer, diagnostic: *files.Diagnostic) LexerError!FullToken {
        const pos = self.index;
        defer self.index = pos;
        const str = self.currentString;
        defer self.currentString = str;
        const num = self.currentNumber;
        defer self.currentNumber = num;
        const tokStr = self.currentTokenString;
        defer self.currentTokenString = tokStr;

        const tp = try self.getNextToken(diagnostic);
        const realStr = self.currentString;
        const realNum = self.currentNumber;
        const realTokStr = self.currentTokenString;

        return .{
            .tp = tp,
            .currentTokenString = realTokStr,
            .currentNumber = realNum,
            .currentString = realStr,
        };
    }

    fn peekChar(self: *Lexer) u8 {
        if (self.index >= self.file.len) {
            return 0;
        }
        return self.file[self.index];
    }

    fn eatChar(self: *Lexer) u8 {
        if (self.index >= self.file.len) {
            return 0;
        }
        const ret = self.file[self.index];
        self.index += 1;
        return ret;
    }

    pub fn isAlnum(char: u8) bool {
        return Lexer.isAlpha(char) or Lexer.isNum(char);
    }

    pub fn isNum(char: u8) bool {
        if (char >= '0' and char <= '9') {
            return true;
        }
        return false;
    }

    pub fn isAlpha(char: u8) bool {
        if (char >= 'a' and char <= 'z') {
            return true;
        }
        if (char >= 'A' and char <= 'Z') {
            return true;
        }
        if (char == '_') {
            return true;
        }
        return false;
    }
    fn eatNumber(self: *Lexer, diagnostic: *files.Diagnostic) LexerError!TokenType {
        const start = self.index;

        var hasDot = false;

        std.debug.assert(Lexer.isNum(self.file[start]));
        // TODO: special chars

        // absorb starting character
        _ = self.eatChar();

        while (self.peekChar() == '.' or Lexer.isNum(self.peekChar())) {
            const ch = self.eatChar();
            if (ch == '.') {
                if (hasDot) {
                    var w = diagnostic.writer();
                    defer w.deinit();

                    try w.writer.print(
                        "Lexer error: Excess dot in floating point value!",
                        .{},
                    );
                    const word = self.file[start..self.index];
                    diagnostic.message = try w.toOwnedSlice();
                    diagnostic.from = .from(word);
                    return error.ExtraFloatingPointDot;
                }
                hasDot = true;
            }
        }

        if (Lexer.isAlpha(self.peekChar())) {
            var w = diagnostic.writer();
            defer w.deinit();

            try w.writer.print(
                "Lexer error: Unexpected alphabetic character after floating point literal, this means you prolly made a mistake!",
                .{},
            );
            const word = self.file[self.index .. self.index + 1];
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(word);
            return error.UnexpectedAlphaCharacter;
        }

        const word = self.file[start..self.index];

        self.currentNumber = std.fmt.parseFloat(f32, word) catch |e| {
            var w = diagnostic.writer();
            defer w.deinit();

            try w.writer.print(
                "Lexer error: Could not parse floating point value, got error {t}!",
                .{e},
            );
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(word);
            return e;
        };

        return .number;
    }

    fn eatString(self: *Lexer) TokenType {
        const start = self.index;

        const startChar = self.file[start];
        std.debug.assert(self.file[start] == '"' or self.file[start] == '\'');
        // TODO: special chars

        // absorb starting character
        _ = self.eatChar();

        const strStart = start + 1;

        while (self.peekChar() != startChar) {
            _ = self.eatChar();
        }
        const strEnd = self.index;
        _ = self.eatChar();

        self.currentString = self.file[strStart..strEnd];

        return .string;
    }

    fn eatWord(self: *Lexer) TokenType {
        const start = self.index;

        std.debug.assert(Lexer.isAlpha(self.file[start]));

        // absorb starting character
        _ = self.eatChar();

        while (Lexer.isAlnum(self.peekChar())) {
            _ = self.eatChar();
        }

        const word = self.file[start..self.index];

        inline for (comptime std.meta.fieldNames(TokenType)) |field| {
            const signal = "kwd_";
            if (field.len > signal.len and std.mem.eql(u8, word, field[signal.len..])) {
                return @field(TokenType, field);
            }
        }

        return .ident;
    }

    fn eatKeyref(self: *Lexer) TokenType {
        const start = self.index;

        std.debug.assert(self.file[start] == '.');

        // absorb starting character
        _ = self.eatChar();

        while (Lexer.isAlnum(self.peekChar()) or self.peekChar() == '.') {
            _ = self.eatChar();
        }

        return .keyref;
    }

    pub fn getNextToken(self: *Lexer, diagnostic: *files.Diagnostic) LexerError!TokenType {
        const char = self.peekChar();
        self.currentNumber = null;
        self.currentString = null;
        if (char == 0) {
            _ = self.eatChar();
            return TokenType.eof;
        }
        if (char == ';') {
            while (self.peekChar() != '\n' and self.peekChar() != 0) {
                _ = self.eatChar();
            }
            return .newline;
        }
        if (char == '\n') {
            const start = self.index;
            defer self.currentTokenString = self.file[start..self.index];
            _ = self.eatChar();
            return .newline;
        }
        // space chars
        if (char <= 32) {
            while (self.peekChar() <= 32) {
                _ = self.eatChar();
                if (self.peekChar() == 0) {
                    break;
                }
            }
            return self.getNextToken(diagnostic);
        }

        const start = self.index;
        defer self.currentTokenString = self.file[start..self.index];
        if (Lexer.isAlpha(char)) {
            return self.eatWord();
        } else if (char == '{') {
            _ = self.eatChar();
            return .lbrace;
        } else if (char == '}') {
            _ = self.eatChar();
            return .rbrace;
        } else if (char == '(') {
            _ = self.eatChar();
            return .lparen;
        } else if (char == ')') {
            _ = self.eatChar();
            return .rparen;
        } else if (char == ',') {
            _ = self.eatChar();
            return .comma;
        } else if (char == '!') {
            _ = self.eatChar();
            const next = self.eatChar();
            if (next != '#') {
                var w = diagnostic.writer();
                defer w.deinit();

                try w.writer.print(
                    "Lexer error: Expected a '#' after an '!' to create a naked value reference (eg !#value_name), but instead got'{c}'!",
                    .{self.peekChar()},
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(self.file[self.index .. self.index + 1]);
            }
            const realStart = self.index;
            if (!Lexer.isAlpha(self.peekChar())) {
                var w = diagnostic.writer();
                defer w.deinit();

                try w.writer.print(
                    "Lexer error: Expected an alphabetic character after a hash, instead got '{c}'!",
                    .{self.peekChar()},
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(self.file[self.index .. self.index + 1]);
            }
            _ = self.eatWord();
            self.currentString = self.file[realStart..self.index];
            return .nakedvalueref;
        } else if (char == '#') {
            _ = self.eatChar();
            const realStart = self.index;
            if (!Lexer.isAlpha(self.peekChar())) {
                var w = diagnostic.writer();
                defer w.deinit();

                try w.writer.print(
                    "Lexer error: Expected an alphabetic character after a hash, instead got '{c}'!",
                    .{self.peekChar()},
                );
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = .from(self.file[self.index .. self.index + 1]);
            }
            _ = self.eatWord();
            self.currentString = self.file[realStart..self.index];
            return .valuerefdecl;
        } else if (char == '"' or char == '\'') {
            return self.eatString();
        } else if (char == '@') {
            _ = self.eatChar();
            return .at;
        } else if (char == ':') {
            _ = self.eatChar();
            return .colon;
        } else if (char == '=') {
            _ = self.eatChar();
            return .op_eq;
        } else if (char == '*') {
            _ = self.eatChar();
            return .op_times;
        } else if (char == '/') {
            _ = self.eatChar();
            return .op_div;
        } else if (char == '+') {
            _ = self.eatChar();
            return .op_plus;
        } else if (char == '-') {
            _ = self.eatChar();
            return .op_minus;
        } else if (char == '>') {
            _ = self.eatChar();
            if (self.peekChar() == '=') {
                _ = self.eatChar();
                return .op_gte;
            }
            return .op_gt;
        } else if (char == '.') {
            return self.eatKeyref();
        } else if (char == '<') {
            _ = self.eatChar();
            if (self.peekChar() == '=') {
                _ = self.eatChar();
                return .op_lte;
            }
            return .op_lt;
        } else if (Lexer.isNum(char)) {
            return self.eatNumber(diagnostic);
        }
        var w = diagnostic.writer();
        defer w.deinit();

        try w.writer.print(
            "Lexer error: Unknown character '{c}'!",
            .{self.peekChar()},
        );
        diagnostic.message = try w.toOwnedSlice();
        diagnostic.from = .from(self.file[self.index .. self.index + 1]);

        return error.UnknownCharacter;
    }
    pub fn getNextTokenOptional(self: *Lexer, diagnostic: *files.Diagnostic) LexerError!?TokenType {
        const token = try self.getNextToken(diagnostic);
        if (token == .eof) {
            return null;
        }
        return token;
    }
};
