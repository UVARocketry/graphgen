const first = @import("./first.zig");
const f = @import("../fileref.zig");
const FileRef = f.FileRef;
const Diagnostic = f.Diagnostic;
const parse = @import("../parse_txt.zig");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const mToFtConversion = "3.28084";

pub const Keyref = packed struct {
    pub const Op = enum(u8) {
        get,
        value,
        first,
        last,
        /// min value of all keys of this type
        min,
        /// max value of all keys of this type
        max,
        mean,
        prev,
        index,
        selection,
    };
    handle: u23,
    // is true when handle is a reference to an axis value, and
    // not a regular value
    lineReference: bool,
    op: Op,

    /// throws an error if the current keyref does not reference a single value (for
    /// use in annotations)
    pub fn ensureStaticValue(self: *const Keyref, str: FileRef, diagnostic: *Diagnostic) !void {
        switch (self.op) {
            .value, .first, .last, .min, .max, .selection => {},
            // technically .index and .mean DO refer to a single but i dont
            // want the hassle of lineReference and index/mean so i ignore it
            .get, .prev, .index, .mean => {
                var w = diagnostic.writer();
                try w.writer.print(
                    \\Key reference '{s}' does not refer to a single value
                    \\  NOTE: to refer to a single value, key reference must be a floating point value or end in ':first', ':last', ':min', ':max'
                    \\
                , .{str.str});
                diagnostic.from = str;
                diagnostic.message = try w.toOwnedSlice();
                return error.MultipleValueKeyReference;
            },
        }
    }
};

pub const Operation = struct {
    tp: enum {
        add,
        ln,
        exp,
        sub,
        mult,
        div,
        max,
        min,
        sqrt,
        abs,
        pow,
        ge,
        gt,
        le,
        lt,
    },
    value: Keyref,
};

pub const Axis = struct {
    value: Keyref,
    ops: []const Operation,
    title: ?FileRef,
    pub fn deinit(self: *const Axis, gpa: Allocator) void {
        gpa.free(self.ops);
    }
};

pub const Filter = struct {
    key: Keyref,
    convert: []const Operation = &.{},
    hint: Hint,

    pub const Hint = enum {
        monotonic,
        normal,
        spike,
    };

    pub fn deinit(self: *const Filter, gpa: Allocator) void {
        gpa.free(self.convert);
    }
};

pub const Annotation = struct {
    pub const Value = struct {
        value: Keyref,
        ops: []const Operation,
        pub fn deinit(self: *const Value, gpa: Allocator) void {
            gpa.free(self.ops);
        }
        pub fn dupe(self: *const Value, gpa: Allocator) !Value {
            return .{
                .value = self.value,
                .ops = try gpa.dupe(Operation, self.ops),
            };
        }
    };
    pub const Selection = enum {
        max,
        min,
        first,
        last,
    };
    pub const TextItem = union(enum) {
        pub const Value = struct {
            round: ?u8,
        };
        text: FileRef,
        item: TextItem.Value,
    };
    style: ?first.Annotation.Style,
    arrow: first.Annotation.Arrow,
    type: FileRef,
    line: u32,
    select: Selection,
    x: Value,
    y: Value,
    text: []const TextItem,
    values: []const Value,

    pub fn deinit(self: *const Annotation, gpa: Allocator) void {
        self.x.deinit(gpa);
        self.y.deinit(gpa);
        for (self.values) |v| v.deinit(gpa);
        gpa.free(self.values);
        gpa.free(self.text);
    }
    pub fn dupe(self: *const Annotation, gpa: Allocator) !Annotation {
        const x = try self.x.dupe(gpa);
        errdefer x.deinit(gpa);

        const y = try self.y.dupe(gpa);
        errdefer y.deinit(gpa);

        const text = try gpa.dupe(TextItem, self.text);
        errdefer gpa.free(text);

        var values: std.ArrayList(Value) = .empty;
        defer values.deinit(gpa);
        errdefer for (values.items) |i| i.deinit(gpa);

        try values.ensureUnusedCapacity(gpa, self.values.len);

        for (self.values) |v| {
            const val = try v.dupe(gpa);
            errdefer val.deinit(gpa);
            values.appendAssumeCapacity(val);
        }

        const ret: Annotation = .{
            .x = x,
            .y = y,
            .text = text,
            .style = self.style,
            .arrow = self.arrow,
            .type = self.type,
            .line = self.line,
            .select = self.select,
            .values = try values.toOwnedSlice(gpa),
        };
        return ret;
    }
};

