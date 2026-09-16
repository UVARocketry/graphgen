const f = @import("../fileref.zig");
const parse = @import("../parse_txt.zig");
const second = @import("second.zig");
const first = @import("first.zig");
const FileRef = f.FileRef;
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Keyref = second.Keyref;
pub const Operation = second.Operation;

pub const PlotBytecode = struct {
    pub const Axis = struct {
        pub const Needs = packed struct(u8) {
            max: bool = false,
            min: bool = false,
            first: bool = false,
            last: bool = false,
            _: u4 = 0,
        };
        needs: Needs,
        value: Keyref,
        ops: []const Operation,
        pub fn deinit(self: *const Axis, gpa: Allocator) void {
            gpa.free(self.ops);
        }
    };

    pub const Filter = struct {
        ops: []const Operation,
        key: Keyref,
        hint: second.Filter.Hint,
        pub fn deinit(self: *const Filter, gpa: Allocator) void {
            gpa.free(self.ops);
        }
    };

    pub const Filters =
        struct {
            left: ?Filter,
            right: ?Filter,

            pub fn deinit(self: *const @This(), gpa: Allocator) void {
                if (self.left) |filter| filter.deinit(gpa);
                if (self.right) |filter| filter.deinit(gpa);
            }
        };

    file: parse.DebugFile,
    x: Axis,
    y: []const Axis,
    filter: Filters,

    pub fn deinit(self: *const PlotBytecode, gpa: Allocator) void {
        for (self.y) |y| {
            y.deinit(gpa);
        }
        gpa.free(self.y);
        self.x.deinit(gpa);

        self.filter.deinit(gpa);
    }
};

pub const PlotMetadata = struct {
    pub const Axis = struct {
        title: ?FileRef,
    };
    dpi: ?i32,
    font: ?first.JsonFont,
    title: ?FileRef,
    width: ?i32,
    height: ?i32,
    saveto: FileRef,
    x: Axis,
    y: []Axis,
    annotations: []const second.Annotation,

    pub fn deinit(self: *PlotMetadata, gpa: Allocator) void {
        gpa.free(self.y);
        for (self.annotations) |an| {
            an.deinit(gpa);
        }
        gpa.free(self.annotations);
    }
};

pub const Bytecode = struct {
    plots: []PlotBytecode,
    metadata: []PlotMetadata,
    tables: second.Tables,

    pub fn deinit(self: *Bytecode, gpa: Allocator) void {
        for (self.plots) |*plot| {
            plot.deinit(gpa);
        }
        gpa.free(self.plots);
        for (self.metadata) |*meta| {
            meta.deinit(gpa);
        }
        gpa.free(self.metadata);
        self.tables.deinit(gpa);
    }
};

pub fn convertAxisMeta(axis: second.Axis) PlotMetadata.Axis {
    return .{
        .title = axis.title,
    };
}

pub fn convertPlotMeta(gpa: Allocator, plot: second.Bytecode) !PlotMetadata {
    const x = convertAxisMeta(plot.x);

    var yvals: std.ArrayList(PlotMetadata.Axis) = .empty;
    defer yvals.deinit(gpa);

    try yvals.ensureUnusedCapacity(gpa, plot.y.len);

    for (plot.y) |y| {
        yvals.appendAssumeCapacity(convertAxisMeta(y));
    }

    var annotations: std.ArrayList(second.Annotation) = .empty;
    defer annotations.deinit(gpa);
    errdefer for (annotations.items) |i| i.deinit(gpa);

    try annotations.ensureUnusedCapacity(gpa, plot.annotations.len);

    for (plot.annotations) |a| {
        annotations.appendAssumeCapacity(try a.dupe(gpa));
    }

    return .{
        .annotations = try annotations.toOwnedSlice(gpa),
        .dpi = plot.dpi,
        .font = plot.font,
        .width = plot.width,
        .height = plot.height,
        .saveto = plot.saveto,
        .title = plot.title,
        .x = x,
        .y = try yvals.toOwnedSlice(gpa),
    };
}

pub fn setNeeds(
    thisAxis: u32,
    anValue: second.Annotation.Value,
    needs: *PlotBytecode.Axis.Needs,
) void {
    if (anValue.value.lineReference) {
        if (anValue.value.handle == thisAxis) {
            switch (anValue.value.op) {
                .first => needs.first = true,
                .max => needs.max = true,
                .min => needs.min = true,
                .last => needs.last = true,
                .selection => {},
                .value => unreachable,
                .get, .prev, .index, .mean => {
                    std.debug.panic("Invalid keyref op {t}\n", .{anValue.value.op});
                },
            }
        }
    }
}

