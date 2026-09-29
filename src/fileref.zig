const std = @import("std");
const Allocator = std.mem.Allocator;
pub const FileRef = struct {
    str: []const u8,
    pub fn from(str: []const u8) FileRef {
        return .{ .str = str };
    }
    pub fn fromish(str: ?[]const u8) ?FileRef {
        if (str) |s| {
            return .{ .str = s };
        }
        return null;
    }
};

pub const LineParts = struct {
    before: []const u8,
    err: []const u8,
    after: []const u8,
    pub fn getLineAround(fileContents: []const u8, ref: FileRef) !LineParts {
        const strPtr: usize = @intFromPtr(ref.str.ptr);
        const contentsPtr: usize = @intFromPtr(fileContents.ptr);
        if (strPtr < contentsPtr or strPtr >= contentsPtr + fileContents.len) {
            return error.RefNotFound;
        }

        // the entire file before the ref string
        const preStr = fileContents[0 .. strPtr - contentsPtr];
        const refStartIndex = strPtr - contentsPtr;

        const startIndex =
            if (std.mem.lastIndexOfScalar(u8, preStr, '\n')) |p|
                p + 1
            else
                0;
        const endIndex = std.mem.findScalarPos(
            u8,
            fileContents,
            refStartIndex,
            '\n',
        ) orelse fileContents.len;

        const pre = fileContents[startIndex..refStartIndex];
        const middle = ref.str;
        const end = if (refStartIndex + ref.str.len >= fileContents.len or endIndex > fileContents.len or refStartIndex + ref.str.len > endIndex)
            ""
        else
            fileContents[refStartIndex + ref.str.len .. endIndex];
        return .{
            .before = pre,
            .err = middle,
            .after = end,
        };
    }
};
pub const Spot = struct {
    line: usize,
    col: usize,

    pub fn findRefIn(fileContents: []const u8, ref: FileRef) !Spot {
        const strPtr: usize = @intFromPtr(ref.str.ptr);
        const contentsPtr: usize = @intFromPtr(fileContents.ptr);
        if (strPtr < contentsPtr or strPtr >= contentsPtr + fileContents.len) {
            return error.RefNotFound;
        }

        const preStr = fileContents[0 .. strPtr - contentsPtr];

        const lines = std.mem.countScalar(u8, preStr, '\n') + 1;
        const col = preStr.len - (std.mem.lastIndexOfScalar(u8, preStr, '\n') orelse 0);
        return .{
            .line = lines,
            .col = col,
        };
    }
};

pub const Diagnostic = struct {
    gpa: Allocator,
    from: FileRef,
    message: []const u8 = &.{},
    extraRefs: std.ArrayList(ExtraMessage),
    filename: []const u8,
    const ExtraMessage = struct {
        staticMessage: []const u8,
        ref: FileRef,
        pub fn init(staticStr: []const u8, ref: FileRef) ExtraMessage {
            return .{
                .staticMessage = staticStr,
                .ref = ref,
            };
        }
        pub fn init2(staticStr: []const u8, ref: []const u8) ExtraMessage {
            return .{
                .staticMessage = staticStr,
                .ref = .from(ref),
            };
        }
    };

    pub fn addRef(self: *Diagnostic, e: ExtraMessage) !void {
        try self.extraRefs.append(self.gpa, e);
    }

    pub fn writer(self: *Diagnostic) std.Io.Writer.Allocating {
        return .init(self.gpa);
    }
    pub fn deinit(self: *Diagnostic) void {
        self.gpa.free(self.message);
        self.extraRefs.deinit(self.gpa);
    }

    pub fn print(self: *const Diagnostic, out: *std.Io.Writer, contents: []const u8) !void {
        try out.print("\n\x1b[31mERROR\x1b[0m: {s}\n", .{self.message});
        {
            const spot: Spot = try .findRefIn(contents, self.from);
            try out.print("  NOTE: at {s} line {} column {}\n", .{
                self.filename,
                spot.line,
                spot.col,
            });
            const around: LineParts = try .getLineAround(contents, self.from);
            try out.print(" {: >5} |", .{spot.line});
            // set to normal color undercurl
            try out.print("\x1b[4:3m", .{});
            for (around.before) |c| {
                // tabs dont get undercurl, so replace them with space
                if (c == '\t') {
                    try out.print("    ", .{});
                } else {
                    try out.print("{c}", .{c});
                }
            }
            // switch to red
            try out.print("\x1b[31m", .{});
            try out.print("{s}", .{around.err});
            // switch to normal
            try out.print("\x1b[39m", .{});
            try out.print("{s}", .{around.after});
            // reset
            try out.print("\x1b[0m\n", .{});
        }
        for (self.extraRefs.items) |ref| {
            const spot: Spot = try .findRefIn(contents, ref.ref);
            try out.print("  NOTE: {s} '{s}' at {s} line {} column {}\n", .{
                ref.staticMessage,
                ref.ref.str,
                self.filename,
                spot.line,
                spot.col,
            });
            const around: LineParts = try .getLineAround(contents, ref.ref);
            try out.print(" {: >5} |", .{spot.line});
            // set to normal color undercurl
            try out.print("\x1b[4:3m", .{});
            for (around.before) |c| {
                // tabs dont get undercurl, so replace them with space
                if (c == '\t') {
                    try out.print("    ", .{});
                } else {
                    try out.print("{c}", .{c});
                }
            }
            // switch to blue
            try out.print("\x1b[34m", .{});
            try out.print("{s}", .{around.err});
            // switch to normal
            try out.print("\x1b[39m", .{});
            try out.print("{s}", .{around.after});
            // reset
            try out.print("\x1b[0m\n", .{});
        }

        try out.print("\n\n", .{});
    }
};

pub fn readFileToString(io: std.Io, filename: []const u8, pageAlloc: Allocator) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(
        io,
        filename,
        .{ .mode = .read_only },
    );
    defer file.close(io);

    const stat = try file.stat(io);
    const size = stat.size;

    var buf: [64]u8 = undefined;
    var r = file.reader(io, &buf);

    const contents = try r.interface.readAlloc(pageAlloc, size);
    errdefer pageAlloc.free(contents);

    return contents;
}
