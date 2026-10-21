const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const debuggraph_zig = @import("debuggraph_zig");
const bc = debuggraph_zig.bc;
const lex = debuggraph_zig.lex;
const f = debuggraph_zig.f;
const first = debuggraph_zig.first;
const parseOut = debuggraph_zig.parseOut;
const second = debuggraph_zig.second;
const third = debuggraph_zig.third;
const interpret = debuggraph_zig.interpret;
const graph = debuggraph_zig.graph;
// const Res = @import("parse/types.zig").Graphs;
const parse = debuggraph_zig.parse;

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

const GraphArgs = struct {
    file: []const u8,
    outputType: graph.OutType,
};

pub fn parseGraphArgs(args: []const []const u8, errorStr: *[]const u8) !GraphArgs {
    if (args.len == 0) {
        errorStr.* = "No args given to 'graph'. needed a .graph file!";
        return error.MissingArgument;
    }

    var ret: GraphArgs = .{
        .file = args[0],
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

fn maxStackUsage(bytecode: *bc.BytecodeInterpreter, graphs: *const graph.Graphs) !u32 {
    var max: u32 = 1;
    for (graphs.graph) |g| {
        max = @max(max, try bytecode.getMaxStackUsage(g.filter.left.value));
        max = @max(max, try bytecode.getMaxStackUsage(g.filter.right.value));
        max = @max(max, try bytecode.getMaxStackUsage(g.x.value));
        for (g.y) |axis| {
            max = @max(max, try bytecode.getMaxStackUsage(axis.value));
        }
        max = @max(max, try bytecode.getMaxStackUsage(g.annotation.line));
        max = @max(max, try bytecode.getMaxStackUsage(g.annotation.x));
        max = @max(max, try bytecode.getMaxStackUsage(g.annotation.y));
        max = @max(max, try bytecode.getMaxStackUsage(g.annotation.value));
    }
    return max;
}

pub fn doGraph(
    io: Io,
    gpa: Allocator,
    pageAlloc: Allocator,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    args: []const []const u8,
) !void {
    var errorStr: []const u8 = "";
    const subArgs = if (args.len >= 3) args[2..] else &.{};
    const graphArgs = parseGraphArgs(subArgs, &errorStr) catch |e| {
        try stdout.print("Error from 'graph' subcommand!\n  {s}\n", .{errorStr});
        return e;
    };

    const graphContents = try f.readFileToString(io, graphArgs.file, pageAlloc);
    defer pageAlloc.free(graphContents);

    var diagnostic: f.Diagnostic = .{
        .gpa = gpa,
        .extraRefs = .empty,
        .filename = graphArgs.file,
        .message = &.{},
        .from = .from(""),
    };
    defer diagnostic.deinit();

    errdefer {
        if (diagnostic.message.len != 0) {
            diagnostic.print(stderr, graphContents) catch {};
            stderr.flush() catch {};
        }
    }

    var parser: parse.ParserPass1 = .{
        .bytecodeStream = .{
            .arr = .empty,
        },
        .keyrefTable = .empty,
        .scope = .empty,
        .lexer = .init(graphContents),
        .paramNames = .empty,
        .bytecodeStarts = .empty,
    };
    parser.paramNames = .initBuffer(&parser.paramNameBuf);
    defer parser.deinit(gpa);

    var parsed = try parser.pass(gpa, graph.Graphs, &diagnostic);
    defer graph.deinit(gpa, &parsed);

    var cache: bc.ValueCache = .init();
    defer cache.deinit(gpa);

    var dummyStack: [1]f32 = undefined;
    var bytecode: bc.BytecodeInterpreter = .{
        .keyrefNames = parser.keyrefTable.items,
        .reader = .{
            .bytecode = parser.bytecodeStream.arr.items,
            .pos = 0,
        },
        .stackAllocator = .failing,
        .valueStack = .initBuffer(&dummyStack),
        .datastoreAllocator = gpa,
        .store = .{
            .maxFrame = 0,
            .leftFrame = .nil,
            .rightFrame = .nil,
            .frames = &.{},
            .cache = &cache,
        },
    };

    const stackSize: usize = @max(try maxStackUsage(&bytecode, &parsed), 8);
    const stack = try gpa.alloc(f32, stackSize);
    defer gpa.free(stack);
    bytecode.valueStack = .initBuffer(stack);

    try graph.run(
        io,
        gpa,
        pageAlloc,
        &parsed,
        stdout,
        &bytecode,
        graphArgs.outputType,
    );
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

pub fn doParse(
    io: Io,
    gpa: Allocator,
    pageAlloc: Allocator,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    args: []const []const u8,
) !void {
    const graphFile = args[2];

    const graphContents = try f.readFileToString(io, graphFile, pageAlloc);
    defer pageAlloc.free(graphContents);

    // var start = std.Io.Clock.awake.now(io);
    // const p = try first.compilePlotJson(gpa, graphContents);
    // defer p.deinit(gpa);
    // const end = std.Io.Clock.awake.now(io);
    // const nanos: f64 = @floatFromInt(start.durationTo(end).nanoseconds);
    // std.debug.print("Pass 1 took {}s\n", .{nanos / 1.0e9});

    var diagnostic: f.Diagnostic = .{
        .gpa = gpa,
        .extraRefs = .empty,
        .filename = graphFile,
        .message = &.{},
        .from = .from(""),
    };
    defer diagnostic.deinit();

    errdefer {
        if (diagnostic.message.len != 0) {
            diagnostic.print(stderr, graphContents) catch {};
            stderr.flush() catch {};
        }
    }

    const lexer: lex.Lexer = .init(graphContents);

    var parser: parse.ParserPass1 = .{
        .bytecodeStream = .{
            .arr = .empty,
        },
        .keyrefTable = .empty,
        .scope = .empty,
        .lexer = lexer,
        .paramNames = .empty,
        .bytecodeStarts = .empty,
    };
    parser.paramNames = .initBuffer(&parser.paramNameBuf);

    defer parser.deinit(gpa);

    var cache: bc.ValueCache = .init();
    defer cache.deinit(gpa);

    var stackBuffer: [6]f32 = undefined;

    var parsed = try parser.pass(gpa, graph.Graphs, &diagnostic);
    defer graph.deinit(gpa, &parsed);

    var bytecode: bc.BytecodeInterpreter = .{
        .keyrefNames = parser.keyrefTable.items,
        .reader = .{
            .bytecode = parser.bytecodeStream.arr.items,
            .pos = 0,
        },
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

    for (parser.scope.items) |item| {
        if (item.bytecodeRef) |ref| {
            bytecode.dbgPrint(ref);
        }
    }

    _ = &parsed;

    _ = try stdout.write("");
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

pub fn cool(
    io: Io,
    gpa: Allocator,
    pageAlloc: Allocator,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    var strDiagnostic: ?[]const u8 = null;
    errdefer {
        if (strDiagnostic) |s| {
            stderr.print("{s}\n", .{s}) catch {};
            stderr.flush() catch {};
        }
    }
    const cols = try parseOut.parseDbgFile(io, gpa, pageAlloc, "./debug_out_v2_22M.txt", &strDiagnostic);
    defer {
        for (cols) |*c| {
            c.deinit(gpa);
        }
        gpa.free(cols);
    }

    var builder: bc.BytecodeBuilder = .{
        .arr = .empty,
    };
    defer builder.arr.deinit(gpa);

    // fn times(a, b) = a * b + a * b;
    // 1 + times(2, 3)

    try builder.addOp(gpa, .{ .isKeyref = true, .rest = .{
        .keyref = .{
            .tp = .fn_arg,
            .rest = .{ .no = 0 },
        },
    } });
    try builder.addType(bc.BytecodeOp.PushTypes.FnArg, gpa, .{
        .argIndex = 1,
    });

    try builder.addOp(gpa, .{ .isKeyref = true, .rest = .{
        .keyref = .{
            .tp = .fn_arg,
            .rest = .{ .no = 0 },
        },
    } });
    try builder.addType(bc.BytecodeOp.PushTypes.FnArg, gpa, .{
        .argIndex = 0,
    });
    try builder.addOp(gpa, .{ .isKeyref = false, .rest = .{ .operation = .times } });

    try builder.addOp(gpa, .{ .isKeyref = true, .rest = .{
        .keyref = .{
            .tp = .fn_arg,
            .rest = .{ .no = 0 },
        },
    } });
    try builder.addType(bc.BytecodeOp.PushTypes.FnArg, gpa, .{
        .argIndex = 1,
    });
    try builder.addOp(gpa, .{ .isKeyref = true, .rest = .{
        .keyref = .{
            .tp = .fn_arg,
            .rest = .{ .no = 0 },
        },
    } });
    try builder.addType(bc.BytecodeOp.PushTypes.FnArg, gpa, .{
        .argIndex = 0,
    });
    try builder.addOp(gpa, .{ .isKeyref = false, .rest = .{ .operation = .times } });

    try builder.addOp(gpa, .{ .isKeyref = false, .rest = .{ .operation = .plus } });

    const fnRef: bc.BytecodeRef = .{
        .start = 0,
        .len = @intCast(builder.arr.items.len),
    };

    try builder.addOp(gpa, .{ .isKeyref = true, .rest = .{ .keyref = .{
        .tp = .keyref,
        .rest = .{
            .keyref = .min,
        },
    } } });
    try builder.addType(bc.BytecodeOp.PushTypes.KeyrefArg, gpa, .{
        .keyrefId = 49,
    });

    try builder.addOp(gpa, .{ .isKeyref = true, .rest = .{
        .keyref = .{
            .tp = .value,
            .rest = .{ .no = 0 },
        },
    } });
    try builder.addType(f32, gpa, 2.0);
    try builder.addOp(gpa, .{ .isKeyref = true, .rest = .{
        .keyref = .{
            .tp = .value,
            .rest = .{ .no = 0 },
        },
    } });
    try builder.addType(f32, gpa, 3.0);

    try builder.addOp(gpa, .{ .isKeyref = false, .rest = .{ .operation = .call } });
    try builder.addType(bc.BytecodeOp.OpTypes.FnCallArgs, gpa, .{
        .bytecode = fnRef,
        .argsPassed = 2,
    });

    try builder.addOp(gpa, .{ .isKeyref = false, .rest = .{ .operation = .plus } });

    const restRef: bc.BytecodeRef = .{
        .start = fnRef.len,
        .len = @intCast(builder.arr.items.len - fnRef.len),
    };

    var bcCols: std.ArrayList(bc.Frame) = try .initCapacity(gpa, cols.len);
    defer bcCols.deinit(gpa);
    var maxFrame: u32 = 0;
    for (cols) |c| {
        const frameCount: u32 = @intCast(c.values.len + c.skip);
        maxFrame = @max(frameCount, maxFrame);
        // std.debug.print("{s}\n", .{c.name});
        bcCols.appendAssumeCapacity(.{
            .values = c.values,
            .skip = c.skip,
        });
    }

    var cache: bc.ValueCache = .init();
    defer cache.deinit(gpa);

    var stackBuffer: [6]f32 = undefined;

    const keyrefNames = try gpa.alloc([]const u8, cols.len);
    defer gpa.free(keyrefNames);
    for (cols, 0..) |c, i| keyrefNames[i] = c.name;

    var bytecode: bc.BytecodeInterpreter = .{
        .keyrefNames = keyrefNames,
        .reader = .{
            .bytecode = builder.arr.items,
            .pos = 0,
        },
        .stackAllocator = .failing,
        .valueStack = .initBuffer(&stackBuffer),
        .datastoreAllocator = gpa,
        .store = .{
            .maxFrame = maxFrame,
            .leftFrame = .nil,
            .rightFrame = .nil,
            .frames = bcCols.items,
            .cache = &cache,
        },
    };

    std.debug.print("Stack usage: {}\n", .{try bytecode.getMaxStackUsage(restRef)});

    const value = try bytecode.execRange(restRef, 3);
    try stdout.print("{}\n", .{value});
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
    var stdout_buffer: [64]u8 = undefined;
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
    } else if (std.mem.eql(u8, subcommand, "parse")) {
        try doParse(io, init.gpa, std.heap.page_allocator, stdout, stderr, args);
        try stdout.flush();
    } else if (std.mem.eql(u8, subcommand, "graph")) {
        try doGraph(io, init.gpa, std.heap.page_allocator, stdout, stderr, args);
        try stdout.flush();
    } else if (std.mem.eql(u8, subcommand, "list_keys")) {
        try listKeys(io, init.gpa, std.heap.page_allocator, stdout, args);
        try stdout.flush();
    } else if (std.mem.eql(u8, subcommand, "resultsof")) {
        try resultsOf(io, init.gpa, std.heap.page_allocator, stdout, args);
    } else if (std.mem.eql(u8, subcommand, "cool")) {
        try cool(io, init.gpa, std.heap.page_allocator, stdout, stderr);
        try stdout.flush();
    } else {
        try stdout.print("unknown subcommand, got '{s}'\n", .{subcommand});
        try stdout.flush();
        return error.UnknownSubcommand;
    }
}
