const bc = @import("../parse/bytecode.zig");
const std = @import("std");
const types = @import("../parse/types.zig");
const parseOut = @import("../parse_txt.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const OutType = enum {
    bare,
    human,
    none,
};

pub const Graphs = struct {
    use: []const u8,
    graph: []Graph,
};
pub const Graph = struct {
    pub const Filter = bc.BytecodeFilter;

    pub const Axis = struct {
        value: types.Bytecode,
        title: []const u8,
    };

    pub const Annotation = struct {
        line: types.Bytecode,
        select: enum {
            max,
            min,
            first,
            last,
        },
        x: types.Bytecode,
        y: types.Bytecode,
        text: []const u8,
        value: types.Bytecode,
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
    annotation: []Annotation,
};

/// Frees the slices allocated by the parser. String fields point into the
/// source file and are not freed here.
pub fn deinit(alloc: Allocator, graphs: *const Graphs) void {
    for (graphs.graph) |graph| {
        alloc.free(graph.y);
        alloc.free(graph.annotation);
    }
    alloc.free(graphs.graph);
}

const FrameStat = struct {
    frame: i32 = -1,
    value: f32 = 0,
};

const AnnotationStats = struct {
    first: FrameStat = .{},
    last: FrameStat = .{},
    max: FrameStat = .{},
    min: FrameStat = .{},
    hasLineData: bool = false,
};

/// Renders annotation text, replacing `{N}` with the value rounded to `N`
/// decimal places (a bare `{}` is not rounded).
fn writeAnnotationText(writer: *Io.Writer, text: []const u8, value: f32) !void {
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        try writer.writeAll(rest[0..open]);
        const after = rest[open + 1 ..];
        const close = std.mem.indexOfScalar(u8, after, '}') orelse {
            try writer.writeAll(rest[open..]);
            return;
        };
        const spec = after[0..close];
        if (std.fmt.parseInt(u8, spec, 10)) |round| {
            try writer.print("{d:.[1]}", .{ value, round });
        } else |_| {
            try writer.print("{d}", .{value});
        }
        rest = after[close + 1 ..];
    }
    try writer.writeAll(rest);
}

