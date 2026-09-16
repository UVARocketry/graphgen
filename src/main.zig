const std = @import("std");
const Io = std.Io;
const f = @import("fileref.zig");
const Allocator = std.mem.Allocator;
const first = @import("passes/first.zig");
const parseOut = @import("parse_txt.zig");
const second = @import("passes/second.zig");
const third = @import("passes/third.zig");
const interpret = @import("passes/interpret.zig");

const debuggraph_zig = @import("debuggraph_zig");

const PlotArgs = struct {
    jsonFile: []const u8,
    outputType: interpret.OutType,
};

pub fn parsePlot(args: []const []const u8, errorStr: *[]const u8) !PlotArgs {
    if (args.len == 0) {
        errorStr.* = "No args given to 'plot'. needed at least a json file!";
        return .{
            .jsonFile = "./gthing2.json",
            .outputType = .human,
        };
    }

    var ret: PlotArgs = .{
        .jsonFile = args[0],
        .outputType = .human,
    };

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--out=bare")) {
            ret.outputType = .bare;
        }
        if (std.mem.eql(u8, arg, "--out=human")) {
            ret.outputType = .human;
        }
        if (std.mem.eql(u8, arg, "--out=none")) {
            ret.outputType = .none;
        }
    }

    return ret;
}

pub fn resultsOf(
    io: Io,
    gpa: Allocator,
    pageAlloc: Allocator,
    stdout: *Io.Writer,
    args: []const []const u8,
) !void {
    var errorStr: []const u8 = "";
    const subArgs = if (args.len >= 3) args[2..] else &.{};
    const plotArgs = parsePlot(subArgs, &errorStr) catch |e| {
        try stdout.print("Error from 'plot' subcommand!\n  {s}", .{errorStr});
        return e;
    };

    std.log.info("Reading {s}\n", .{plotArgs.jsonFile});

    const jsonContents = try f.readFileToString(io, plotArgs.jsonFile, pageAlloc);
    defer pageAlloc.free(jsonContents);

    const p = try first.compilePlotJson(gpa, jsonContents);
    defer p.deinit(gpa);

    for (p.plots) |plot| {
        const path = try Io.Dir.cwd().realPathFileAlloc(io, plot.output.str, gpa);
        defer gpa.free(path);
        try stdout.print("{s}\n", .{path});
    }
}

