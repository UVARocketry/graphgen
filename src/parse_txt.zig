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
    return try gpa.dupe(Column, ret.items);
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
    const v = parseDbgOut(gpa, dbgContents, diagnostic) catch |e| {
        return e;
    };
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