pub const Bytecode = struct {
    file: parse.DebugFile,
    saveto: FileRef,
    title: ?FileRef,
    width: ?i32,
    height: ?i32,
    dpi: ?i32,
    font: ?first.JsonFont,
    x: Axis,
    y: []const Axis,
    leftFilter: ?Filter,
    rightFilter: ?Filter,
    annotations: []const Annotation,
    pub fn deinit(self: *const Bytecode, gpa: Allocator) void {
        for (self.y) |y| {
            y.deinit(gpa);
        }
        gpa.free(self.y);
        self.x.deinit(gpa);

        for (self.annotations) |an| {
            an.deinit(gpa);
        }
        gpa.free(self.annotations);

        if (self.leftFilter) |filter| {
            filter.deinit(gpa);
        }
        if (self.rightFilter) |filter| {
            filter.deinit(gpa);
        }
    }
};

pub const BytecodeInfo = struct {
    plots: []Bytecode,
    tables: Tables,
    // files: []DebugFile,
    pub fn deinit(self: *BytecodeInfo, gpa: Allocator) void {
        for (self.plots) |p| {
            p.deinit(gpa);
        }
        gpa.free(self.plots);
        self.tables.deinit(gpa);
    }
};

pub const Tables = struct {
    floats: std.ArrayList(f32),
    indices: std.ArrayList(Index),
    pub const Index = struct {
        keyref: u32,
        index: u32,
    };
    pub fn deinit(self: *Tables, gpa: Allocator) void {
        self.floats.deinit(gpa);
        self.indices.deinit(gpa);
    }
};

pub fn parseKeyOp(
    gpa: Allocator,
    tables: *Tables,
    ref: FileRef,
    diagnostic: *Diagnostic,
    handle: u32,
) !Keyref.Op {
    const str = ref.str;
    if (std.mem.eql(u8, str, "first")) {
        return .first;
    } else if (std.mem.eql(u8, str, "last")) {
        return .last;
    } else if (std.mem.eql(u8, str, "min")) {
        return .min;
    } else if (std.mem.eql(u8, str, "max")) {
        return .max;
    } else if (std.mem.eql(u8, str, "mean")) {
        return .mean;
    } else if (std.mem.eql(u8, str, "prev")) {
        return .prev;
    } else if (std.mem.eql(u8, str, "@")) {
        return .selection;
    }

    if (str[0] >= '0' and str[0] <= '9') {
        const indexBuf = for (str, 0..) |c, i| {
            if (c < '0' or c > '9') {
                break str[0 .. i - 1];
            }
        } else str;
        const v = try std.fmt.parseInt(u32, indexBuf, 10);
        try tables.indices.append(gpa, .{ .index = v, .keyref = handle });
        return .index;
    }

    var w = diagnostic.writer();
    defer w.deinit();
    try w.writer.print("Unknown key operator {s}, expected one of 'first', 'last', 'min', 'max', 'mean', 'prev', '@', or a numeric index!", .{str});
    diagnostic.message = try w.toOwnedSlice();
    diagnostic.from = ref;
    return error.UnknownKey;
}

const DirectKeyRef = struct {
    handle: u32,
    rest: FileRef,
};

