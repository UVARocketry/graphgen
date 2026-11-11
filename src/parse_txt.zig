const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Column = struct {
    skip: u32,
    name: []const u8,
    values: []const f32,

    pub fn deinit(self: *Column, gpa: Allocator) void {
        gpa.free(self.values);
        gpa.free(self.name);
    }
};

const TempColumn = struct {
    skip: u32,
    name: []const u8,
    values: std.ArrayList(f32),
};

const pow10tab = [_]f64{
    1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,  1e8,  1e9,
    1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18,
};

inline fn parseU32(s: []const u8) u32 {
    var r: u32 = 0;
    for (s) |c| r = r * 10 + (c - '0');
    return r;
}

inline fn parseF32(s: []const u8) f32 {
    var pos: usize = 0;
    const len = s.len;

    var negative = false;
    if (pos < len and s[pos] == '-') {
        negative = true;
        pos += 1;
    }

    var significand: u64 = 0;
    var digit_count: u32 = 0;
    var exponent: i32 = 0;

    while (pos < len) : (pos += 1) {
        const c = s[pos];
        if (c < '0' or c > '9') break;
        significand = significand * 10 + (c - '0');
        digit_count += 1;
    }

    if (pos < len and s[pos] == '.') {
        pos += 1;
        while (pos < len) : (pos += 1) {
            const c = s[pos];
            if (c < '0' or c > '9') break;
            if (digit_count < 18) {
                significand = significand * 10 + (c - '0');
                digit_count += 1;
            }
            exponent -= 1;
        }
    }

    if (digit_count == 0) return 0.0;

    var result: f64 = @floatFromInt(significand);

    if (exponent >= 0) {
        const e: usize = @intCast(exponent);
        if (e < pow10tab.len) {
            result *= pow10tab[e];
        } else {
            result *= std.math.pow(f64, 10.0, @floatFromInt(e));
        }
    } else {
        const e: usize = @intCast(-exponent);
        if (e < pow10tab.len) {
            result /= pow10tab[e];
        } else {
            result /= std.math.pow(f64, 10.0, @floatFromInt(-exponent));
        }
    }

    if (negative) result = -result;
    return @floatCast(result);
}

