const bc = @import("../parse/bytecode.zig");
const std = @import("std");
const builtin = @import("builtin");
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
        value: []types.Bytecode,
        arrow: Arrow,
        style: ?Style = null,

        pub const Style = struct {
            color: ?[]const u8 = null,
            fontsize: ?i32 = null,
            bbox: BBox = .{},
            pub const BBox = struct {
                boxstyle: ?[]const u8 = null,
                facecolor: ?[]const u8 = null,
                alpha: ?f32 = null,
            };
        };
        pub const Arrow = struct {
            in: enum {
                pct,
                pixels,
            } = .pixels,
            dx: f32,
            dy: f32,
        };
    };

    pub const Font = struct {
        title: i32 = 0,
        xlabel: i32 = 0,
        ylabel: i32 = 0,
        legend: i32 = 0,
        tick: i32 = 0,
    };

    saveto: []const u8,
    title: []const u8 = "",
    ylabel: []const u8 = "",
    filter: Filter = .{
        .left = null,
        .right = null,
    },
    font: Font = .{},
    x: Axis,
    y: []Axis,
    skip: u32 = 0,
    annotation: []Annotation,
};

/// Frees the slices allocated by the parser. String fields point into the
/// source file and are not freed here.
pub fn deinit(alloc: Allocator, graphs: *const Graphs) void {
    for (graphs.graph) |graph| {
        alloc.free(graph.y);
        for (graph.annotation) |an| {
            alloc.free(an.value);
        }
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
fn writeAnnotationText(writer: *Io.Writer, text: []const u8, value: []const f32) !void {
    var rest = text;
    var valueI: u32 = 0;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        try writer.writeAll(rest[0..open]);
        const after = rest[open + 1 ..];
        const close = std.mem.indexOfScalar(u8, after, '}') orelse {
            try writer.writeAll(rest[open..]);
            return;
        };
        const spec = after[0..close];
        if (std.fmt.parseInt(u8, spec, 10)) |round| {
            try writer.print("{d:.[1]}", .{ value[valueI], round });
        } else |_| {
            try writer.print("{d}", .{value[valueI]});
        }
        valueI += 1;
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
    const parseStart = std.Io.Clock.awake.now(io);
    const cols = parseOut.parseDbgFile(io, gpa, pageAlloc, graphs.use, &diagnostic) catch |e| {
        if (diagnostic) |message| {
            std.log.err("Failed to parse '{s}': {s}", .{ graphs.use, message });
        }
        return e;
    };
    defer if (builtin.optimize != .fast) {
        for (cols) |*col| col.deinit(gpa);
        gpa.free(cols);
    };

    {
        const end = std.Io.Clock.awake.now(io);
        const nanos: f32 = @floatFromInt(parseStart.durationTo(end).nanoseconds);
        std.debug.print("  data fetching took {}s\n", .{nanos / 1.0e9});
    }

    // only the columns the bytecode actually references need to be part of the
    // keyref table, keeping the data file's column order
    var used: std.StringHashMapUnmanaged(void) = .empty;
    defer if (builtin.optimize != .fast) used.deinit(gpa);
    for (bytecode.keyrefNames) |name| try used.put(gpa, name, {});

    var frames: std.ArrayList(bc.Frame) = .empty;
    defer if (builtin.optimize != .fast) frames.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer if (builtin.optimize != .fast) names.deinit(gpa);

    var maxFrame: u32 = 0;
    for (cols) |col| {
        if (!used.contains(col.name)) continue;
        try frames.append(gpa, .{ .skip = col.skip, .values = col.values });
        try names.append(gpa, col.name);
        maxFrame = @max(maxFrame, col.skip + @as(u32, @intCast(col.values.len)));
    }

    for (bytecode.keyrefNames) |name| {
        const found = for (cols) |col| {
            if (std.mem.eql(u8, col.name, name)) break true;
        } else false;
        if (!found) {
            std.log.warn("Field '{s}' not found in '{s}'", .{ name, graphs.use });
        }
    }

    const renameStart = std.Io.Clock.awake.now(io);
    var renameDiagnostic: ?[]const u8 = null;
    defer if (builtin.optimize != .fast) if (renameDiagnostic) |message| gpa.free(message);
    bytecode.renameKeyrefs(gpa, names.items, &renameDiagnostic) catch |e| {
        if (renameDiagnostic) |message| {
            std.log.err("Failed to rename keyref '{s}'", .{message});
        }
        return e;
    };
    // renameKeyrefs allocates a new name table when some keyrefs are not renamed
    defer if (bytecode.keyrefNames.len != names.items.len and builtin.optimize != .fast) {
        gpa.free(bytecode.keyrefNames);
    };

    {
        const end = std.Io.Clock.awake.now(io);
        const nanos: f32 = @floatFromInt(renameStart.durationTo(end).nanoseconds);
        std.debug.print("  rename took {}s\n", .{nanos / 1.0e9});
    }

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

    const stack: []f32 = try gpa.alloc(f32, 128);
    defer gpa.free(stack);

    for (graphs.graph) |*graph| {
        if (graph.y.len > frameData.len - 1) {
            return error.TooManyYValues;
        }

        bytecode.setFilterBounds(graph.filter, stack);

        const frameStart = bytecode.store.leftFrame.orElse(0);
        // 0 (and .nil) means the right filter did not clip anything
        const rightFrame = bytecode.store.rightFrame.orElse(0);
        const frameEnd = if (rightFrame == 0) maxFrame else @min(rightFrame, maxFrame);

        switch (outputType) {
            .bare, .human => try writer.print(
                \\CHART
                \\SAVE:{s}
                \\TITLE:{s}
                \\x:{s}
                \\ylabel:{s}
                \\width:0
                \\height:0
                \\dpi:0
                \\font.title:{}
                \\font.xlabel:{}
                \\font.ylabel:{}
                \\font.legend:{}
                \\font.tick:{}
                \\
            , .{
                graph.saveto,
                graph.title,
                graph.x.title,
                graph.ylabel,
                graph.font.title,
                graph.font.xlabel,
                graph.font.ylabel,
                graph.font.legend,
                graph.font.tick,
            }),
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
        defer if (builtin.optimize != .fast) gpa.free(stats);
        @memset(stats, .{});

        const execStart = std.Io.Clock.awake.now(io);
        var frameCount: u32 = 0;

        var maxX: f32 = -std.math.inf(f32);
        var minX: f32 = std.math.inf(f32);
        var maxY: f32 = -std.math.inf(f32);
        var minY: f32 = std.math.inf(f32);
        frames: for (frameStart..frameEnd) |frame| {
            if (frame % (graph.skip + 1) != 0) continue;
            const frameNo: u32 = @intCast(frame);

            const x = bytecode.execRange(graph.x.value, frameNo, stack, 0);
            if (std.math.isNan(x)) continue;
            frameData[0] = x;

            var tempmaxY: f32 = -std.math.inf(f32);
            var tempminY: f32 = std.math.inf(f32);
            for (graph.y, 1..) |axis, i| {
                const y = bytecode.execRange(axis.value, frameNo, stack, 0);
                if (std.math.isNan(y)) continue :frames;
                tempmaxY = @max(tempmaxY, y);
                tempminY = @min(tempminY, y);
                frameData[i] = y;
            }

            maxX = @max(x, maxX);
            minX = @min(x, minX);
            maxY = @max(tempmaxY, maxY);
            minY = @min(tempminY, minY);

            frameCount += 1;

            // track the frame each annotation selects from
            for (graph.annotation, stats) |annotation, *stat| {
                const line = bytecode.execRange(annotation.line, frameNo, stack, 0);
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
                .human => try writer.print("\n", .{}),
                .none, .bare => {},
            }
        }
        switch (outputType) {
            .bare => try writer.print("\x7F\x80\xAB\xCD", .{}),
            .none, .human => {},
        }
        std.debug.print("  generated data for {} frames\n", .{frameCount});
        {
            const end = std.Io.Clock.awake.now(io);
            const nanos: f32 = @floatFromInt(execStart.durationTo(end).nanoseconds);
            std.debug.print("  frame exec took {}s\n", .{nanos / 1.0e9});
        }

        switch (outputType) {
            .bare, .human => {
                try writer.print("ANNOTATIONS\n{}\n", .{graph.annotation.len});

                outer: for (graph.annotation, stats) |annotation, stat| {
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

                    const x = bytecode.execRange(annotation.x, selectedFrame, stack, 0);
                    if (std.math.isNan(x)) {
                        try writer.print("SKIP\n", .{});
                        continue;
                    }
                    const y = bytecode.execRange(annotation.y, selectedFrame, stack, 0);
                    if (std.math.isNan(y)) {
                        try writer.print("SKIP\n", .{});
                        continue;
                    }
                    const values = try gpa.alloc(f32, annotation.value.len);
                    defer gpa.free(values);

                    for (values, annotation.value) |*value, ogVal| {
                        value.* = bytecode.execRange(ogVal, selectedFrame, stack, 0);
                        if (std.math.isNan(value.*)) {
                            try writer.print("SKIP\n", .{});
                            continue :outer;
                        }
                    }

                    try writer.print("x:{}\n", .{x});
                    try writer.print("y:{}\n", .{y});
                    try writer.print("text:\nBEGIN\n", .{});
                    try writeAnnotationText(writer, annotation.text, values);
                    try writer.print("\nEND\n", .{});
                    try writer.print("type:text\n", .{});
                    switch (annotation.arrow.in) {
                        .pixels => {
                            try writer.print("arrow.dx:{}\n", .{annotation.arrow.dx});
                            try writer.print("arrow.dy:{}\n", .{annotation.arrow.dy});
                        },
                        .pct => {
                            const rangeX = maxX - minX;
                            const rangeY = maxY - minY;
                            try writer.print("arrow.dx:{}\n", .{@round(annotation.arrow.dx / 100.0 * rangeX)});
                            try writer.print("arrow.dy:{}\n", .{@round(annotation.arrow.dy / 100.0 * rangeY)});
                        },
                    }
                    if (annotation.style) |style| {
                        if (style.color) |color| {
                            try writer.print("style.color:{s}\n", .{color});
                        }
                        if (style.fontsize) |fontsize| {
                            try writer.print("style.fontsize:{}\n", .{fontsize});
                        }
                        if (style.bbox.boxstyle) |boxstyle| {
                            try writer.print("style.bbox.boxstyle:{s}\n", .{boxstyle});
                        }
                        if (style.bbox.facecolor) |facecolor| {
                            try writer.print("style.bbox.facecolor:{s}\n", .{facecolor});
                        }
                        if (style.bbox.alpha) |alpha| {
                            try writer.print("style.bbox.alpha:{}\n", .{alpha});
                        }
                    }
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