pub fn parseAxisRef(
    fileref: FileRef,
    supportsAxisRef: bool,
    currentAxisRef: ?u32,
    diagnostic: *Diagnostic,
) !DirectKeyRef {
    const str = fileref.str;
    if (!supportsAxisRef) {
        var w = diagnostic.writer();
        defer w.deinit();

        try w.writer.print("Attempting to parse '{s}' as an axis reference when no axis information was given", .{str});
        diagnostic.message = try w.toOwnedSlice();
        diagnostic.from = fileref;
        return error.InvalidAxisReferenceAttempt;
    }
    const currentRef = currentAxisRef orelse unreachable;
    if (str[0] == 'x') {
        return .{ .handle = 0, .rest = .from(str[1..]) };
    } else if (str[0] == 'y') {
        if (str.len == 1 or str[1] != '[') {
            var w = diagnostic.writer();
            defer w.deinit();

            try w.writer.print("Invalid axis reference '{s}', expected a '[' after 'y'", .{str[1..]});
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(if (str.len == 1) str else str[1..]);

            return error.InvalidAxisReference;
        }
        if (str.len == 2) {
            var w = diagnostic.writer();
            defer w.deinit();

            try w.writer.print("Invalid axis reference '{s}', expected a digit or '#' after '['", .{str[1..]});
            diagnostic.from = .from(if (str.len == 1) str else str[1..]);
            diagnostic.message = try w.toOwnedSlice();

            return error.InvalidAxisReference;
        }
        const nextIndex = if (std.mem.indexOfScalar(u8, str[2..], ']')) |i| i + 2 else {
            var w = diagnostic.writer();
            defer w.deinit();

            try w.writer.print(
                "Invalid axis reference '{s}', expected a closing ']'",
                .{str},
            );
            diagnostic.from = .from(if (str.len == 1) str else str[1..]);
            diagnostic.message = try w.toOwnedSlice();

            return error.InvalidAxisReference;
        };
        const digitStr = str[2..nextIndex];
        const digit =
            if (std.mem.eql(u8, digitStr, "#")) currentRef else std.fmt.parseInt(u32, digitStr, 10) catch |e| {
                var w = diagnostic.writer();
                defer w.deinit();

                try w.writer.print(
                    "Invalid digit reference '{s}', got error {t} while converting it into an integer",
                    .{
                        digitStr, e,
                    },
                );
                diagnostic.from = .from(digitStr);
                diagnostic.message = try w.toOwnedSlice();

                return e;
            };

        return .{
            .handle = digit + 1,
            .rest = .from(str[nextIndex + 1 ..]),
        };
    } else {
        var w = diagnostic.writer();
        defer w.deinit();

        try w.writer.print("Invalid axis reference '{s}', expected either 'x' or 'y[#]' or 'y[(axis number)]'", .{str});
        diagnostic.from = fileref;
        diagnostic.message = try w.toOwnedSlice();

        return error.InvalidAxisReference;
    }
}

pub fn parseDirectKeyRef(
    fileref: FileRef,
    file: []parse.Column,
    supportsAxisRef: bool,
    currentAxisRef: ?u32,
    diagnostic: *Diagnostic,
) !DirectKeyRef {
    const str = fileref.str;
    const firstChar = str[0];
    if (firstChar != '.') {
        if (!supportsAxisRef) {
            var w = diagnostic.writer();
            defer w.deinit();
            try w.writer.print("Invalid reference to a key: '{s}'. \n  NOTE: key references must start with a '.' (eg .timestamp_s or .acc.x)", .{str});
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(str);
            return error.InvalidValueReference;
        } else {
            return try parseAxisRef(fileref, supportsAxisRef, currentAxisRef, diagnostic);
        }
    }

    const slice = for (str, 0..) |c, i| {
        switch (c) {
            'A'...'Z', 'a'...'z', '_', '.', '0'...'9' => {},
            else => break str[0..i],
        }
    } else str;
    const index = for (file, 0..) |col, i| {
        if (std.mem.eql(u8, col.name, slice)) {
            break i;
        }
    } else {
        var w = diagnostic.writer();
        defer w.deinit();
        try w.writer.print("Unknown key reference '{s}'!\n  NOTE: Expected one of: ", .{slice});
        for (file) |col| {
            try w.writer.print("    '{s}'\n", .{col.name});
        }
        diagnostic.from = fileref;
        diagnostic.message = try w.toOwnedSlice();

        return error.UnknownKeyReference;
    };
    const rest = str[slice.len..];

    return .{
        .handle = @intCast(index),
        .rest = .from(rest),
    };
}