pub fn doPlot(
    io: Io,
    gpa: Allocator,
    pageAlloc: Allocator,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    args: []const []const u8,
) !void {
    var errorStr: []const u8 = "";
    const subArgs = if (args.len >= 3) args[2..] else &.{};
    const plotArgs = parsePlot(subArgs, &errorStr) catch |e| {
        try stdout.print("Error from 'plot' subcommand!\n  {s}", .{errorStr});
        return e;
    };

    std.log.info("Reading {s}\n", .{plotArgs.jsonFile});

    const jsonContents = try f.readFileToString(io, plotArgs.jsonFile, pageAlloc);
    defer pageAlloc.free(jsonContents);

    var start = std.Io.Clock.awake.now(io);
    const p = try first.compilePlotJson(gpa, jsonContents);
    defer p.deinit(gpa);
    var end = std.Io.Clock.awake.now(io);
    var nanos: f64 = @floatFromInt(start.durationTo(end).nanoseconds);
    std.debug.print("Pass 1 took {}s\n", .{nanos / 1.0e9});

    var diagnostic: f.Diagnostic = .{
        .gpa = gpa,
        .extraRefs = .empty,
        .filename = plotArgs.jsonFile,
        .message = &.{},
        .from = .from(""),
    };
    defer diagnostic.deinit();

    errdefer {
        if (diagnostic.message.len != 0) {
            diagnostic.print(stderr, jsonContents) catch {};
            stderr.flush() catch {};
        }
    }

    const expectedFile = p.plots[0].read.str;
    for (p.plots) |plot| {
        if (!std.mem.eql(u8, plot.read.str, expectedFile)) {
            var w: Io.Writer.Allocating = .init(gpa);
            defer w.deinit();

            try w.writer.print(
                \\Not all file names in '{s}' are the same!
                \\  NOTE: Expected all file names to be '{s}', but got '{s}'
            ,
                .{ plotArgs.jsonFile, expectedFile, plot.read.str },
            );

            diagnostic.message = try w.toOwnedSlice();
            try diagnostic.extraRefs.append(gpa, .init2("Derived expected file from ", expectedFile));
            diagnostic.from = plot.read;
            return error.ExtraFiles;
        }
    }

    var strDiagnostic: ?[]const u8 = null;
    errdefer {
        if (strDiagnostic) |s| {
            stdout.print("{s}\n", .{s}) catch {};
            stdout.flush() catch {};
        }
    }

    start = std.Io.Clock.awake.now(io);
    const cols = try parseOut.parseDbgFile(io, gpa, pageAlloc, p.plots[0].read.str, &strDiagnostic);
    defer {
        for (cols) |*c| {
            c.deinit(gpa);
        }
        gpa.free(cols);
    }
    end = std.Io.Clock.awake.now(io);
    nanos = @floatFromInt(start.durationTo(end).nanoseconds);
    std.debug.print("dbg parse took {}s\n", .{nanos / 1.0e9});

    const file: parseOut.DebugFile = .{
        .data = cols,
        .file = p.plots[0].read.str,
    };
    start = std.Io.Clock.awake.now(io);
    var bytecode = try second.compileToBytecode(gpa, p, file, &diagnostic);
    defer bytecode.deinit(gpa);
    end = std.Io.Clock.awake.now(io);
    nanos = @floatFromInt(start.durationTo(end).nanoseconds);
    std.debug.print("pass 2 took {}s\n", .{nanos / 1.0e9});

    start = std.Io.Clock.awake.now(io);
    var bytecodeReal = try third.compile(gpa, bytecode);
    defer bytecodeReal.deinit(gpa);
    end = std.Io.Clock.awake.now(io);
    nanos = @floatFromInt(start.durationTo(end).nanoseconds);
    std.debug.print("pass 3 took {}s\n", .{nanos / 1.0e9});

    start = std.Io.Clock.awake.now(io);
    try interpret.interpretBytecode(
        stdout,
        gpa,
        bytecodeReal,
        plotArgs.outputType,
    );
    end = std.Io.Clock.awake.now(io);
    nanos = @floatFromInt(start.durationTo(end).nanoseconds);
    std.debug.print("interpret {}s\n", .{nanos / 1.0e9});
}

pub fn listKeys(
    io: Io,
    gpa: Allocator,
    pageAlloc: Allocator,
    stdout: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 3) {
        _ = try stdout.write("Expected a debug_out.txt argument!");
    }
    const filename = if (args.len >= 3) args[2] else "./debug_out.txt";
    var diagnostic: ?[]const u8 = null;

    const v = parseOut.parseDbgFile(io, gpa, pageAlloc, filename, &diagnostic) catch |e| {
        if (diagnostic) |d| {
            defer gpa.free(d);
            try stdout.print("Error while parsing {s}:\n  ", .{filename});
            _ = try stdout.write(d);
            try stdout.flush();
        }
        return e;
    };

    for (v) |col| {
        try stdout.print("{s}\n", .{col.name});
    }

    defer {
        for (v) |*col| {
            col.deinit(gpa);
        }
        gpa.free(v);
    }
}

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024 * 1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    try stdout.flush();

    if (args.len == 1) {
        _ = try stdout.write("need a subcommand: can have 'plot'\n");
        return;
    }

    const subcommand = if (args.len >= 2) args[1] else "plot";

    if (std.mem.eql(u8, subcommand, "plot")) {
        try doPlot(io, init.gpa, std.heap.page_allocator, stdout, stderr, args);
        try stdout.flush();
    } else if (std.mem.eql(u8, subcommand, "list_keys")) {
        try listKeys(io, init.gpa, std.heap.page_allocator, stdout, args);
        try stdout.flush();
    } else if (std.mem.eql(u8, subcommand, "resultsof")) {
        try resultsOf(io, init.gpa, std.heap.page_allocator, stdout, args);
        try stdout.flush();
    } else {
        try stdout.print("unknown subcommand, got '{s}'\n", .{subcommand});
        try stdout.flush();
        return error.UnknownSubcommand;
    }
}
