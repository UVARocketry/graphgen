const std = @import("std");
const f = @import("../fileref.zig");
const FileRef = f.FileRef;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const AxisValue = struct {
    key: FileRef,
    title: ?FileRef,
    conversions: []const FileRef,

    pub fn deinit(self: *const AxisValue, alloc: Allocator) void {
        alloc.free(self.conversions);
    }
};

pub const Filter = struct {
    key: FileRef,
    conversions: []const FileRef,
    hint: ?FileRef,
    pub fn deinit(self: *const Filter, alloc: Allocator) void {
        alloc.free(self.conversions);
    }

    pub fn fromish(filterish: ?JsonFilter, gpa: Allocator) !?Filter {
        if (filterish == null) return null;
        const filter = filterish.?;
        const arr = try gpa.alloc(FileRef, filter.convert.len);
        errdefer gpa.free(arr);
        for (arr, filter.convert) |*a, c| {
            a.* = .from(c);
        }
        return .{
            .key = .from(filter.key),
            .conversions = arr,
            .hint = .fromish(filter.hint),
        };
    }
};

pub const Plot = struct {
    filter: struct {
        left: ?Filter = null,
        right: ?Filter = null,
    } = .{},
    annotations: []const Annotation = &.{},
    read: FileRef,
    output: FileRef,
    title: ?FileRef,
    x: AxisValue,
    y: []AxisValue,
    width: ?i32 = null,
    height: ?i32 = null,
    font: ?JsonFont = null,
    dpi: ?i32 = null,

    pub fn deinit(self: *const Plot, gpa: Allocator) void {
        for (self.y) |y| {
            y.deinit(gpa);
        }
        gpa.free(self.y);
        self.x.deinit(gpa);
        if (self.filter.left) |filter| {
            filter.deinit(gpa);
        }
        if (self.filter.right) |filter| {
            filter.deinit(gpa);
        }
        for (self.annotations) |a| a.deinit(gpa);
        gpa.free(self.annotations);
    }
};

const JsonAxis = struct {
    key: []const u8,
    title: ?[]const u8,
    convert: ?[]const []const u8,
};

pub const JsonFont = struct {
    title: ?i32 = null,
    xlabel: ?i32 = null,
    ylabel: ?i32 = null,
    legend: ?i32 = null,
    tick: ?i32 = null,
};

const JsonFilter = struct {
    key: []const u8,
    convert: []const []const u8,
    hint: ?[]const u8 = null,
};

pub const Annotation = struct {
    pub const Value = struct {
        value: FileRef,
        convert: []const FileRef,

        pub fn deinit(self: *const Value, gpa: Allocator) void {
            gpa.free(self.convert);
        }
    };
    pub const Arrow = struct {
        dx: i32,
        dy: i32,
    };
    pub const Style = struct {
        // all these values are just gonna be forwarded to the output and
        // we do no parsing on them so we dont need to store the strings as a FileRef
        pub const BBox = struct {
            boxstyle: []const u8,
            facecolor: []const u8,
            alpha: f32,
        };
        fontsize: u32,
        color: []const u8,
        bbox: BBox,
    };

    type: FileRef,
    line: u32,
    select: FileRef,
    x: Value,
    y: Value,
    text: FileRef,
    values: []const Value,
    arrow: Arrow,
    style: ?Style,

    pub fn deinit(self: *const Annotation, gpa: Allocator) void {
        self.x.deinit(gpa);
        self.y.deinit(gpa);
        for (self.values) |v| v.deinit(gpa);
        gpa.free(self.values);
    }
};
const JsonAnnotationValue = struct {
    value: []const u8,
    convert: []const []const u8,
};
const JsonAnnotation = struct {
    const Style = struct {
        const BBox = struct {
            boxstyle: []const u8,
            facecolor: []const u8,
            alpha: f32,
        };
        fontsize: u32,
        color: []const u8,
        bbox: BBox,
    };

    type: []const u8,
    line: u32,
    select: []const u8,
    x: JsonAnnotationValue,
    y: JsonAnnotationValue,
    text: []const u8,
    values: []const JsonAnnotationValue,
    arrow: Annotation.Arrow,
    style: ?Style,
};

const JsonField = struct {
    filter: ?struct {
        left: ?JsonFilter = null,
        right: ?JsonFilter = null,
    } = null,
    font: ?JsonFont = null,
    read: []const u8,
    // deprecating this field tbh
    // realpos: []const u8,
    out: []const u8,
    x: JsonAxis,
    y: []const JsonAxis,
    title: ?[]const u8 = null,
    // ylabel: ?[]const u8 = null,
    // xlabel: ?[]const u8 = null,
    width: ?i32 = null,
    height: ?i32 = null,
    dpi: ?i32 = null,
    annotations: []const JsonAnnotation,
};

pub const PlotInfo = struct {
    plots: []Plot,

    pub fn deinit(self: *const PlotInfo, alloc: Allocator) void {
        for (self.plots) |p| {
            p.deinit(alloc);
        }
        alloc.free(self.plots);
    }
};