pub fn parseDbgOut(gpa: Allocator, data: []const u8, diagnostic: *?[]const u8) ![]Column {
    if (data[0] == '!') {
        return try parseV2Txt(gpa, data, diagnostic);
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var cols: std.ArrayList(TempColumn) = .empty;

    var currentCol: u32 = 0;
    var lastFrame: u32 = 0;
    var row: usize = 0;

    var pos: usize = 0;
    const len = data.len;

    while (pos < len) {
        row += 1;

        if (data[pos] != '.') {
            diagnostic.* = "Expected '.' at start of line";
            return error.InvalidFormat;
        }
        pos += 1;

        const frame_start = pos;
        while (pos < len and data[pos] != '.') : (pos += 1) {}
        const frame = parseU32(data[frame_start..pos]);
        pos += 1;

        const key_start = pos;
        while (pos < len and data[pos] != ':') : (pos += 1) {}
        const key = data[key_start..pos];
        pos += 1;

        while (pos < len and data[pos] <= 32) : (pos += 1) {}

        const val_start = pos;
        while (pos < len and data[pos] != '\n') : (pos += 1) {}
        const value = parseF32(data[val_start..pos]);

        if (pos < len and data[pos] == '\n') pos += 1;

        if (lastFrame != frame) currentCol = 0;
        lastFrame = frame;

        if (currentCol >= cols.items.len) {
            try cols.append(arena.allocator(), .{
                .name = try arena.allocator().dupe(u8, key),
                .skip = frame,
                .values = .empty,
            });
        }

        if (!std.mem.eql(u8, cols.items[currentCol].name, key)) {
            try cols.insert(arena.allocator(), currentCol, .{
                .name = try arena.allocator().dupe(u8, key),
                .skip = frame,
                .values = .empty,
            });
        }

        const item = &cols.items[currentCol];
        if (frame == item.skip + item.values.items.len) {
            try item.values.append(gpa, value);
        }
        currentCol += 1;
    }

    var ret: std.ArrayList(Column) = .empty;
    defer ret.deinit(gpa);
    errdefer for (ret.items) |*i| i.deinit(gpa);

    try ret.ensureUnusedCapacity(gpa, cols.items.len);

    for (cols.items) |*c| {
        ret.appendAssumeCapacity(.{
            .name = try gpa.dupe(u8, c.name),
            .skip = c.skip,
            .values = try c.values.toOwnedSlice(gpa),
        });
    }

    std.debug.print("Finished {} lines with {} items!\n", .{ row, cols.items.len });

    return try ret.toOwnedSlice(gpa);
}

pub fn parseV2Txt(gpa: Allocator, data: []const u8, diagnostic: *?[]const u8) ![]Column {
    var ret: std.ArrayList(Column) = .empty;
    defer ret.deinit(gpa);

    errdefer for (ret.items) |*i| {
        i.deinit(gpa);
    };

    var reader: std.Io.Reader = .fixed(data);
    const start = "!v2\n";
    for (start) |c| {
        if (try reader.takeByte() != c) {
            diagnostic.* = "Expected file to start with '!v2'";
            return error.UnexpectedCharacter;
        }
    }
    const modeStr = try reader.takeDelimiterExclusive('=');
    _ = try reader.takeByte();
    if (!std.mem.eql(u8, modeStr, "mode")) {
        diagnostic.* = "Need mode flags!";
        return error.MissingFlags;
    }

    const modeFlag = try reader.takeDelimiterExclusive('\n');
    _ = try reader.takeByte();
    var mode: enum { raw, human } = .human;

    if (std.mem.eql(u8, modeFlag, "raw")) {
        mode = .raw;
    } else if (std.mem.eql(u8, modeFlag, "human")) {
        mode = .human;
    } else {
        diagnostic.* = "Unknown mode flag!";
        return error.UnknownMode;
    }

    const fieldsCountStr = try reader.takeDelimiterExclusive('\n');
    _ = try reader.takeByte();
    const fieldsCount = try std.fmt.parseInt(u32, fieldsCountStr, 10);

    try ret.ensureUnusedCapacity(gpa, fieldsCount);

    for (0..fieldsCount) |_| {
        const name = try reader.takeDelimiterExclusive('\n');
        _ = try reader.takeByte();
        ret.appendAssumeCapacity(.{
            .name = try gpa.dupe(u8, name),
            .skip = 0,
            .values = &.{},
        });
    }
    var totalValues: u32 = 0;

    for (0..fieldsCount) |expectedI| {
        const name = try reader.takeDelimiterExclusive('\n');
        _ = try reader.takeByte();

        const i = if (!std.mem.eql(u8, ret.items[expectedI].name, name))
            for (ret.items, 0..) |item, i| {
                if (std.mem.eql(u8, item.name, name)) {
                    break i;
                }
            } else std.debug.panic("Unknown name {s}!", .{name})
        else
            expectedI;

        const baseFrameStr = try reader.takeDelimiterExclusive('\n');
        _ = try reader.takeByte();
        const baseFrame = try std.fmt.parseInt(u32, baseFrameStr, 10);

        ret.items[i].skip = baseFrame;

        const valuesCountStr = try reader.takeDelimiterExclusive('\n');
        _ = try reader.takeByte();
        const valuesCount = try std.fmt.parseInt(u32, valuesCountStr, 10);
        totalValues += valuesCount;

        if (mode == .raw) {
            if (try reader.takeByte() != '!') {
                diagnostic.* = "Expected !";
                return error.UnknownCharacter;
            }
            const valuesSlice = try reader.take(valuesCount * @sizeOf(f32));
            const slice = try gpa.alloc(f32, valuesCount);
            @memcpy(slice, @as([]align(1) f32, @ptrCast(valuesSlice)));
            ret.items[i].values = slice;
            _ = try reader.takeByte();
        } else {
            const slice = try gpa.alloc(f32, valuesCount);
            for (0..valuesCount) |k| {
                const str = try reader.takeDelimiterExclusive('\n');
                _ = try reader.takeByte();

                const float = try std.fmt.parseFloat(f32, str);
                slice[k] = float;
            }
            ret.items[i].values = slice;
        }
    }
    std.debug.print("Parsed {} values!\n", .{totalValues});
    var frames: usize = 0;
    for (ret.items) |col| {
        frames = @max(col.values.len, frames);
    }
    std.debug.print("Parsed {} frames!\n", .{frames});
    return try gpa.dupe(Column, ret.items);
}

pub const V2OutMode = enum {
    raw,
    human,
};

fn parseCsvNumber(text: []const u8) !f32 {
    if (text.len == 0) return std.math.nan(f32);
    if (std.ascii.eqlIgnoreCase(text, "nan") or
        std.ascii.eqlIgnoreCase(text, "-nan") or
        std.ascii.eqlIgnoreCase(text, "+nan") or
        std.ascii.eqlIgnoreCase(text, "na") or
        std.ascii.eqlIgnoreCase(text, "n/a") or
        std.ascii.eqlIgnoreCase(text, "null"))
    {
        return std.math.nan(f32);
    }
    return std.fmt.parseFloat(f32, text);
}

fn csvRowLooksLikeHeader(fields: []const []const u8) bool {
    for (fields) |raw| {
        const text = std.mem.trim(u8, raw, " \t\r\x00");
        if (text.len == 0) continue;
        _ = parseCsvNumber(text) catch return true;
    }
    return false;
}

fn appendCsvRow(
    gpa: Allocator,
    columns: *std.ArrayList(std.ArrayList(f32)),
    line: []const u8,
    lineNo: usize,
    diagnostic: *?[]const u8,
) !void {
    var fields = std.mem.splitScalar(u8, line, ',');
    var columnIndex: usize = 0;

    while (fields.next()) |raw| : (columnIndex += 1) {
        if (columnIndex >= columns.items.len) {
            diagnostic.* = try std.fmt.allocPrint(
                gpa,
                "Line {d}: expected {} columns but found more",
                .{ lineNo, columns.items.len },
            );
            return error.TooManyColumns;
        }

        const text = std.mem.trim(u8, raw, " \t\r\x00");
        const value = parseCsvNumber(text) catch {
            diagnostic.* = try std.fmt.allocPrint(
                gpa,
                "Line {d}: invalid number '{s}'",
                .{ lineNo, text },
            );
            return error.InvalidNumber;
        };
        try columns.items[columnIndex].append(gpa, value);
    }

    // Be forgiving of short rows; missing values are represented by NaN.
    while (columnIndex < columns.items.len) : (columnIndex += 1) {
        try columns.items[columnIndex].append(gpa, std.math.nan(f32));
    }
}

fn csvColumnNameExists(existing: []const Column, name: []const u8) bool {
    for (existing) |column| {
        if (std.mem.eql(u8, column.name, name)) return true;
    }
    return false;
}

fn makeCsvColumnName(
    gpa: Allocator,
    raw: []const u8,
    index: usize,
    existing: []const Column,
) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\x00");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) {
        return std.fmt.allocPrint(gpa, ".column_{d}", .{index});
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    var start: usize = 0;
    if (trimmed[0] == '.') {
        try buf.append(gpa, '.');
        start = 1;
    } else {
        try buf.append(gpa, '.');
    }

    for (trimmed[start..]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') {
            try buf.append(gpa, c);
        } else {
            try buf.append(gpa, '_');
        }
    }

    const base = try buf.toOwnedSlice(gpa);
    errdefer gpa.free(base);

    if (!csvColumnNameExists(existing, base)) return base;

    var suffix: usize = 2;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(
            gpa,
            "{s}_{d}",
            .{ base, suffix },
        );
        if (!csvColumnNameExists(existing, candidate)) {
            gpa.free(base);
            return candidate;
        }
        gpa.free(candidate);
    }
}

