const std = @import("std");
const parse = @import("../parse_txt.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const t = @import("third.zig");
const s = @import("second.zig");
const first = @import("first.zig");

const Bytecode = t.Bytecode;
const Keyref = t.Keyref;
const Operation = t.Operation;
const Axis = t.PlotBytecode.Axis;
const Tables = s.Tables;
const PlotBytecode = t.PlotBytecode;

pub const SavedValue = struct {
    derivedFrom: u32,
    value: f32,
    leftFrame: u32,
    rightFrame: u32,
};

pub fn getRefFor(key: Keyref) ?u32 {
    switch (key.op) {
        .value => return null,
        .first, .selection, .get, .index, .last, .max, .mean, .min, .prev => return key.handle,
    }
}

pub const AxisFailure = error{} || Allocator.Error;

pub const FrameInfo = struct {
    frame: i32 = -1,
    value: f32 = 0.0,
};
pub const Info = struct {
    max: [32]FrameInfo = undefined,
    min: [32]FrameInfo = undefined,
    first: [32]FrameInfo = undefined,
    last: [32]FrameInfo = undefined,
};

pub fn restrictDataSeries(
    series: parse.Column,
    leftFrameLimit: u32,
    rightFrameLimit: u32,
) parse.Column {
    const newLeft = @max(leftFrameLimit, series.skip);
    const empty: parse.Column = .{
        .name = series.name,
        .skip = 0,
        .values = &.{},
    };
    if (newLeft >= series.skip + series.values.len) {
        return empty;
    }
    const leftRemoval = newLeft - series.skip;
    const shrunkenFloats = series.values[leftRemoval..];
    if (rightFrameLimit == 0 or rightFrameLimit >= newLeft + shrunkenFloats.len) {
        return .{
            .name = series.name,
            .skip = newLeft,
            .values = shrunkenFloats,
        };
    }

    if (rightFrameLimit <= newLeft) {
        return empty;
    }

    const newSize = rightFrameLimit - newLeft;
    const realFloats = shrunkenFloats[0..newSize];
    return .{
        .name = series.name,
        .skip = newLeft,
        .values = realFloats,
    };
}

pub fn getValueForRef(
    gpa: Allocator,
    key: Keyref,
    currentFrame: usize,
    tables: *const Tables,
    plot: *PlotBytecode,
    cache: *std.EnumMap(Keyref.Op, std.ArrayList(SavedValue)),
    leftFrameLimit: u32,
    rightFrameLimit: u32,
    frameInfo: Info,
) AxisFailure!f32 {
    if (key.lineReference) {
        switch (key.op) {
            .max => return frameInfo.max[key.handle].value,
            .min => return frameInfo.min[key.handle].value,
            .first => return frameInfo.first[key.handle].value,
            .last => return frameInfo.last[key.handle].value,
            .selection => {},
            .get, .index, .mean, .prev, .value => @panic("not allowed!!"),
        }
        if (key.handle == 0) {
            return try computeAxisStep(
                gpa,
                plot.x,
                currentFrame,
                tables,
                plot,
                cache,
                leftFrameLimit,
                rightFrameLimit,
                frameInfo,
            );
        } else {
            return try computeAxisStep(
                gpa,
                plot.y[key.handle - 1],
                currentFrame,
                tables,
                plot,
                cache,
                leftFrameLimit,
                rightFrameLimit,
                frameInfo,
            );
        }
    }
    const handleish = getRefFor(key);

    // key refers to a float if this is true, key.handle is an index into floats array
    if (handleish == null) {
        return tables.floats.items[key.handle];
    }

    const handle = handleish.?;

    const dataUnrestricted = plot.file.data[handle];

    const nan = std.math.nan(f32);
    if (currentFrame < dataUnrestricted.skip) {
        return nan;
    }

    const data = restrictDataSeries(dataUnrestricted, leftFrameLimit, rightFrameLimit);

    return switch (key.op) {
        .value => unreachable,
        .first => if (data.values.len == 0) nan else data.values[0],
        .last => if (data.values.len == 0) nan else data.values[data.values.len - 1],
        .get => if (currentFrame < data.skip or currentFrame - data.skip >= data.values.len) nan else data.values[currentFrame - data.skip],
        .selection => data.values[currentFrame - data.skip],
        .index => blk: {
            const index = tables.indices.items[plot.x.value.handle];
            const ret = plot.file.data[index.keyref].values[index.index];
            break :blk ret;
        },
        .max => blk: {
            const arr = cache.getPtr(.max).?;
            for (arr.items) |i| {
                if (i.derivedFrom == handle and leftFrameLimit == i.leftFrame and rightFrameLimit == i.rightFrame) {
                    break :blk i.value;
                }
            } else {
                var max: f32 = data.values[0];
                for (data.values) |v| {
                    max = @max(v, max);
                }
                const save: SavedValue = .{
                    .value = max,
                    .derivedFrom = handle,
                    .leftFrame = leftFrameLimit,
                    .rightFrame = rightFrameLimit,
                };
                try arr.append(gpa, save);
                break :blk max;
            }
        },
        .min => blk: {
            const arr = cache.getPtr(.min).?;
            for (arr.items) |i| {
                if (i.derivedFrom == handle and leftFrameLimit == i.leftFrame and rightFrameLimit == i.rightFrame) {
                    break :blk i.value;
                }
            } else {
                var min: f32 = data.values[0];
                for (data.values) |v| {
                    min = @min(v, min);
                }
                const save: SavedValue = .{
                    .value = min,
                    .derivedFrom = handle,
                    .leftFrame = leftFrameLimit,
                    .rightFrame = rightFrameLimit,
                };
                try arr.append(gpa, save);
                break :blk min;
            }
        },
        .mean => blk: {
            const arr = cache.getPtr(.mean).?;
            for (arr.items) |i| {
                if (i.derivedFrom == handle and leftFrameLimit == i.leftFrame and rightFrameLimit == i.rightFrame) {
                    break :blk i.value;
                }
            } else {
                var mean: f32 = 0.0;
                for (data.values) |v| {
                    mean += v;
                }
                mean /= @floatFromInt(data.values.len);
                const save: SavedValue = .{
                    .value = mean,
                    .derivedFrom = handle,
                    .leftFrame = leftFrameLimit,
                    .rightFrame = rightFrameLimit,
                };
                try arr.append(gpa, save);
                break :blk mean;
            }
        },
        .prev => if (currentFrame == data.skip or currentFrame - data.skip >= data.values.len) nan else data.values[currentFrame - data.skip - 1],
    };
}

pub fn applyOperation(
    gpa: Allocator,
    input: f32,
    op: Operation,
    currentFrame: usize,
    tables: *const Tables,
    plot: *PlotBytecode,
    cache: *std.EnumMap(Keyref.Op, std.ArrayList(SavedValue)),
    leftFrameLimit: u32,
    rightFrameLimit: u32,
    frameInfo: Info,
) AxisFailure!f32 {
    const applying = try getValueForRef(
        gpa,
        op.value,
        currentFrame,
        tables,
        plot,
        cache,
        leftFrameLimit,
        rightFrameLimit,
        frameInfo,
    );

    if (std.math.isNan(applying)) {
        return applying;
    }

    return switch (op.tp) {
        .le => if (input <= applying) input else std.math.nan(f32),
        .lt => if (input < applying) input else std.math.nan(f32),
        .ge => if (input >= applying) input else std.math.nan(f32),
        .gt => if (input > applying) input else std.math.nan(f32),
        .exp => @exp(input),
        .ln => @log(input),
        .sqrt => @sqrt(input),
        .abs => @abs(input),
        .pow => std.math.pow(f32, input, applying),
        .max => @max(input, applying),
        .min => @min(input, applying),
        .add => input + applying,
        .sub => input - applying,
        .mult => input * applying,
        .div => input / applying,
    };
}

pub fn computeAxisStep(
    gpa: Allocator,
    axis: Axis,
    currentFrame: usize,
    tables: *const Tables,
    plot: *PlotBytecode,
    cache: *std.EnumMap(Keyref.Op, std.ArrayList(SavedValue)),
    leftFrameLimit: u32,
    rightFrameLimit: u32,
    frameInfo: Info,
) AxisFailure!f32 {
    var value = try getValueForRef(
        gpa,
        axis.value,
        currentFrame,
        tables,
        plot,
        cache,
        leftFrameLimit,
        rightFrameLimit,
        frameInfo,
    );

    for (axis.ops) |op| {
        if (std.math.isNan(value)) {
            break;
        }
        value = try applyOperation(
            gpa,
            value,
            op,
            currentFrame,
            tables,
            plot,
            cache,
            leftFrameLimit,
            rightFrameLimit,
            frameInfo,
        );
    }
    return value;
}

pub const OutType = enum {
    bare,
    human,
    none,
};

pub fn resolveFrameFilter(
    gpa: Allocator,
    findLeft: bool,
    filter: t.PlotBytecode.Filter,
    plot: *PlotBytecode,
    tables: *const Tables,
    leftFrame: u32,
    rightFrame: u32,
    cache: *std.EnumMap(Keyref.Op, std.ArrayList(SavedValue)),
    frameInfo: Info,
) !u32 {
    const axis: Axis = .{
        .needs = .{},
        .ops = filter.ops,
        .value = filter.key,
    };

    {
        const boundFrame = if (findLeft) leftFrame else rightFrame;
        const v = try computeAxisStep(
            gpa,
            axis,
            boundFrame,
            tables,
            plot,
            cache,
            0,
            0,
            frameInfo,
        );
        // trivial case where filter doesnt do anything, return 0
        if (!std.math.isNan(v)) {
            return 0;
        }
    }

    switch (filter.hint) {
        .normal => {
            for (0..rightFrame - leftFrame) |frame| {
                const realFrame =
                    if (findLeft) leftFrame + frame else rightFrame - 1 - frame;
                const v = try computeAxisStep(
                    gpa,
                    axis,
                    realFrame,
                    tables,
                    plot,
                    cache,
                    0,
                    0,
                    frameInfo,
                );
                if (!std.math.isNan(v)) {
                    return @intCast(realFrame);
                }
            }
            if (findLeft) {
                return rightFrame;
            } else {
                return leftFrame;
            }
        },
        .spike => {
            var ready: bool = false;
            for (0..rightFrame - leftFrame) |frame| {
                const realFrame =
                    if (findLeft) leftFrame + frame else rightFrame - 1 - frame;
                const v = try computeAxisStep(
                    gpa,
                    axis,
                    realFrame,
                    tables,
                    plot,
                    cache,
                    0,
                    0,
                    frameInfo,
                );
                if (!std.math.isNan(v)) {
                    if (ready) {
                        return @intCast(realFrame);
                    }
                } else {
                    ready = true;
                }
            }
            if (findLeft) {
                return rightFrame;
            } else {
                return leftFrame;
            }
        },
        .monotonic => {
            var leftBound = leftFrame;
            var rightBound = rightFrame;
            while (leftBound < rightBound) {
                const frame = (leftBound + rightBound) / 2;
                const v = try computeAxisStep(
                    gpa,
                    axis,
                    frame,
                    tables,
                    plot,
                    cache,
                    0,
                    0,
                    frameInfo,
                );
                leftBound, rightBound = if (std.math.isNan(v)) blk: {
                    if (findLeft) {
                        if (rightBound - leftBound <= 1) {
                            return rightBound;
                        }
                        break :blk .{ frame, rightBound };
                    } else {
                        if (rightBound - leftBound <= 1) {
                            return leftBound;
                        }
                        break :blk .{ leftBound, frame };
                    }
                } else blk: {
                    if (!findLeft) {
                        if (rightBound - leftBound <= 1) {
                            return rightBound;
                        }
                        break :blk .{ frame, rightBound };
                    } else {
                        if (rightBound - leftBound <= 1) {
                            return leftBound;
                        }
                        break :blk .{ leftBound, frame };
                    }
                };
            }
            std.debug.assert(leftBound == rightBound);
            return leftBound;
        },
    }
}

pub fn resolveAnnotationValue(
    gpa: Allocator,
    value: s.Annotation.Value,
    frame: u32,
    tables: *const Tables,
    plot: *PlotBytecode,
    leftBound: u32,
    rightBound: u32,
    cache: *std.EnumMap(Keyref.Op, std.ArrayList(SavedValue)),
    frameInfo: Info,
) !f32 {
    const val = try computeAxisStep(
        gpa,
        .{
            .needs = .{},
            .ops = value.ops,
            .value = value.value,
        },
        frame,
        tables,
        plot,
        cache,
        leftBound,
        rightBound,
        frameInfo,
    );
    return val;
}

pub fn interpretBytecode(output: *Io.Writer, gpa: Allocator, bytecodes: Bytecode, outputType: OutType) !void {
    var annotationNumber: u32 = 0;
    var map: std.EnumMap(Keyref.Op, std.ArrayList(SavedValue)) = .initFull(.empty);
    defer for (&map.values) |*v| {
        v.deinit(gpa);
    };

    var frameData: [32]f32 = undefined;
    var frameInfo: Info = undefined;
    var axisNeeds: [32]Axis.Needs = undefined;

    for (bytecodes.plots, bytecodes.metadata) |*plot, *meta| {
        var maxFrame = plot.file.data[0].values.len;
        var minFrame = plot.file.data[0].skip;
        for (plot.file.data) |col| {
            minFrame = @min(col.skip, minFrame);
            maxFrame = @max(col.values.len + col.skip, maxFrame);
        }

        const xhandle = getRefFor(plot.x.value);

        const frameStartOg, const frameEndOg = if (xhandle) |r|
            .{
                plot.file.data[r].skip,
                plot.file.data[r].skip + plot.file.data[r].values.len,
            }
        else
            .{ minFrame, maxFrame };

        if (plot.y.len > frameData.len - 1) {
            return error.TooManyYValues;
        }

        const font: first.JsonFont = meta.font orelse .{};

        switch (outputType) {
            .bare, .human => try output.print(
                \\CHART
                \\SAVE:{s}
                \\TITLE:{s}
                \\x:{s}
                \\width:{}
                \\height:{}
                \\dpi:{}
                \\font.title:{}
                \\font.xlabel:{}
                \\font.ylabel:{}
                \\font.legend:{}
                \\font.tick:{}
                \\
            , .{
                meta.saveto.str,
                if (meta.title) |title| title.str else "",
                if (meta.x.title) |title| title.str else "",
                meta.width orelse 0,
                meta.height orelse 0,
                meta.dpi orelse 0,
                font.title orelse 0,
                font.xlabel orelse 0,
                font.ylabel orelse 0,
                font.legend orelse 0,
                font.tick orelse 0,
            }),
            .none => {},
        }

        switch (outputType) {
            .bare, .human => try output.print("{}\n", .{plot.y.len}),
            .none => {},
        }
        for (meta.y) |y| {
            switch (outputType) {
                .bare, .human => try output.print("y:{s}\n", .{
                    if (y.title) |title| title.str else "",
                }),
                .none => {},
            }
        }

        const leftBound = if (plot.filter.left) |filter|
            try resolveFrameFilter(
                gpa,
                true,
                filter,
                plot,
                &bytecodes.tables,
                frameStartOg,
                @intCast(frameEndOg),
                &map,
                undefined,
            )
        else
            0;

        const rightBound = if (plot.filter.right) |filter|
            try resolveFrameFilter(
                gpa,
                false,
                filter,
                plot,
                &bytecodes.tables,
                frameStartOg,
                @intCast(frameEndOg),
                &map,
                undefined,
            )
        else
            0;

        const frameStart = leftBound;
        const frameEnd = if (rightBound == 0) frameEndOg else rightBound;

        axisNeeds[0] = plot.x.needs;
        for (plot.y, 1..) |y, i| {
            axisNeeds[i] = y.needs;
            frameInfo.first[i] = .{};
            frameInfo.last[i] = .{};
            frameInfo.min[i] = .{};
            frameInfo.max[i] = .{};
        }

        var hasData: bool = false;
        frame: for (frameStart..frameEnd) |frame| {
            const x = try computeAxisStep(
                gpa,
                plot.x,
                frame,
                &bytecodes.tables,
                plot,
                &map,
                leftBound,
                rightBound,
                frameInfo,
            );
            frameData[0] = x;
            if (std.math.isNan(x)) {
                continue;
            }
            for (plot.y, 1..) |y, i| {
                const yval = try computeAxisStep(
                    gpa,
                    y,
                    frame,
                    &bytecodes.tables,
                    plot,
                    &map,
                    leftBound,
                    rightBound,
                    undefined,
                );
                if (std.math.isNan(yval)) {
                    continue :frame;
                }
                frameData[i] = yval;
            }
            for (0..plot.y.len + 1) |i| {
                const needs = axisNeeds[i];
                if (needs.first) {
                    if (!hasData) {
                        frameInfo.first[i].value = frameData[i];
                        frameInfo.first[i].frame = @intCast(frame);
                    }
                }
                if (needs.last) {
                    frameInfo.last[i].value = frameData[i];
                    frameInfo.last[i].frame = @intCast(frame);
                }
                if (needs.max) {
                    if (!hasData) {
                        frameInfo.max[i].value = frameData[i];
                        frameInfo.max[i].frame = @intCast(frame);
                    }
                    if (frameData[i] > frameInfo.max[i].value) {
                        frameInfo.max[i].value = frameData[i];
                        frameInfo.max[i].frame = @intCast(frame);
                    }
                }
                if (needs.min) {
                    if (!hasData) {
                        frameInfo.min[i].value = frameData[i];
                        frameInfo.min[i].frame = @intCast(frame);
                    }
                    if (frameData[i] < frameInfo.min[i].value) {
                        frameInfo.min[i].value = frameData[i];
                        frameInfo.min[i].frame = @intCast(frame);
                    }
                }
                switch (outputType) {
                    .bare => {
                        const bytes: []const u8 = @ptrCast(&frameData[i]);
                        _ = try output.write(bytes);
                    },
                    .human => {
                        try output.print("{}", .{frameData[i]});
                        if (i < plot.y.len) {
                            try output.print(", ", .{});
                        }
                    },
                    .none => {},
                }
            }
            hasData = true;
            switch (outputType) {
                .bare, .human => try output.print("\n", .{}),
                .none => {},
            }
        }
        try output.print("ANNOTATIONS\n{}\n", .{meta.annotations.len});
        annotations: for (meta.annotations) |an| {
            annotationNumber += 1;
            const line = an.line + 1;
            const frame: i32 = switch (an.select) {
                .first => frameInfo.first[line].frame,
                .last => frameInfo.last[line].frame,
                .max => frameInfo.max[line].frame,
                .min => frameInfo.min[line].frame,
            };
            if (frame < 0) {
                try output.print("SKIP\n", .{});
                continue;
            }
            const x = try resolveAnnotationValue(
                gpa,
                an.x,
                @intCast(frame),
                &bytecodes.tables,
                plot,
                leftBound,
                rightBound,
                &map,
                frameInfo,
            );
            if (std.math.isNan(x)) {
                try output.print("SKIP\n", .{});
                continue;
            }
            try output.print("x:{}\n", .{x});
            const y = try resolveAnnotationValue(
                gpa,
                an.y,
                @intCast(frame),
                &bytecodes.tables,
                plot,
                leftBound,
                rightBound,
                &map,
                frameInfo,
            );
            if (std.math.isNan(y)) {
                try output.print("SKIP\n", .{});
                continue;
            }
            var resolvedValues: std.ArrayList(f32) = .empty;
            defer resolvedValues.deinit(gpa);
            try resolvedValues.ensureUnusedCapacity(gpa, an.values.len);
            for (an.values) |v| {
                const val = try resolveAnnotationValue(
                    gpa,
                    v,
                    @intCast(frame),
                    &bytecodes.tables,
                    plot,
                    leftBound,
                    rightBound,
                    &map,
                    frameInfo,
                );
                if (std.math.isNan(val)) {
                    try output.print("SKIP\n", .{});

                    continue :annotations;
                }
                resolvedValues.appendAssumeCapacity(val);
            }

            try output.print("y:{}\n", .{y});
            try output.print("text:\nBEGIN\n", .{});
            var valIndex: usize = 0;
            for (an.text) |text| {
                switch (text) {
                    .text => |txt| {
                        try output.print("{s}", .{txt.str});
                    },
                    .item => |item| {
                        const val = resolvedValues.items[valIndex];
                        valIndex += 1;
                        if (item.round) |round| {
                            try output.print("{d:.[1]}", .{ val, round });
                        } else {
                            try output.print("{d}", .{val});
                        }
                    },
                }
            }
            try output.print("\nEND\n", .{});

            try output.print("type:{s}\n", .{an.type.str});
            try output.print("arrow.dx:{}\n", .{an.arrow.dx});
            try output.print("arrow.dy:{}\n", .{an.arrow.dy});
            if (an.style) |style| {
                try output.print("style.color:{s}\n", .{style.color});
                try output.print("style.fontsize:{}\n", .{style.fontsize});
                try output.print("style.bbox.boxstyle:{s}\n", .{style.bbox.boxstyle});
                try output.print("style.bbox.facecolor:{s}\n", .{style.bbox.facecolor});
                try output.print("style.bbox.alpha:{}\n", .{style.bbox.alpha});
            }
        }
        switch (outputType) {
            .bare, .human => try output.print("END\n", .{}),
            .none => {},
        }
    }
}
