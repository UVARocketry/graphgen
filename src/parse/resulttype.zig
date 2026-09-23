const std = @import("std");
const second = @import("../passes/second.zig");
const Allocator = std.mem.Allocator;
pub const SpecialTypes = enum {
    handle,
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

pub fn HandleTo(things: []const []const u8) type {
    return struct {
        pub const special: SpecialTypes = .handle;
        pub const handleTo = things;
    };
}

pub const Graph = struct {
    pub const Filter = struct {
        const FilterSection = struct {
            value: Bytecode(true, false),
            hint: enum {
                monotonic,
                spike,
                none,
            },
        };
        left: FilterSection,
    };

    pub const Axis = struct {
        value: Bytecode(true, false),
        title: []const u8,
    };

    pub const Annotation = struct {
        line: HandleTo(&.{"y"}),
        select: enum { max, min, first, last },
        x: Bytecode(true, true),
        y: Bytecode(true, true),
        text: []const u8,
        value: Bytecode(true, true),
        arrow: Arrow,

        pub const Arrow = struct {
            dx: f32,
            dy: f32,
        };
    };
    saveto: []const u8,
    filter: Filter,
    x: Axis,
    y: []Axis,
    annotation: Annotation,
};

pub const Graphs = struct {
    use: []const u8,
    graph: []Graph,
};