/// Parse a CSV file containing numeric values. If the first row is not
/// entirely numeric it is treated as a header; otherwise columns are named
/// `.column_0`, `.column_1`, and so on. `nan`/`-nan` and empty cells become
/// `std.math.nan(f32)`.
pub fn parseCsv(gpa: Allocator, data: []const u8, diagnostic: *?[]const u8) ![]Column {
    var csv = data;
    if (std.mem.startsWith(u8, csv, "\xEF\xBB\xBF")) csv = csv[3..];

    var columns: std.ArrayList(std.ArrayList(f32)) = .empty;
    defer {
        for (columns.items) |*column| column.deinit(gpa);
        columns.deinit(gpa);
    }

    var columnNames: std.ArrayList([]const u8) = .empty;
    defer columnNames.deinit(gpa);

    var pos: usize = 0;
    var lineNo: usize = 0;

    while (pos < csv.len) {
        const eol = std.mem.findScalarPos(u8, csv, pos, '\n') orelse csv.len;
        const line = std.mem.trim(u8, csv[pos..eol], " \t\r\x00");
        pos = if (eol < csv.len) eol + 1 else csv.len;
        lineNo += 1;

        if (line.len == 0) continue;

        if (columns.items.len == 0) {
            var firstFields: std.ArrayList([]const u8) = .empty;
            defer firstFields.deinit(gpa);

            var fields = std.mem.splitScalar(u8, line, ',');
            while (fields.next()) |field| {
                try firstFields.append(gpa, field);
            }

            if (firstFields.items.len == 0) continue;

            try columns.ensureUnusedCapacity(gpa, firstFields.items.len);
            for (0..firstFields.items.len) |_| {
                columns.appendAssumeCapacity(.empty);
            }

            if (csvRowLooksLikeHeader(firstFields.items)) {
                for (firstFields.items) |name| {
                    try columnNames.append(gpa, name);
                }
                continue;
            }

            try appendCsvRow(gpa, &columns, line, lineNo, diagnostic);
            continue;
        }

        try appendCsvRow(gpa, &columns, line, lineNo, diagnostic);
    }

    if (columns.items.len == 0) {
        diagnostic.* = "CSV file contained no numeric rows";
        return error.EmptyCsv;
    }

    var ret: std.ArrayList(Column) = .empty;
    errdefer {
        for (ret.items) |*column| column.deinit(gpa);
        ret.deinit(gpa);
    }
    try ret.ensureUnusedCapacity(gpa, columns.items.len);

    for (columns.items, 0..) |*column, i| {
        const name = if (columnNames.items.len == 0)
            try std.fmt.allocPrint(gpa, ".column_{d}", .{i})
        else
            try makeCsvColumnName(gpa, columnNames.items[i], i, ret.items);
        errdefer gpa.free(name);

        ret.appendAssumeCapacity(.{
            .skip = 0,
            .name = name,
            .values = try column.toOwnedSlice(gpa),
        });
    }

    return ret.toOwnedSlice(gpa);
}