pub fn run(
    io: Io,
    gpa: Allocator,
    pageAlloc: Allocator,
    graphs: *const Graphs,
    writer: *Io.Writer,
    bytecode: *bc.BytecodeInterpreter,
    outputType: OutType,
) !void {
    var diagnostic: ?[]const u8 = null;
    const cols = parseOut.parseDbgFile(io, gpa, pageAlloc, graphs.use, &diagnostic) catch |e| {
        if (diagnostic) |message| {
            std.log.err("Failed to parse '{s}': {s}", .{ graphs.use, message });
        }
        return e;
    };
    defer {
        for (cols) |*col| col.deinit(gpa);
        gpa.free(cols);
    }

    // only the columns the bytecode actually references need to be part of the
    // keyref table, keeping the data file's column order
    var used: std.StringHashMapUnmanaged(void) = .empty;
    defer used.deinit(gpa);
    for (bytecode.keyrefNames) |name| try used.put(gpa, name, {});

    var frames: std.ArrayList(bc.Frame) = .empty;
    defer frames.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);

    var maxFrame: u32 = 0;
    for (cols) |col| {
        if (!used.contains(col.name)) continue;
        try frames.append(gpa, .{ .skip = col.skip, .values = col.values });
        try names.append(gpa, col.name);
        maxFrame = @max(maxFrame, col.skip + @as(u32, @intCast(col.values.len)));
    }

    var renameDiagnostic: ?[]const u8 = null;
    defer if (renameDiagnostic) |message| gpa.free(message);
    bytecode.renameKeyrefs(gpa, names.items, &renameDiagnostic) catch |e| {
        if (renameDiagnostic) |message| {
            std.log.err("Failed to rename keyref '{s}'", .{message});
        }
        return e;
    };
    // renameKeyrefs allocates a new name table when some keyrefs are not renamed
    defer if (bytecode.keyrefNames.len != names.items.len) {
        gpa.free(bytecode.keyrefNames);
    };

    // keyrefs with no matching column have no data, use an empty frame so their
    // ids still line up with the (kept) names
    while (frames.items.len < bytecode.keyrefNames.len) {
        try frames.append(gpa, .{ .skip = 0, .values = &.{} });
    }

    bytecode.store.frames = frames.items;
    bytecode.store.maxFrame = maxFrame;
    bytecode.store.leftFrame = .nil;
    bytecode.store.rightFrame = .nil;

    var frameData: [32]f32 = undefined;

    for (graphs.graph) |*graph| {
        if (graph.y.len > frameData.len - 1) {
            return error.TooManyYValues;
        }

        bytecode.setFilterBounds(graph.filter);

        const frameStart = bytecode.store.leftFrame.orElse(0);
        // 0 (and .nil) means the right filter did not clip anything
        const rightFrame = bytecode.store.rightFrame.orElse(0);
        const frameEnd = if (rightFrame == 0) maxFrame else @min(rightFrame, maxFrame);

        switch (outputType) {
            .bare, .human => try writer.print(
                \\CHART
                \\SAVE:{s}
                \\TITLE:
                \\x:{s}
                \\width:0
                \\height:0
                \\dpi:0
                \\font.title:0
                \\font.xlabel:0
                \\font.ylabel:0
                \\font.legend:0
                \\font.tick:0
                \\
            , .{ graph.saveto, graph.x.title }),
            .none => {},
        }

        switch (outputType) {
            .bare, .human => try writer.print("{}\n", .{graph.y.len}),
            .none => {},
        }
        for (graph.y) |axis| {
            switch (outputType) {
                .bare, .human => try writer.print("y:{s}\n", .{axis.title}),
                .none => {},
            }
        }

        const stats = try gpa.alloc(AnnotationStats, graph.annotation.len);
        defer gpa.free(stats);
        @memset(stats, .{});

        frames: for (frameStart..frameEnd) |frame| {
            const frameNo: u32 = @intCast(frame);

            const x = try bytecode.execRange(graph.x.value, frameNo);
            if (std.math.isNan(x)) continue;
            frameData[0] = x;

            for (graph.y, 1..) |axis, i| {
                const y = try bytecode.execRange(axis.value, frameNo);
                if (std.math.isNan(y)) continue :frames;
                frameData[i] = y;
            }

            // track the frame each annotation selects from
            for (graph.annotation, stats) |annotation, *stat| {
                const line = try bytecode.execRange(annotation.line, frameNo);
                if (std.math.isNan(line)) continue;
                const current: FrameStat = .{ .frame = @intCast(frameNo), .value = line };
                if (!stat.hasLineData) {
                    stat.first = current;
                    stat.max = current;
                    stat.min = current;
                }
                stat.last = current;
                if (line > stat.max.value) stat.max = current;
                if (line < stat.min.value) stat.min = current;
                stat.hasLineData = true;
            }

            for (0..graph.y.len + 1) |i| {
                switch (outputType) {
                    .bare => {
                        const bytes: []const u8 = @ptrCast(&frameData[i]);
                        _ = try writer.write(bytes);
                    },
                    .human => {
                        try writer.print("{}", .{frameData[i]});
                        if (i < graph.y.len) {
                            try writer.print(", ", .{});
                        }
                    },
                    .none => {},
                }
            }
            switch (outputType) {
                .bare, .human => try writer.print("\n", .{}),
                .none => {},
            }
        }

        switch (outputType) {
            .bare, .human => {
                try writer.print("ANNOTATIONS\n{}\n", .{graph.annotation.len});

                for (graph.annotation, stats) |annotation, stat| {
                    const frame: i32 = switch (annotation.select) {
                        .first => stat.first.frame,
                        .last => stat.last.frame,
                        .max => stat.max.frame,
                        .min => stat.min.frame,
                    };

                    if (frame < 0) {
                        try writer.print("SKIP\n", .{});
                        continue;
                    }
                    const selectedFrame: u32 = @intCast(frame);

                    const x = try bytecode.execRange(annotation.x, selectedFrame);
                    if (std.math.isNan(x)) {
                        try writer.print("SKIP\n", .{});
                        continue;
                    }
                    const y = try bytecode.execRange(annotation.y, selectedFrame);
                    if (std.math.isNan(y)) {
                        try writer.print("SKIP\n", .{});
                        continue;
                    }
                    const value = try bytecode.execRange(annotation.value, selectedFrame);
                    if (std.math.isNan(value)) {
                        try writer.print("SKIP\n", .{});
                        continue;
                    }

                    try writer.print("x:{}\n", .{x});
                    try writer.print("y:{}\n", .{y});
                    try writer.print("text:\nBEGIN\n", .{});
                    try writeAnnotationText(writer, annotation.text, value);
                    try writer.print("\nEND\n", .{});
                    try writer.print("type:text\n", .{});
                    try writer.print("arrow.dx:{}\n", .{annotation.arrow.dx});
                    try writer.print("arrow.dy:{}\n", .{annotation.arrow.dy});
                }
            },
            .none => {},
        }

        switch (outputType) {
            .bare, .human => try writer.print("END\n", .{}),
            .none => {},
        }
    }
}
