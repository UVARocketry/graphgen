const parseOut = @import("../parse_txt.zig");
const builtin = @import("builtin");
const types = @import("../parse/types.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bc = @import("../parse/bytecode.zig");
const std = @import("std");
const f = @import("../fileref.zig");
const parse = @import("../parse/parse.zig");
pub const Type = struct {
    filter: bc.BytecodeFilter = .{
        .left = null,
        .right = null,
    },
    use: []const u8,
    add: []struct {
        name: []const u8,
        value: types.Bytecode,
    } = &.{},
    drop: [][]const u8 = &.{},
};

/// Frees the slices allocated by the parser. String fields point into the
/// source file and are not freed here.
pub fn deinit(alloc: Allocator, item: *const Type) void {
    alloc.free(item.add);
    alloc.free(item.drop);
}

pub fn run(
    io: Io,
    gpa: Allocator,
    pageAlloc: Allocator,
    item: *const Type,
    writer: *Io.Writer,
    bytecode: *bc.BytecodeInterpreter,
) !void {
    var diagnostic: ?[]const u8 = null;
    const cols = parseOut.parseDbgFile(io, gpa, pageAlloc, item.use, &diagnostic) catch |e| {
        if (diagnostic) |message| {
            std.log.err("Failed to parse '{s}': {s}", .{ item.use, message });
        }
        return e;
    };
    defer {
        for (cols) |*col| col.deinit(gpa);
        gpa.free(cols);
    }

    try runColumns(gpa, item, writer, bytecode, cols);
}

/// Runs the transform over already parsed columns, writing the resulting csv
/// to `writer`. `cols` is borrowed, not freed.
pub fn runColumns(
    gpa: Allocator,
    item: *const Type,
    writer: *Io.Writer,
    bytecode: *bc.BytecodeInterpreter,
    cols: []const parseOut.Column,
) !void {
    // only the columns the bytecode actually references need to be part of the
    // keyref table, keeping the data file's column order
    var used: std.StringHashMapUnmanaged(bool) = .empty;
    defer used.deinit(gpa);
    for (bytecode.keyrefNames) |name| try used.put(gpa, name, false);

    var frames: std.ArrayList(bc.Frame) = .empty;
    defer frames.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);

    var maxFrame: u32 = 0;
    for (cols) |col| {
        maxFrame = @max(maxFrame, col.skip + @as(u32, @intCast(col.values.len)));
        if (used.getPtr(col.name)) |referenced| {
            referenced.* = true;
            try frames.append(gpa, .{ .skip = col.skip, .values = col.values });
            try names.append(gpa, col.name);
        }
    }

    // every key referenced by the filter or add expressions must exist in the
    // data file
    var missing = used.iterator();
    while (missing.next()) |entry| {
        if (!entry.value_ptr.*) {
            if (!builtin.is_test) {
                std.log.err("Keyname: {s}\n", .{entry.key_ptr.*});
            }
            return error.MissingKey;
        }
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

    bytecode.store.frames = frames.items;
    bytecode.store.maxFrame = maxFrame;
    bytecode.store.leftFrame = .nil;
    bytecode.store.rightFrame = .nil;

    // the filter and add expressions execute on the interpreter's value stack,
    // which may be too small for them, so grow it if needed
    var needed: usize = 8;
    if (item.filter.left) |left| {
        needed = @max(needed, try bytecode.getMaxStackUsage(left.value));
    }
    if (item.filter.right) |right| {
        needed = @max(needed, try bytecode.getMaxStackUsage(right.value));
    }
    for (item.add) |add| {
        needed = @max(needed, try bytecode.getMaxStackUsage(add.value));
    }

    const oldStack = bytecode.valueStack;
    defer bytecode.valueStack = oldStack;
    var tempStack: ?[]f32 = null;
    defer if (tempStack) |stack| gpa.free(stack);
    if (oldStack.capacity < needed) {
        tempStack = try gpa.alloc(f32, needed);
        bytecode.valueStack = .initBuffer(tempStack.?);
    }

    bytecode.setFilterBounds(item.filter);

    // dropped column indices, original columns first then added fields
    var dropped = try std.DynamicBitSet.initEmpty(gpa, cols.len + item.add.len);
    defer dropped.deinit();

    for (item.drop) |dropName| {
        var index: ?usize = null;
        for (cols, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, dropName)) {
                index = i;
                break;
            }
        }
        if (index == null) {
            for (item.add, 0..) |add, j| {
                if (std.mem.eql(u8, add.name, dropName)) {
                    index = cols.len + j;
                    break;
                }
            }
        }
        const found = index orelse {
            return error.UnknownColumn;
        };
        dropped.set(found);
    }

    var first: bool = true;
    for (cols, 0..) |col, i| {
        if (dropped.isSet(i)) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        const name = if (col.name[0] == '.') col.name[1..] else col.name;
        try writer.writeAll(name);
    }
    for (item.add, 0..) |add, j| {
        if (dropped.isSet(cols.len + j)) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll(add.name);
    }
    try writer.writeAll("\n");

    const frameStart = bytecode.store.leftFrame.orElse(0);
    // 0 (and .nil) means the right filter did not clip anything
    const rightFrame = bytecode.store.rightFrame.orElse(0);
    const frameEnd = if (rightFrame == 0) maxFrame else @min(rightFrame, maxFrame);

    // every frame in the filter window gets a row, none are skipped
    for (frameStart..frameEnd) |frame| {
        const frameNo: u32 = @intCast(frame);
        var rowFirst = true;
        for (cols, 0..) |col, i| {
            if (dropped.isSet(i)) continue;
            if (!rowFirst) try writer.writeAll(",");
            rowFirst = false;
            const asFrame: bc.Frame = .{ .skip = col.skip, .values = col.values };
            try writer.print("{d}", .{asFrame.valueAtFrame(frameNo)});
        }
        for (item.add, 0..) |add, j| {
            if (dropped.isSet(cols.len + j)) continue;
            if (!rowFirst) try writer.writeAll(",");
            rowFirst = false;
            const value = try bytecode.execRange(add.value, frameNo);
            try writer.print("{d}", .{value});
        }
        try writer.writeAll("\n");
    }
}

