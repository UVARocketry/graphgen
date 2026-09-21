const lex = @import("lexer.zig");
const std = @import("std");

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

pub const Parser = struct {
    numbers: std.ArrayList(f32),
    strings: std.ArrayList(u8),
};
