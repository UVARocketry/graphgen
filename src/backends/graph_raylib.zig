const bc = @import("../parse/bytecode.zig");
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../parse/types.zig");
const parseOut = @import("../parse_txt.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const rl = @import("raylib");

const Graphs = @import("./graph.zig").Graphs;
const actualRun = @import("./graph.zig").run;
const OutType = @import("./graph.zig").OutType;
const Annotation = struct {
    x: f32,
    y: f32,
    text: []const u8,
    dx: f32,
    dy: f32,
};

/// Frees the slices allocated by the parser. String fields point into the
/// source file and are not freed here.
pub fn deinit(alloc: Allocator, graphs: *const Graphs) void {
    for (graphs.graph) |graph| {
        alloc.free(graph.y);
        for (graph.annotation) |an| {
            alloc.free(an.value);
        }
        alloc.free(graph.annotation);
    }
    alloc.free(graphs.graph);
}

const FrameStat = struct {
    frame: i32 = -1,
    value: f32 = 0,
};

const AnnotationStats = struct {
    first: FrameStat = .{},
    last: FrameStat = .{},
    max: FrameStat = .{},
    min: FrameStat = .{},
    hasLineData: bool = false,
};

/// Picks a "nice" gridline interval (1, 2 or 5 times a power of ten) that
/// roughly divides `range` into `targetTicks` segments.
fn niceStep(range: f32, targetTicks: f32) f32 {
    const rough = range / targetTicks;
    if (!std.math.isFinite(rough) or rough <= 0) return 1;
    const magnitude = std.math.pow(f32, 10, @floor(std.math.log10(rough)));
    const normalized = rough / magnitude;
    const nice: f32 = if (normalized < 1.5) 1 else if (normalized < 3) 2 else if (normalized < 7) 5 else 10;
    return nice * magnitude;
}

fn drawXTick(
    img: *rl.Image,
    font: rl.Font,
    gpa: Allocator,
    value: f32,
    px: f32,
    plotTop: f32,
    plotBottom: f32,
    tickLength: f32,
) !void {
    rl.imageDrawLineEx(img, .init(px, plotTop), .init(px, plotBottom), 1, .light_gray);
    rl.imageDrawLineEx(img, .init(px, plotBottom), .init(px, plotBottom + tickLength), 2, .black);

    const tickStr = try std.fmt.allocPrintSentinel(gpa, "{}", .{value}, 0);
    defer gpa.free(tickStr);

    const info = rl.measureTextEx(font, tickStr, 20, 2);
    rl.imageDrawTextEx(
        img,
        font,
        tickStr,
        .init(px - info.x / 2, plotBottom + tickLength),
        20,
        2,
        .black,
    );
}

fn drawYTick(
    img: *rl.Image,
    font: rl.Font,
    gpa: Allocator,
    value: f32,
    py: f32,
    plotLeft: f32,
    plotRight: f32,
    tickLength: f32,
) !void {
    rl.imageDrawLineEx(img, .init(plotLeft, py), .init(plotRight, py), 1, .light_gray);
    rl.imageDrawLineEx(img, .init(plotLeft - tickLength, py), .init(plotLeft, py), 2, .black);

    const tickStr = try std.fmt.allocPrintSentinel(gpa, "{}", .{value}, 0);
    defer gpa.free(tickStr);

    const info = rl.measureTextEx(font, tickStr, 20, 2);
    rl.imageDrawTextEx(
        img,
        font,
        tickStr,
        .init(plotLeft - tickLength - 10 - info.x, py - info.y / 2),
        20,
        2,
        .black,
    );
}

const LegendPos = enum {
    top_left,
    top_center,
    top_right,
    right_center,
    bottom_right,
    bottom_center,
    bottom_left,
    left_center,
};

/// Places a `size` box at one of the eight legend slots inside `area`.
fn legendRect(pos: LegendPos, area: rl.Rectangle, size: rl.Vector2, margin: f32) rl.Rectangle {
    const left = area.x + margin;
    const right = area.x + area.width - margin - size.x;
    const top = area.y + margin;
    const bottom = area.y + area.height - margin - size.y;
    const centerX = area.x + (area.width - size.x) / 2;
    const centerY = area.y + (area.height - size.y) / 2;

    const x = switch (pos) {
        .top_left, .bottom_left, .left_center => left,
        .top_center, .bottom_center => centerX,
        .top_right, .right_center, .bottom_right => right,
    };
    const y = switch (pos) {
        .top_left, .top_center, .top_right => top,
        .left_center, .right_center => centerY,
        .bottom_left, .bottom_center, .bottom_right => bottom,
    };
    return .{ .x = x, .y = y, .width = size.x, .height = size.y };
}

fn pointInRect(p: rl.Vector2, r: rl.Rectangle) bool {
    return p.x >= r.x and p.x <= r.x + r.width and p.y >= r.y and p.y <= r.y + r.height;
}

fn imageLineExSafe(img: *rl.Image, p1: rl.Vector2, p2: rl.Vector2, thick: i32, color: rl.Color) void {
    // raylib's ImageDrawLine shifts the shorter axis delta left by 16, which is
    // undefined behaviour for negative values. Replicate its integer rounding
    // and branch selection, then order the points so the shorter delta used by
    // each branch is non-negative.
    const x1: i32 = @intFromFloat(p1.x + 0.5);
    const y1: i32 = @intFromFloat(p1.y + 0.5);
    const x2: i32 = @intFromFloat(p2.x + 0.5);
    const y2: i32 = @intFromFloat(p2.y + 0.5);
    const dx = x2 - x1;
    const dy = y2 - y1;
    const adx = @abs(dx);
    const ady = @abs(dy);
    const vertical = dx == 0 or ady >= adx;
    const swap = if (vertical)
        (if (ady > adx) dx < 0 else dy < 0)
    else
        dy < 0;
    if (swap) {
        rl.imageDrawLineEx(img, p2, p1, thick, color);
    } else {
        rl.imageDrawLineEx(img, p1, p2, thick, color);
    }
}

fn readGraph(reader: *std.Io.Reader, gpa: Allocator) !void {
    try expectStr(reader, "CHART\n");
    try expectStr(reader, "SAVE:");
    const savePath = try reader.takeDelimiterExclusive('\n');
    _ = try reader.take(1);
    try expectStr(reader, "TITLE:");
    const title = try reader.takeDelimiterExclusive('\n');
    _ = try reader.take(1);
    try expectStr(reader, "x:");
    const xtitle = try reader.takeDelimiterExclusive('\n');
    _ = try reader.take(1);
    try expectStr(reader, "ylabel:");
    const ylabel = try reader.takeDelimiterExclusive('\n');
    _ = try reader.take(1);
    try expectStr(reader, "width:0\n");
    try expectStr(reader, "height:0\n");
    try expectStr(reader, "dpi:0\n");
    try expectStr(reader, "font.title:");
    const titleFontStr = try reader.takeDelimiterExclusive('\n');
    _ = titleFontStr;
    _ = try reader.take(1);
    try expectStr(reader, "font.xlabel:");
    const xlabelFontStr = try reader.takeDelimiterExclusive('\n');
    _ = xlabelFontStr;
    _ = try reader.take(1);
    try expectStr(reader, "font.ylabel:");
    const ylabelFontStr = try reader.takeDelimiterExclusive('\n');
    _ = ylabelFontStr;
    _ = try reader.take(1);
    try expectStr(reader, "font.legend:");
    const legendFontStr = try reader.takeDelimiterExclusive('\n');
    _ = legendFontStr;
    _ = try reader.take(1);
    try expectStr(reader, "font.tick:");
    const tickFontStr = try reader.takeDelimiterExclusive('\n');
    _ = tickFontStr;
    _ = try reader.take(1);

    const yCountStr = try reader.takeDelimiterExclusive('\n');
    _ = try reader.take(1);
    const yCount = try std.fmt.parseInt(u32, yCountStr, 10);
    const yNames = try gpa.alloc([]const u8, yCount);
    defer gpa.free(yNames);

    for (0..yCount) |i| {
        try expectStr(reader, "y:");
        const yaxisName = try reader.takeDelimiterExclusive('\n');
        _ = try reader.take(1);
        yNames[i] = yaxisName;
    }

    var hasPoints = false;
    var minX: f32 = 0.0;
    var maxX: f32 = 0.0;
    var minY: f32 = 0.0;
    var maxY: f32 = 0.0;
    var floatArray: std.ArrayList(f32) = .empty;
    defer floatArray.deinit(gpa);
    const bareEndSignal = "\x7F\x80\xAB\xCD";
    while (true) {
        const next = try reader.peek(bareEndSignal.len);
        if (std.mem.eql(u8, next, bareEndSignal)) {
            _ = try reader.take(bareEndSignal.len);
            break;
        }
        const bytes = try reader.take(@sizeOf(f32) * (yCount + 1));
        const floats: []align(1) const f32 = @ptrCast(bytes);
        if (!hasPoints) {
            hasPoints = true;
            minX = floats[0];
            maxX = floats[0];

            minY = floats[1];
            maxY = floats[1];
            for (floats[2..]) |f| {
                maxY = @max(maxY, f);
                minY = @min(minY, f);
            }
        } else {
            minX = @min(minX, floats[0]);
            maxX = @max(maxX, floats[0]);
            for (floats[1..]) |f| {
                maxY = @max(maxY, f);
                minY = @min(minY, f);
            }
        }
        try floatArray.appendUnalignedSlice(gpa, floats);
    }

    var annotations: std.ArrayList(Annotation) = .empty;
    defer annotations.deinit(gpa);

    if (try matchesNext(reader, "ANNOTATIONS\n")) {
        const countStr = try reader.takeDelimiterExclusive('\n');
        _ = try reader.take(1);

        const count = try std.fmt.parseInt(u32, countStr, 10);
        for (0..count) |_| {
            if (try matchesNext(reader, "SKIP\n")) continue;

            try expectStr(reader, "x:");
            const xStr = try reader.takeDelimiterExclusive('\n');
            _ = try reader.take(1);
            const x = try std.fmt.parseFloat(f32, xStr);

            try expectStr(reader, "y:");
            const yStr = try reader.takeDelimiterExclusive('\n');
            _ = try reader.take(1);
            const y = try std.fmt.parseFloat(f32, yStr);

            try expectStr(reader, "text:\n");
            try expectStr(reader, "BEGIN\n");
            const str = try reader.takeDelimiterExclusive('\n');
            _ = try reader.take(1);
            try expectStr(reader, "END\n");
            try expectStr(reader, "type:text\n");

            try expectStr(reader, "arrow.dx:");
            const dxStr = try reader.takeDelimiterExclusive('\n');
            _ = try reader.take(1);
            const dx = try std.fmt.parseFloat(f32, dxStr);

            try expectStr(reader, "arrow.dy:");
            const dyStr = try reader.takeDelimiterExclusive('\n');
            _ = try reader.take(1);
            std.debug.print("dy: {s}\n", .{dyStr});
            const dy = try std.fmt.parseFloat(f32, dyStr);

            if (try matchesNext(reader, "style.color:")) {
                _ = try reader.takeDelimiterInclusive('\n');
            }
            if (try matchesNext(reader, "style.fontsize:")) {
                _ = try reader.takeDelimiterInclusive('\n');
            }
            if (try matchesNext(reader, "style.bbox.boxstyle:")) {
                _ = try reader.takeDelimiterInclusive('\n');
            }
            if (try matchesNext(reader, "style.bbox.facecolor:")) {
                _ = try reader.takeDelimiterInclusive('\n');
            }
            if (try matchesNext(reader, "style.bbox.alpha:")) {
                _ = try reader.takeDelimiterInclusive('\n');
            }

            try annotations.append(gpa, .{
                .x = x,
                .y = y,
                .text = str,
                .dx = dx,
                .dy = dy,
            });
        }
    }

    try expectStr(reader, "END\n");

    const mainWidth: i32 = 1600;
    const xRange = @ceil(maxX - minX);
    const mainHeight: i32 = 1000;
    const yRange = @ceil(maxY - minY);

    const xScale = @as(f32, @floatFromInt(mainWidth)) / xRange;
    const yScale = @as(f32, @floatFromInt(mainHeight)) / yRange;
    const hpad: i32 = 40;
    const leftExtra = 70;
    const vpad: i32 = 60;

    const ihpad: i32 = 20;
    const ivpad: i32 = 20;
    var img = rl.genImageColor(
        leftExtra + mainWidth + hpad * 2 + ihpad * 2,
        mainHeight + vpad * 2 + ivpad * 2,
        .white,
    );
    rl.setConfigFlags(.{ .window_hidden = true });
    rl.initWindow(1, 1, "graphgen");
    defer rl.closeWindow();

    // outer border
    rl.imageDrawLineEx(
        &img,
        .init(hpad + leftExtra, vpad),
        .init(hpad + leftExtra, vpad + mainHeight + ivpad * 2),
        2.0,
        .black,
    );
    rl.imageDrawLineEx(
        &img,
        .init(hpad + leftExtra, vpad),
        .init(hpad + leftExtra + mainWidth + ihpad * 2, vpad),
        2.0,
        .black,
    );
    rl.imageDrawLineEx(
        &img,
        .init(hpad + leftExtra + mainWidth + ihpad * 2, vpad),
        .init(hpad + leftExtra + mainWidth + ihpad * 2, vpad + mainHeight + ivpad * 2),
        2.0,
        .black,
    );
    rl.imageDrawLineEx(
        &img,
        .init(hpad + leftExtra, vpad + mainHeight + ivpad * 2),
        .init(hpad + leftExtra + mainWidth + ihpad * 2, vpad + mainHeight + ivpad * 2),
        2.0,
        .black,
    );

    const font = try rl.getFontDefault();
    if (title.len != 0) {
        const titleZ = try gpa.dupeSentinel(u8, title, 0);
        defer gpa.free(titleZ);
        const info = rl.measureTextEx(font, titleZ, 30, 2);
        const totalWidth = mainWidth + leftExtra + hpad * 2 + ihpad * 2;
        std.debug.print("{s}\n", .{titleZ});
        rl.imageDrawTextEx(
            &img,
            font,
            titleZ,
            .init(totalWidth / 2 - info.x / 2, 20 - info.y / 2),
            30,
            2,
            .black,
        );
    }

    if (xtitle.len != 0) {
        const titleZ = try gpa.dupeSentinel(u8, xtitle, 0);
        defer gpa.free(titleZ);
        const info = rl.measureTextEx(font, titleZ, 20, 2);
        const totalWidth = mainWidth + leftExtra + hpad * 2 + ihpad * 2;
        const totalHeight = mainHeight + vpad * 2 + ivpad * 2;
        std.debug.print("{s}\n", .{titleZ});
        rl.imageDrawTextEx(
            &img,
            font,
            titleZ,
            .init(totalWidth / 2 - info.x / 2, totalHeight - 20 - info.y / 2),
            20,
            2,
            .black,
        );
    }

    if (ylabel.len != 0) {
        const titleZ = try gpa.dupeSentinel(u8, ylabel, 0);
        defer gpa.free(titleZ);
        std.debug.print("ylabel {s}\n", .{titleZ});

        // raylib's ImageDrawTextPro is an unimplemented stub, so render the
        // text to a temporary image, rotate it, then blit it into place.
        var label = try rl.imageTextEx(font, titleZ, 20, 2, .black);
        defer rl.unloadImage(label);
        rl.imageRotateCCW(&label);

        const cx = @divTrunc(30, 2) - @divTrunc(label.width, 2);
        const cy = @divTrunc(vpad + mainHeight, 2) - @divTrunc(label.height, 2);
        rl.imageDrawImage(&img, label, cx, cy, .white);
    }

    // gridlines and axis ticks
    const plotLeft: f32 = @floatFromInt(hpad + leftExtra);
    const plotTop: f32 = @floatFromInt(vpad);
    const plotRight = plotLeft + @as(f32, @floatFromInt(mainWidth + ihpad * 2));
    const plotBottom = plotTop + @as(f32, @floatFromInt(mainHeight + ivpad * 2));
    const minYValue = maxY - yRange;
    const tickLength: f32 = 8.0;

    const xStep = niceStep(xRange, 10);
    var xTick = @ceil(minX / xStep) * xStep;
    var lastXTick: ?f32 = null;
    while (xTick <= minX + xRange + xStep * 0.01) : (xTick += xStep) {
        const px = plotLeft + (xTick - minX) * xScale + ihpad;
        try drawXTick(&img, font, gpa, xTick, px, plotTop, plotBottom, tickLength);
        lastXTick = xTick;
    }
    // If the data max covers more than 30% of the region after the last
    // regular tick, mark the max itself so that region isn't left unlabelled.
    if (lastXTick) |last| {
        if ((maxX - last) / xStep > 0.5) {
            const px = plotLeft + (maxX - minX) * xScale + ihpad;
            try drawXTick(&img, font, gpa, maxX, px, plotTop, plotBottom, tickLength);
        }
    }

    const yStep = niceStep(yRange, 8);
    var yTick = @ceil(minYValue / yStep) * yStep;
    var lastYTick: ?f32 = null;
    while (yTick <= maxY + yStep * 0.01) : (yTick += yStep) {
        const py = plotTop + (maxY - yTick) * yScale + ivpad;
        try drawYTick(&img, font, gpa, yTick, py, plotLeft, plotRight, tickLength);
        lastYTick = yTick;
    }
    if (lastYTick) |last| {
        if ((maxY - last) / yStep > 0.5) {
            try drawYTick(&img, font, gpa, maxY, plotTop, plotLeft, plotRight, tickLength);
        }
    }

    std.debug.print("w, h: {}, {}\n", .{ mainWidth, mainHeight });

    const colors: []const rl.Color = &[_]rl.Color{
        .green,
        .blue,
        .red,
        .orange,
        .purple,
        .brown,
        .yellow,
        .purple,
        .pink,
        .magenta,
    };

    for (0..floatArray.items.len / (yCount + 1)) |row| {
        const baseI = row * (yCount + 1);
        const nextBaseI = (row + 1) * (yCount + 1);
        if (nextBaseI >= floatArray.items.len) break;
        const x: f32 = floatArray.items[baseI] - minX;
        const nextX: f32 = floatArray.items[nextBaseI] - minX;
        for (baseI + 1..nextBaseI, 0..) |yIndex, yKind| {
            const y: f32 = maxY - floatArray.items[yIndex];
            const nextY: f32 = maxY - floatArray.items[yIndex + yCount + 1];
            const p1: rl.Vector2 = .init(
                x * xScale + hpad + ihpad + leftExtra,
                y * yScale + vpad + ivpad,
            );
            const p2: rl.Vector2 = .init(
                nextX * xScale + hpad + ihpad + leftExtra,
                nextY * yScale + vpad + ivpad,
            );
            imageLineExSafe(&img, p1, p2, 3.0, colors[yKind % colors.len]);
        }
    }

    if (yCount > 0) {
        const legendFontSize: f32 = 20;
        const legendPad: f32 = 10;
        const swatchWidth: f32 = 28;
        const swatchGap: f32 = 10;
        const rowHeight: f32 = 28;

        const nameZ = try gpa.alloc([:0]u8, yCount);
        defer {
            for (nameZ) |z| gpa.free(z);
            gpa.free(nameZ);
        }

        var maxNameWidth: f32 = 0;
        for (yNames, 0..) |name, i| {
            nameZ[i] = try gpa.dupeSentinel(u8, name, 0);
            if (nameZ[i].len == 0) continue;

            // Measure the actual rendered bitmap: MeasureTextEx undercounts the
            // spacing once the image gets scaled up to the draw size.
            const probe = try rl.imageTextEx(font, nameZ[i], legendFontSize, 2, .black);
            defer rl.unloadImage(probe);
            maxNameWidth = @max(maxNameWidth, @as(f32, @floatFromInt(probe.width)));
        }

        const legendSize: rl.Vector2 = .init(
            legendPad * 2 + swatchWidth + swatchGap + maxNameWidth,
            legendPad * 2 + rowHeight * @as(f32, @floatFromInt(yCount)),
        );
        const plotArea: rl.Rectangle = .{
            .x = @floatFromInt(hpad + leftExtra + ihpad),
            .y = @floatFromInt(vpad + ivpad),
            .width = @floatFromInt(mainWidth),
            .height = @floatFromInt(mainHeight),
        };
        const legendMargin: f32 = 12;

        const positions = [_]LegendPos{
            .top_left,     .top_center,    .top_right,   .right_center,
            .bottom_right, .bottom_center, .bottom_left, .left_center,
        };
        var bestPos: LegendPos = .top_left;
        var bestScore: usize = std.math.maxInt(usize);

        // Score each slot by how many data samples fall inside it and pick
        // the emptiest one.
        const frameCount = floatArray.items.len / (yCount + 1);
        for (positions) |pos| {
            const r = legendRect(pos, plotArea, legendSize, legendMargin);
            var score: usize = 0;
            for (0..frameCount) |row| {
                const baseI = row * (yCount + 1);
                const nextBaseI = (row + 1) * (yCount + 1);
                for (0..yCount) |kind| {
                    const px = (floatArray.items[baseI] - minX) * xScale + hpad + ihpad + leftExtra;
                    const py = (maxY - floatArray.items[baseI + 1 + kind]) * yScale + vpad + ivpad;
                    if (pointInRect(.init(px, py), r)) score += 1;

                    if (nextBaseI < floatArray.items.len) {
                        const npx = (floatArray.items[nextBaseI] - minX) * xScale + hpad + ihpad + leftExtra;
                        const npy = (maxY - floatArray.items[nextBaseI + 1 + kind]) * yScale + vpad + ivpad;
                        if (pointInRect(.init((px + npx) / 2, (py + npy) / 2), r)) score += 1;
                    }
                }
            }
            if (score < bestScore) {
                bestScore = score;
                bestPos = pos;
            }
        }

        const r = legendRect(bestPos, plotArea, legendSize, legendMargin);
        rl.imageDrawRectangleRec(&img, r, .white);
        rl.imageDrawRectangleLinesEx(&img, r, 2, .black);

        for (nameZ, 0..) |name, i| {
            const cy = r.y + legendPad + (@as(f32, @floatFromInt(i)) + 0.5) * rowHeight;
            rl.imageDrawLineEx(
                &img,
                .init(r.x + legendPad, cy),
                .init(r.x + legendPad + swatchWidth, cy),
                3,
                colors[i % colors.len],
            );
            const info = rl.measureTextEx(font, name, legendFontSize, 2);
            rl.imageDrawTextEx(
                &img,
                font,
                name,
                .init(r.x + legendPad + swatchWidth + swatchGap, cy - info.y / 2),
                legendFontSize,
                2,
                .black,
            );
        }
    }

    for (annotations.items) |an| {
        const x = an.x - minX;
        const endX = an.x - minX + an.dx;

        const y = maxY - an.y;
        const endY = maxY - an.y - an.dy;

        const p1: rl.Vector2 = .init(
            x * xScale + hpad + ihpad + leftExtra,
            y * yScale + vpad + ivpad,
        );

        const p2: rl.Vector2 = .init(
            endX * xScale + hpad + ihpad + leftExtra,
            endY * yScale + vpad + ivpad,
        );

        const dir = p2.subtract(p1).normalize();

        const angle = std.math.atan2(dir.y, -dir.x);
        std.debug.print("AN ANGLE: {}\n", .{angle * 180 / std.math.pi});
        std.debug.print("AN ANGLE: {}\n", .{dir});
        const dirLeft = dir.rotate(30.0 * std.math.pi / 180.0);
        const dirRight = dir.rotate(-30 * std.math.pi / 180.0);

        const rp1 = p1.add(dir.multiply(.init(6, 6)));
        const rp2 = p2.subtract(dir.multiply(.init(6, 6)));

        const endLeft = rp1.add(dirLeft.multiply(.init(12, 12)));
        imageLineExSafe(&img, rp1, endLeft, 3.0, .black);

        const endRight = rp1.add(dirRight.multiply(.init(12, 12)));
        imageLineExSafe(&img, rp1, endRight, 3.0, .black);

        imageLineExSafe(&img, rp1, rp2, 3.0, .black);

        const text = try gpa.dupeSentinel(u8, an.text, 0);
        defer gpa.free(text);

        const info = rl.measureTextEx(font, text, 20, 2);
        const textPos = p2.add(.init(0, if (an.dy < 0) 3 else -info.y - 3));
        rl.imageDrawTextEx(&img, font, text, textPos, 20, 2, .black);
    }

    const saveZ = try gpa.dupeSentinel(u8, savePath, 0);
    defer gpa.free(saveZ);
    std.debug.print("Saving to: {s}\n", .{saveZ});
    const exp = rl.exportImage(img, saveZ);
    std.debug.print("Exp: {}\n", .{exp});
    rl.unloadImage(img);
}

fn expectStr(reader: *std.Io.Reader, str: []const u8) !void {
    const buf = try reader.take(str.len);
    if (!std.mem.eql(u8, buf, str)) {
        @branchHint(.unlikely);
        std.debug.print("{s}  {s}\n", .{ buf, str });
    }
}
fn matchesNext(reader: *std.Io.Reader, str: []const u8) !bool {
    const buf = try reader.peek(str.len);
    if (std.mem.eql(u8, buf, str)) {
        @branchHint(.unlikely);
        _ = try reader.take(str.len);
        return true;
    }
    return false;
}

pub fn run(
    io: Io,
    gpa: Allocator,
    pageAlloc: Allocator,
    graphs: *const Graphs,
    writer: *Io.Writer,
    bytecode: *bc.BytecodeInterpreter,
    outputType: OutType,
) !void {
    _ = writer;
    _ = outputType;
    var allocW: std.Io.Writer.Allocating = .init(gpa);
    defer allocW.deinit();

    rl.setTraceLogLevel(.none);

    try actualRun(io, gpa, pageAlloc, graphs, &allocW.writer, bytecode, .bare);

    var reader: std.Io.Reader = .fixed(allocW.written());
    while (true) {
        readGraph(&reader, gpa) catch |e| switch (e) {
            error.EndOfStream => break,
            error.ReadFailed => return e,
            error.OutOfMemory => return e,
            error.Overflow => return e,
            error.StreamTooLong => return e,
            error.InvalidCharacter => return e,
            error.LoadFont => return e,
            error.LoadImage => return e,
        };
    }
}