/// Serialize columns to the v2 debug format. The returned slice is owned by
/// the caller.
pub fn writeV2Txt(gpa: Allocator, columns: []const Column, mode: V2OutMode) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    const writer = &out.writer;
    try writer.print("!v2\nmode={s}\n{}\n", .{ @tagName(mode), columns.len });
    for (columns) |column| {
        try writer.print("{s}\n", .{column.name});
    }

    for (columns) |column| {
        try writer.print(
            "{s}\n{}\n{}\n",
            .{ column.name, column.skip, column.values.len },
        );

        switch (mode) {
            .raw => {
                try writer.writeByte('!');
                try writer.writeAll(std.mem.sliceAsBytes(column.values));
                try writer.writeByte('\n');
            },
            .human => {
                for (column.values) |value| {
                    try writer.print("{d}\n", .{value});
                }
            },
        }
    }

    return out.toOwnedSlice();
}

pub fn parseDbgFile(io: std.Io, gpa: Allocator, pageAlloc: Allocator, filename: []const u8, diagnostic: *?[]const u8) ![]Column {
    const file = try std.Io.Dir.cwd().openFile(
        io,
        filename,
        .{ .mode = .read_only },
    );
    defer file.close(io);

    const stat = try file.stat(io);
    const size = stat.size;

    const buf: []u8 = try pageAlloc.alloc(u8, 1024 * 1024 * 16);
    var r = file.reader(io, buf);

    const dbgContents = try r.interface.readAlloc(pageAlloc, size);
    defer pageAlloc.free(dbgContents);

    const start = std.Io.Clock.awake.now(io);
    const v = if (std.mem.endsWith(u8, filename, ".csv"))
        parseCsv(gpa, dbgContents, diagnostic)
    else
        parseDbgOut(gpa, dbgContents, diagnostic);
    const end = std.Io.Clock.awake.now(io);

    const nanos: f64 = @floatFromInt(start.durationTo(end).nanoseconds);
    std.debug.print("Took {}s\n", .{nanos / 1.0e9});
    return v;
}

pub const DebugFile = struct {
    data: []Column,
    file: []const u8,
    pub fn deinit(self: *const DebugFile, gpa: Allocator) void {
        gpa.free(self.file);
        for (self.data) |d| {
            d.deinit(gpa);
        }
        gpa.free(self.data);
    }
};
