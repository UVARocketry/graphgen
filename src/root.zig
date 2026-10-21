//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
pub const bc = @import("parse/bytecode.zig");
pub const lex = @import("parse/lexer.zig");
pub const f = @import("fileref.zig");
pub const first = @import("passes/first.zig");
pub const parseOut = @import("parse_txt.zig");
pub const second = @import("passes/second.zig");
pub const third = @import("passes/third.zig");
pub const interpret = @import("passes/interpret.zig");
pub const graph = @import("backends/graph.zig");
// const Res = @import("parse/types.zig").Graphs;
pub const parse = @import("parse/parse.zig");

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}
_: std.testing.refAllDecls(bc),
test {
    _ = bc;
    std.testing.refAllDecls(graph);
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test "typed parse" {
    const gpa = std.testing.allocator;
    const types = @import("parse/types.zig");
    const T = struct {
        name: []const u8,
        count: f32,
        mode: enum { a, b },
        inner: struct { x: f32 },
        items: []f32,
        value: types.Bytecode,
    };
    const src =
        \\name "hi"
        \\count -2.5
        \\mode a
        \\inner {
        \\  x 1
        \\}
        \\items 1
        \\items 2
        \\value = .foo + 1
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

    const value = try parser.pass(gpa, T, &diagnostic);
    defer gpa.free(value.items);

    try std.testing.expectEqualStrings("hi", value.name);
    try std.testing.expectEqual(@as(f32, -2.5), value.count);
    try std.testing.expectEqual(@FieldType(T, "mode").a, value.mode);
    try std.testing.expectEqual(@as(f32, 1), value.inner.x);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, value.items);
    try std.testing.expectEqual(@as(u16, 0), value.value.start);
    try std.testing.expect(value.value.len > 0);
}
