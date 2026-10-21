const std = @import("std");
const second = @import("../passes/second.zig");
const Allocator = std.mem.Allocator;
pub const SpecialTypes = enum {
    bytecode,
};

pub const BytecodeHandle = enum(u16) { _ };

pub fn Bytecode(keyrefs: bool, axisrefs: bool) type {
    return struct {
        pub const special: SpecialTypes = .bytecode;
        pub const restrictions: struct {
            keyrefs: bool = keyrefs,
            axisrefs: bool = axisrefs,
        } = .{};

        start: BytecodeHandle,
        len: BytecodeHandle,
    };
}

pub const AllowedPrimitives = enum {
    float,
    bytecode,
    string,
    enumeration,
};
