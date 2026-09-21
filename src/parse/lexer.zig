const std = @import("std");
const files = @import("../fileref.zig");

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
    kwd_use,
    kwd_foreign,

    keyref,

    op_eq,

    hash,

    colon,

    at,

    op_times,
    op_div,
    op_plus,
    op_minus,
    op_gt,
    op_lt,
    op_gte,
    op_lte,

    eof,
};

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

    pub fn peekNextToken(self: *Lexer) !TokenType {
        return try self.getNextToken(null);
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
    fn eatNumber(self: *Lexer, diagnostic: ?*files.Diagnostic) !TokenType {
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
                    if (diagnostic) |d| {
                        var w = d.writer();
                        defer w.deinit();

                        try w.writer.print(
                            "Lexer error: Excess dot in floating point value!",
                            .{},
                        );
                        const word = self.file[start..self.index];
                        d.message = try w.toOwnedSlice();
                        d.from = .from(word);
                        return error.ExtraFloatingPointDot;
                    }
                }
                hasDot = true;
            }
        }

        if (Lexer.isAlpha(self.peekChar())) {
            if (diagnostic) |d| {
                var w = d.writer();
                defer w.deinit();

                try w.writer.print(
                    "Lexer error: Unexpected alphabetic character after floating point literal, this means you prolly made a mistake!",
                    .{},
                );
                const word = self.file[self.index .. self.index + 1];
                d.message = try w.toOwnedSlice();
                d.from = .from(word);
                return error.UnexpectedAlphaCharacter;
            }
        }

        const word = self.file[start..self.index];

        self.currentNumber = std.fmt.parseFloat(f32, word) catch |e| {
            if (diagnostic) |d| {
                var w = d.writer();
                defer w.deinit();

                try w.writer.print(
                    "Lexer error: Could not parse floating point value, got error {t}!",
                    .{e},
                );
                d.message = try w.toOwnedSlice();
                d.from = .from(word);
            }
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

    pub fn getNextToken(self: *Lexer, diagnostic: ?*files.Diagnostic) !TokenType {
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
            return self.getNextToken(diagnostic);
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
        } else if (char == '#') {
            _ = self.eatChar();
            return .hash;
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
        if (diagnostic) |d| {
            var w = d.writer();
            defer w.deinit();

            try w.writer.print(
                "Lexer error: Unknown character '{c}'!",
                .{self.peekChar()},
            );
            d.message = try w.toOwnedSlice();
            d.from = .from(self.file[self.index .. self.index + 1]);
        }
        return error.UnknownCharacter;
    }
    pub fn getNextTokenOptional(self: *Lexer, diagnostic: ?*files.Diagnostic) !?TokenType {
        const token = try self.getNextToken(diagnostic);
        if (token == .eof) {
            return null;
        }
        return token;
    }
};