pub fn parseKeyRef(
    gpa: Allocator,
    tables: *Tables,
    file: []parse.Column,
    fileref: FileRef,
    supportsAxisRef: bool,
    currentAxisRef: ?u32,
    diagnostic: *Diagnostic,
) !Keyref {
    const str = fileref.str;
    const firstChar = str[0];
    const maybeAxis = (firstChar == 'x' or firstChar == 'y') and supportsAxisRef;
    if (firstChar == '.' or maybeAxis) {
        const directRef = try parseDirectKeyRef(fileref, file, supportsAxisRef, currentAxisRef, diagnostic);
        var index = directRef.handle;
        const rest = directRef.rest;
        const len: usize = @intFromPtr(rest.str.ptr) - @intFromPtr(str.ptr);
        const op: Keyref.Op = if (rest.str.len != 0) blk: {
            if (rest.str[0] != ':') {
                var w = diagnostic.writer();
                defer w.deinit();
                try w.writer.print("Expected ':' or nothing else after key reference '{s}'!\n  NOTE: got string '{s}'", .{ str[0..len], rest.str });
                diagnostic.message = try w.toOwnedSlice();
                diagnostic.from = rest;
                try diagnostic.addRef(.init2("Key reference: ", str[0..len]));
                return error.UnexpectedToken;
            }

            const op = try parseKeyOp(
                gpa,
                tables,
                .from(rest.str[1..]),
                diagnostic,
                @intCast(index),
            );
            if (op == .index) {
                index = @intCast(tables.indices.items.len - 1);
            }
            break :blk op;
        } else .get;

        return .{
            .lineReference = maybeAxis,
            .handle = @intCast(index),
            .op = op,
        };
    }
    if (firstChar >= '0' and firstChar <= '9' or firstChar == '-') {
        const slice = for (str, 0..) |c, i| {
            switch (c) {
                '0'...'9', '.', '-' => {},
                else => break str[0 .. i - 1],
            }
        } else str;

        if (slice.len != str.len) {
            var w: std.Io.Writer.Allocating = .init(gpa);
            defer w.deinit();
            try w.writer.print("Unexpected characters after floating point value '{s}'!\n  NOTE: after float string '{s}'", .{ str[slice.len..], slice });
            diagnostic.message = try w.toOwnedSlice();
            diagnostic.from = .from(str[slice.len..]);
            try diagnostic.extraRefs.append(gpa, .init2("Floating point string: ", slice));
        }

        const value = try std.fmt.parseFloat(f32, slice);

        const op: Keyref.Op = .value;

        const index = tables.floats.items.len;
        try tables.floats.append(gpa, value);

        return .{
            .lineReference = false,
            .handle = @intCast(index),
            .op = op,
        };
    }
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.print("Invalid reference to a value or key reference: '{s}'. \n  NOTE: values should be normal floats (eg 0.1) and key references must start with a '.' (eg .timestamp_s or .acc.x)", .{str});
    diagnostic.message = try w.toOwnedSlice();
    diagnostic.from = .from(str);
    return error.InvalidValueReference;
}