pub fn convertAxisData(
    gpa: Allocator,
    axis: second.Axis,
    axisIndex: ?u32,
    annotations: []const second.Annotation,
) !PlotBytecode.Axis {
    const ops = try gpa.dupe(Operation, axis.ops);
    errdefer gpa.free(ops);

    var needs: PlotBytecode.Axis.Needs = .{};
    if (axisIndex) |i| {
        for (annotations) |an| {
            if (an.line + 1 == i) {
                switch (an.select) {
                    .first => needs.first = true,
                    .last => needs.last = true,
                    .max => needs.max = true,
                    .min => needs.min = true,
                }
            }
            setNeeds(i, an.x, &needs);
            setNeeds(i, an.y, &needs);
            for (an.values) |val| {
                setNeeds(i, val, &needs);
            }
        }
    }

    return .{
        .needs = needs,
        .value = axis.value,
        .ops = ops,
    };
}

pub fn convertPlotData(
    gpa: Allocator,
    plot: second.Bytecode,
) !PlotBytecode {
    const x = try convertAxisData(gpa, plot.x, 0, plot.annotations);
    errdefer x.deinit(gpa);

    var yvals: std.ArrayList(PlotBytecode.Axis) = .empty;
    defer yvals.deinit(gpa);
    errdefer for (yvals.items) |y| {
        y.deinit(gpa);
    };

    try yvals.ensureUnusedCapacity(gpa, plot.y.len);

    for (plot.y, 1..) |y, axisIndex| {
        yvals.appendAssumeCapacity(try convertAxisData(
            gpa,
            y,
            @intCast(axisIndex),
            plot.annotations,
        ));
    }

    const leftFilter: ?PlotBytecode.Filter = if (plot.leftFilter) |filter| blk: {
        const axis = try convertAxisData(gpa, .{
            .title = null,
            .value = filter.key,
            .ops = filter.convert,
        }, null, plot.annotations);
        errdefer axis.deinit(gpa);
        break :blk .{
            .key = axis.value,
            .ops = axis.ops,
            .hint = filter.hint,
        };
    } else null;
    errdefer if (leftFilter) |filter| filter.deinit(gpa);

    const rightFilter: ?PlotBytecode.Filter = if (plot.rightFilter) |filter| blk: {
        const axis = try convertAxisData(
            gpa,
            .{
                .title = null,
                .value = filter.key,
                .ops = filter.convert,
            },
            null,
            plot.annotations,
        );
        errdefer axis.deinit(gpa);
        break :blk .{
            .key = axis.value,
            .ops = axis.ops,
            .hint = filter.hint,
        };
    } else null;
    errdefer if (rightFilter) |filter| filter.deinit(gpa);

    return .{
        .filter = .{
            .left = leftFilter,
            .right = rightFilter,
        },
        .file = plot.file,
        .x = x,
        .y = try yvals.toOwnedSlice(gpa),
    };
}

pub fn compile(gpa: Allocator, info: second.BytecodeInfo) !Bytecode {
    var plots: std.ArrayList(PlotBytecode) = .empty;
    defer plots.deinit(gpa);
    errdefer for (plots.items) |*p| {
        p.deinit(gpa);
    };

    var metadata: std.ArrayList(PlotMetadata) = .empty;
    defer metadata.deinit(gpa);
    errdefer for (metadata.items) |*m| {
        m.deinit(gpa);
    };

    try plots.ensureUnusedCapacity(gpa, info.plots.len);
    try metadata.ensureUnusedCapacity(gpa, info.plots.len);

    for (info.plots) |plot| {
        plots.appendAssumeCapacity(try convertPlotData(gpa, plot));
        metadata.appendAssumeCapacity(try convertPlotMeta(gpa, plot));
    }

    const tables: second.Tables = blk: {
        const floats = try gpa.dupe(f32, info.tables.floats.items);
        errdefer gpa.free(floats);
        const indices = try gpa.dupe(second.Tables.Index, info.tables.indices.items);
        errdefer gpa.free(indices);
        break :blk .{
            .indices = .fromOwnedSlice(indices),
            .floats = .fromOwnedSlice(floats),
        };
    };

    return .{
        .plots = try plots.toOwnedSlice(gpa),
        .metadata = try metadata.toOwnedSlice(gpa),
        .tables = tables,
    };
}