test "transform csv columns" {
    const gpa = std.testing.allocator;
    const src =
        \\use "data"
        \\filter {
        \\  left {
        \\    value = .a > 0
        \\    hint none
        \\  }
        \\}
        \\add {
        \\  name "sum"
        \\  value = .a + .b
        \\}
        \\drop ".b"
        \\
    ;

    var diagnostic: f.Diagnostic = .{
        .gpa = gpa,
        .extraRefs = .empty,
        .filename = "test",
        .message = &.{},
        .from = .from(""),
    };
    defer diagnostic.deinit();

    var parser: parse.ParserPass1 = .{
        .lexer = .init(src),
        .bytecodeStream = .{ .arr = .empty },
        .scope = .empty,
        .keyrefTable = .empty,
        .paramNames = .empty,
        .bytecodeStarts = .empty,
    };
    parser.paramNames = .initBuffer(&parser.paramNameBuf);
    defer parser.deinit(gpa);

    var parsed = try parser.pass(gpa, Type, &diagnostic);
    defer deinit(gpa, &parsed);

    var cache: bc.ValueCache = .init();
    defer cache.deinit(gpa);

    var stackBuffer: [1]f32 = undefined;

    var bytecode: bc.BytecodeInterpreter = .{
        .keyrefNames = parser.keyrefTable.items,
        .reader = .{ .bytecode = parser.bytecodeStream.arr.items, .pos = 0 },
        .stackAllocator = .failing,
        .valueStack = .initBuffer(&stackBuffer),
        .datastoreAllocator = gpa,
        .store = .{
            .maxFrame = 0,
            .leftFrame = .nil,
            .rightFrame = .nil,
            .frames = &.{},
            .cache = &cache,
        },
    };

    var cols = [_]parseOut.Column{
        .{ .skip = 0, .name = ".a", .values = &[_]f32{ -1, 1, 2, 3 } },
        .{ .skip = 0, .name = ".b", .values = &[_]f32{ 10, 20, 30, 40 } },
    };

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try runColumns(gpa, &parsed, &out.writer, &bytecode, &cols);

    const output = try out.toOwnedSlice();
    defer gpa.free(output);

    try std.testing.expectEqualStrings(
        "a,sum\n1,21\n2,32\n3,43\n",
        output,
    );
}

