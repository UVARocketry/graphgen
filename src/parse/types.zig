const std = @import("std");
const second = @import("../passes/second.zig");
const Allocator = std.mem.Allocator;
pub const SpecialTypes = enum {
    bytecode,
};

pub const Bytecode = struct {
    pub const special: SpecialTypes = .bytecode;

    start: u16,
    len: u16,
};

pub const AllowedPrimitives = enum {
    float,
    bytecode,
    string,
    enumeration,
};