pub fn jsonAxisToNormal(gpa: Allocator, axis: JsonAxis) !AxisValue {
    const convert: []const FileRef = if (axis.convert) |c| blk: {
        var l: std.ArrayList(FileRef) = .empty;
        defer l.deinit(gpa);

        try l.ensureUnusedCapacity(gpa, c.len);

        for (c) |con| {
            l.appendAssumeCapacity(.from(con));
        }

        break :blk try l.toOwnedSlice(gpa);
    } else &.{};
    errdefer gpa.free(convert);

    const ret: AxisValue = .{
        .title = .fromish(axis.title),
        .key = .from(axis.key),
        .conversions = convert,
    };
    return ret;
}

pub fn parseJsonAnnotationValue(gpa: Allocator, value: JsonAnnotationValue) !Annotation.Value {
    var conversions: std.ArrayList(FileRef) = .empty;
    defer conversions.deinit(gpa);

    try conversions.ensureUnusedCapacity(gpa, value.convert.len);

    for (value.convert) |c| {
        conversions.appendAssumeCapacity(.from(c));
    }

    return .{
        .convert = try conversions.toOwnedSlice(gpa),
        .value = .from(value.value),
    };
}

pub fn compilePlotJson(gpa: Allocator, json: []const u8) !PlotInfo {
    const jsonReader = try std.json.parseFromSlice([]const JsonField, gpa, json, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
        .parse_numbers = false,
    });
    defer jsonReader.deinit();

    var plots: std.ArrayList(Plot) = .empty;
    defer plots.deinit(gpa);

    errdefer for (plots.items) |p| {
        p.deinit(gpa);
    };

    for (jsonReader.value) |p| {
        const out = p.out;

        const read = p.read;

        var yAxes: std.ArrayList(AxisValue) = .empty;
        defer yAxes.deinit(gpa);

        errdefer for (yAxes.items) |v| {
            v.deinit(gpa);
        };

        try yAxes.ensureUnusedCapacity(gpa, p.y.len);
        for (p.y) |y| {
            yAxes.appendAssumeCapacity(try jsonAxisToNormal(gpa, y));
        }

        const leftFilter: ?Filter =
            if (p.filter) |filter| try .fromish(filter.left, gpa) else null;
        errdefer if (leftFilter) |filter| filter.deinit(gpa);

        const rightFilter: ?Filter =
            if (p.filter) |filter| try .fromish(filter.right, gpa) else null;
        errdefer if (rightFilter) |filter| filter.deinit(gpa);

        const x = try jsonAxisToNormal(gpa, p.x);
        errdefer x.deinit(gpa);

        const y = try yAxes.toOwnedSlice(gpa);
        errdefer gpa.free(y);
        errdefer for (y) |v| v.deinit(gpa);

        var annotations: std.ArrayList(Annotation) = .empty;
        defer annotations.deinit(gpa);
        errdefer for (annotations.items) |item| item.deinit(gpa);

        try annotations.ensureUnusedCapacity(gpa, p.annotations.len);
        for (p.annotations) |annotation| {
            var values: std.ArrayList(Annotation.Value) = .empty;
            defer values.deinit(gpa);
            errdefer for (values.items) |item| item.deinit(gpa);

            try values.ensureUnusedCapacity(gpa, annotation.values.len);
            for (annotation.values) |value| {
                values.appendAssumeCapacity(try parseJsonAnnotationValue(gpa, value));
            }

            const ax = try parseJsonAnnotationValue(gpa, annotation.x);
            errdefer ax.deinit(gpa);
            const ay = try parseJsonAnnotationValue(gpa, annotation.y);
            errdefer ay.deinit(gpa);

            annotations.appendAssumeCapacity(.{
                .text = .from(annotation.text),
                .style = if (annotation.style) |style| .{
                    .bbox = .{
                        .boxstyle = style.bbox.boxstyle,
                        .alpha = style.bbox.alpha,
                        .facecolor = style.bbox.facecolor,
                    },
                    .fontsize = style.fontsize,
                    .color = style.color,
                } else null,
                .x = ax,
                .y = ay,
                .values = try values.toOwnedSlice(gpa),
                .arrow = annotation.arrow,
                .line = annotation.line,
                .select = .from(annotation.select),
                .type = .from(annotation.type),
            });
        }

        const plot: Plot = .{
            .annotations = try annotations.toOwnedSlice(gpa),
            .filter = .{
                .left = leftFilter,
                .right = rightFilter,
            },
            .font = p.font,
            .dpi = p.dpi,
            .width = p.width,
            .height = p.height,
            .title = .fromish(p.title),
            .output = .from(out),
            .read = .from(read),
            .x = x,
            .y = y,
        };

        try plots.append(gpa, plot);
    }

    return .{
        .plots = try plots.toOwnedSlice(gpa),
    };
}