test "transform drop unknown column" {
    const gpa = std.testing.allocator;
    const src =
        \\use "data"
        \\drop ".nope"
        \\
    ;

    var diagnostic: f.Diagnostic = .{
        .gpa = gpa,
        .extraRefs = .empty,
        .filename = "test",
        .message = &.{},
        .from = .from(""),
    };
    defer diagnostic.deinit();

    var parser: parse.ParserPass1 = .{
        .lexer = .init(src),
        .bytecodeStream = .{ .arr = .empty },
        .scope = .empty,
        .keyrefTable = .empty,
        .paramNames = .empty,
        .bytecodeStarts = .empty,
    };
    parser.paramNames = .initBuffer(&parser.paramNameBuf);
    defer parser.deinit(gpa);

    var parsed = try parser.pass(gpa, Type, &diagnostic);
    defer deinit(gpa, &parsed);

    var cache: bc.ValueCache = .init();
    defer cache.deinit(gpa);

    var stackBuffer: [1]f32 = undefined;

    var bytecode: bc.BytecodeInterpreter = .{
        .keyrefNames = parser.keyrefTable.items,
        .reader = .{ .bytecode = parser.bytecodeStream.arr.items, .pos = 0 },
        .stackAllocator = .failing,
        .valueStack = .initBuffer(&stackBuffer),
        .datastoreAllocator = gpa,
        .store = .{
            .maxFrame = 0,
            .leftFrame = .nil,
            .rightFrame = .nil,
            .frames = &.{},
            .cache = &cache,
        },
    };

    var cols = [_]parseOut.Column{
        .{ .skip = 0, .name = ".a", .values = &[_]f32{ 1, 2 } },
    };

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try std.testing.expectError(
        error.UnknownColumn,
        runColumns(gpa, &parsed, &out.writer, &bytecode, &cols),
    );
}

test "transform missing key" {
    const gpa = std.testing.allocator;
    const src =
        \\use "data"
        \\add {
        \\  name "sum"
        \\  value = .a + .b
        \\}
        \\
    ;

    var diagnostic: f.Diagnostic = .{
        .gpa = gpa,
        .extraRefs = .empty,
        .filename = "test",
        .message = &.{},
        .from = .from(""),
    };
    defer diagnostic.deinit();

    var parser: parse.ParserPass1 = .{
        .lexer = .init(src),
        .bytecodeStream = .{ .arr = .empty },
        .scope = .empty,
        .keyrefTable = .empty,
        .paramNames = .empty,
        .bytecodeStarts = .empty,
    };
    parser.paramNames = .initBuffer(&parser.paramNameBuf);
    defer parser.deinit(gpa);

    var parsed = try parser.pass(gpa, Type, &diagnostic);
    defer deinit(gpa, &parsed);

    var cache: bc.ValueCache = .init();
    defer cache.deinit(gpa);

    var stackBuffer: [1]f32 = undefined;

    var bytecode: bc.BytecodeInterpreter = .{
        .keyrefNames = parser.keyrefTable.items,
        .reader = .{ .bytecode = parser.bytecodeStream.arr.items, .pos = 0 },
        .stackAllocator = .failing,
        .valueStack = .initBuffer(&stackBuffer),
        .datastoreAllocator = gpa,
        .store = .{
            .maxFrame = 0,
            .leftFrame = .nil,
            .rightFrame = .nil,
            .frames = &.{},
            .cache = &cache,
        },
    };

    // the data file only has .a, the add references .b
    var cols = [_]parseOut.Column{
        .{ .skip = 0, .name = ".a", .values = &[_]f32{ 1, 2 } },
    };

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try std.testing.expectError(
        error.MissingKey,
        runColumns(gpa, &parsed, &out.writer, &bytecode, &cols),
    );
}