pub fn parseOperation(
    gpa: Allocator,
    tables: *Tables,
    ref: FileRef,
    file: []parse.Column,
    supportsAxisRef: bool,
    currentAxisRef: ?u32,
    diagnostic: *Diagnostic,
) !Operation {
    const str = ref.str;
    if (str[0] == '+') {
        return .{
            .tp = .add,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(str[1..]),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (str[0] == '-') {
        return .{
            .tp = .sub,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(str[1..]),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (str[0] == '/') {
        return .{
            .tp = .div,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(str[1..]),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (str[0] == '*') {
        return .{
            .tp = .mult,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(str[1..]),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (std.mem.startsWith(u8, str, "max ")) {
        return .{
            .tp = .max,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(str[4..]),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (std.mem.startsWith(u8, str, "min ")) {
        return .{
            .tp = .min,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(str[4..]),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (std.mem.startsWith(u8, str, "pow ")) {
        return .{
            .tp = .pow,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(str[4..]),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (std.mem.startsWith(u8, str, "le ")) {
        return .{
            .tp = .le,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(str[3..]),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (std.mem.startsWith(u8, str, "lt ")) {
        return .{
            .tp = .lt,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(str[3..]),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (std.mem.startsWith(u8, str, "ge ")) {
        return .{
            .tp = .ge,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(str[3..]),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (std.mem.startsWith(u8, str, "gt ")) {
        return .{
            .tp = .gt,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(str[3..]),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (std.mem.eql(u8, str, "m_to_ft")) {
        return .{
            .tp = .mult,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(mToFtConversion),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (std.mem.eql(u8, str, "ft_to_m")) {
        return .{
            .tp = .div,
            .value = try parseKeyRef(
                gpa,
                tables,
                file,
                .from(mToFtConversion),
                supportsAxisRef,
                currentAxisRef,
                diagnostic,
            ),
        };
    } else if (std.mem.eql(u8, str, "abs")) {
        return .{
            .tp = .abs,
            .value = undefined,
        };
    } else if (std.mem.eql(u8, str, "exp")) {
        return .{
            .tp = .exp,
            .value = undefined,
        };
    } else if (std.mem.eql(u8, str, "ln")) {
        return .{
            .tp = .ln,
            .value = undefined,
        };
    } else if (std.mem.eql(u8, str, "sqrt")) {
        return .{
            .tp = .sqrt,
            .value = undefined,
        };
    } else {
        var w = diagnostic.writer();
        defer w.deinit();
        try w.writer.print(
            \\Expected a conversion string, instead got '{s}'!
            \\  NOTE: Conversion string must be one of '+', '-', '*', '/', 'max ', 'min ', 'pow ', 'le ', 'lt ', 'ge ', 'gt ' followed by a valid key reference (eg '+.timestamp_s', '-.acc.z:last') OR 'm_to_ft', 'ft_to_m', 'sqrt, 'abs', 'ln', 'exp' (eg 'm_to_ft')
        , .{str});
        diagnostic.message = try w.toOwnedSlice();
        diagnostic.from = ref;
        return error.InvalidConversionString;
    }
}

pub fn parseJsonAxis(
    gpa: Allocator,
    tables: *Tables,
    files: parse.DebugFile,
    axis: first.AxisValue,
    diagnostic: *Diagnostic,
) !Axis {
    const ref = try parseKeyRef(gpa, tables, files.data, axis.key, false, null, diagnostic);
    const ops = try gpa.alloc(Operation, axis.conversions.len);
    errdefer gpa.free(ops);

    for (ops, 0..) |*op, i| {
        op.* = try parseOperation(
            gpa,
            tables,
            axis.conversions[i],
            files.data,
            false,
            null,
            diagnostic,
        );
    }
    return .{
        .title = axis.title,
        .value = ref,
        .ops = ops,
    };
}

pub fn parseFilter(
    gpa: Allocator,
    filterish: ?first.Filter,
    tables: *Tables,
    file: []parse.Column,
    diagnostic: *Diagnostic,
) !?Filter {
    if (filterish == null) return null;
    const filter = filterish.?;
    const ref = try parseDirectKeyRef(filter.key, file, false, null, diagnostic);
    if (ref.rest.str.len != 0) {
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try w.writer.print(
            \\Expected end of string after filter 'key' declaration, instead got '{s}'!
        , .{ref.rest.str});
        diagnostic.message = try w.toOwnedSlice();
        diagnostic.from = ref.rest;
        try diagnostic.extraRefs.append(
            gpa,
            .init("While parsing filter key: ", filter.key),
        );
        return error.InvalidFilterKey;
    }
    if (filter.conversions.len < 1) {
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try w.writer.print(
            \\Need at least one conversion in filter.convert
        , .{});
        diagnostic.message = try w.toOwnedSlice();
        diagnostic.from = filter.key;
        return error.EmptyFilterConversions;
    }
    const conversions: []Operation = try gpa.alloc(Operation, filter.conversions.len);
    errdefer gpa.free(conversions);

    for (conversions, filter.conversions) |*c, og| {
        c.* = try parseOperation(gpa, tables, og, file, false, null, diagnostic);
    }

    const hint: Filter.Hint = if (filter.hint) |hint| blk: {
        if (std.meta.stringToEnum(Filter.Hint, hint.str)) |h| {
            break :blk h;
        }
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try w.writer.print(
            \\Invalid filter hint '{s}', expected one of: 
        , .{hint.str});
        const names = std.meta.fieldNames(Filter.Hint);
        for (names, 0..) |field, i| {
            try w.writer.print("'{s}'", .{field});
            if (i < names.len - 1) {
                try w.writer.print(", ", .{});
            }
        }
        diagnostic.message = try w.toOwnedSlice();
        diagnostic.from = hint;
        return error.InvalidFilterHint;
    } else .normal;

    const ret: Filter = .{
        .key = .{
            .lineReference = false,
            .handle = @intCast(ref.handle),
            .op = .get,
        },
        .convert = conversions,
        .hint = hint,
    };
    return ret;
}

pub fn parseAnnotationValue(
    gpa: Allocator,
    value: first.Annotation.Value,
    tables: *Tables,
    file: []parse.Column,
    currentAxis: u32,
    diagnostic: *Diagnostic,
) !Annotation.Value {
    const v = try parseKeyRef(
        gpa,
        tables,
        file,
        value.value,
        true,
        currentAxis,
        diagnostic,
    );
    try v.ensureStaticValue(value.value, diagnostic);

    var ops: std.ArrayList(Operation) = .empty;
    defer ops.deinit(gpa);

    try ops.ensureUnusedCapacity(gpa, value.convert.len);

    for (value.convert) |c| {
        const op =
            try parseOperation(gpa, tables, c, file, true, currentAxis, diagnostic);
        try op.value.ensureStaticValue(c, diagnostic);
        ops.appendAssumeCapacity(op);
    }

    return .{
        .value = v,
        .ops = try ops.toOwnedSlice(gpa),
    };
}

pub fn parseAnnotation(
    gpa: Allocator,
    annotation: first.Annotation,
    tables: *Tables,
    file: []parse.Column,
    diagnostic: *Diagnostic,
) !Annotation {
    const axis = annotation.line;
    if (axis >= file.len) {
        var w = diagnostic.writer();
        defer w.deinit();
        try w.writer.print(
            \\specified 'line' key for annotation value is too high!
            \\  NOTE: got {}, but graph only specifies {} y axes
        , .{ axis, file.len });
        diagnostic.message = try w.toOwnedSlice();
        diagnostic.from = annotation.text;
        return error.InvalidAnnotationAxis;
    }

    const x = try parseAnnotationValue(gpa, annotation.x, tables, file, axis, diagnostic);
    errdefer x.deinit(gpa);

    const y = try parseAnnotationValue(gpa, annotation.y, tables, file, axis, diagnostic);
    errdefer y.deinit(gpa);

    var values: std.ArrayList(Annotation.Value) = .empty;
    defer values.deinit(gpa);
    errdefer for (values.items) |i| i.deinit(gpa);

    try values.ensureUnusedCapacity(gpa, annotation.values.len);

    for (annotation.values) |v| {
        const value = try parseAnnotationValue(gpa, v, tables, file, axis, diagnostic);
        errdefer value.deinit(gpa);

        values.appendAssumeCapacity(value);
    }

    const selection = blk: {
        if (std.meta.stringToEnum(Annotation.Selection, annotation.select.str)) |h| {
            break :blk h;
        }
        var w = diagnostic.writer();
        defer w.deinit();
        try w.writer.print(
            \\Invalid annotation select key '{s}', expected one of: 
        , .{annotation.select.str});
        const names = std.meta.fieldNames(Annotation.Selection);
        for (names, 0..) |field, i| {
            try w.writer.print("'{s}'", .{field});
            if (i < names.len - 1) {
                try w.writer.print(", ", .{});
            }
        }
        diagnostic.message = try w.toOwnedSlice();
        diagnostic.from = annotation.select;
        return error.InvalidAnnotationSelect;
    };

    var text: std.ArrayList(Annotation.TextItem) = .empty;
    defer text.deinit(gpa);

    var currentReferences: usize = 0;
    var currentStart: usize = 0;
    var i: usize = 0;
    const str = annotation.text.str;
    while (i < str.len) : (i += 1) {
        const c = str[i];
        if (c == '{') {
            if (i + 1 < str.len and str[i + 1] == '{') {
                try text.append(gpa, .{ .text = .from(str[currentStart .. i + 1]) });
                currentStart = i + 2;
                i = currentStart;
            } else {
                if (i != currentStart) {
                    try text.append(gpa, .{ .text = .from(str[currentStart..i]) });
                }
                currentReferences += 1;
                if (currentReferences > values.items.len) {
                    var w = diagnostic.writer();
                    defer w.deinit();
                    try w.writer.print(
                        \\Too many value references given to annotation text!
                        \\  NOTE: Expected {} references, but got at least {}
                    , .{ values.items.len, currentReferences });

                    diagnostic.message = try w.toOwnedSlice();
                    diagnostic.from = .from(str[i..]);
                    return error.TooManyValueReferences;
                }
                const braceIndex =
                    if (std.mem.indexOfScalar(u8, str[i..], '}')) |idx| idx + i else {
                        var w = diagnostic.writer();
                        defer w.deinit();
                        try w.writer.print(
                            \\Expected a closing '}}' after an opening '{{' for an annotation value reference!
                            \\  NOTE: if you want to put a literal '{{', please put it as {{{{
                        , .{});

                        diagnostic.message = try w.toOwnedSlice();
                        diagnostic.from = .from(str[i..]);
                        return error.TooManyValueReferences;
                    };

                const middle = str[i + 1 .. braceIndex];
                if (middle.len == 0) {
                    try text.append(gpa, .{ .item = .{ .round = null } });
                } else {
                    const round = std.fmt.parseInt(u8, middle, 10) catch |e| {
                        var w = diagnostic.writer();
                        defer w.deinit();
                        try w.writer.print(
                            \\Invalid integer literal {s}!
                        , .{middle});

                        diagnostic.message = try w.toOwnedSlice();
                        diagnostic.from = .from(middle);
                        return e;
                    };
                    try text.append(gpa, .{ .item = .{ .round = round } });
                }
                currentStart = braceIndex + 1;
                i = currentStart;
            }
        }
    }
    if (i != currentStart) {
        try text.append(gpa, .{ .text = .from(str[currentStart..]) });
    }

    const ret: Annotation = .{
        .select = selection,
        .text = try text.toOwnedSlice(gpa),
        .x = x,
        .y = y,
        .type = annotation.type,
        .line = annotation.line,
        .values = try values.toOwnedSlice(gpa),
        .arrow = annotation.arrow,
        .style = annotation.style,
    };
    return ret;
}

pub fn compileToBytecode(
    gpa: Allocator,
    info: first.PlotInfo,
    files: parse.DebugFile,
    diagnostic: *Diagnostic,
) !BytecodeInfo {
    var tables: Tables = .{
        .floats = .empty,
        .indices = .empty,
    };
    errdefer tables.deinit(gpa);

    const plots: []Bytecode = try gpa.alloc(Bytecode, info.plots.len);
    errdefer gpa.free(plots);

    var filledIndices: usize = 0;
    errdefer for (0..filledIndices) |i| {
        plots[i].deinit(gpa);
    };

    for (info.plots, plots) |plot, *ret| {
        const xRef = try parseJsonAxis(gpa, &tables, files, plot.x, diagnostic);
        errdefer xRef.deinit(gpa);

        var yList: std.ArrayList(Axis) = .empty;
        defer yList.deinit(gpa);
        errdefer {
            for (yList.items) |y| {
                y.deinit(gpa);
            }
        }

        try yList.ensureUnusedCapacity(gpa, plot.y.len);

        for (plot.y) |y| {
            yList.appendAssumeCapacity(try parseJsonAxis(
                gpa,
                &tables,
                files,
                y,
                diagnostic,
            ));
        }

        const leftFilter = try parseFilter(
            gpa,
            plot.filter.left,
            &tables,
            files.data,
            diagnostic,
        );
        errdefer if (leftFilter) |filter| filter.deinit(gpa);
        const rightFilter = try parseFilter(
            gpa,
            plot.filter.right,
            &tables,
            files.data,
            diagnostic,
        );
        errdefer if (rightFilter) |filter| filter.deinit(gpa);

        var annotations: std.ArrayList(Annotation) = .empty;
        defer annotations.deinit(gpa);
        errdefer for (annotations.items) |i| i.deinit(gpa);

        try annotations.ensureUnusedCapacity(gpa, plot.annotations.len);
        for (plot.annotations) |a| {
            annotations.appendAssumeCapacity(
                try parseAnnotation(gpa, a, &tables, files.data, diagnostic),
            );
        }

        ret.* = .{
            .annotations = try annotations.toOwnedSlice(gpa),
            .leftFilter = leftFilter,
            .rightFilter = rightFilter,
            .dpi = plot.dpi,
            .font = plot.font,
            .width = plot.width,
            .height = plot.height,
            .saveto = plot.output,
            .title = plot.title,
            .file = files,
            .x = xRef,
            .y = try yList.toOwnedSlice(gpa),
        };
        filledIndices += 1;
    }

    return .{
        .plots = plots,
        .tables = tables,
    };
}
