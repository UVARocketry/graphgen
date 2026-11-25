const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

// bytecode format:
//
// |-- header --|-- payload --|
// |     1b     |   n bytes   |
// |------------|-------------|
//
// the idea is that there is a 1 byte operand and then between 0 and n bytes of payload
//
// operand format (in order of lsb to msb):
//
// - bit 1: set to 1 if it is a push operation (eg add a value to the stack), set to 0
//   for operations that pop off the stack and then push results onto the stack
// - next 7 bits are different depending on bit 1
//
// if bit 1 is 0, the next 7 are an enum that determines what the operation is, for
// example, the "plus" operation POPs two values off the stack then PUSHes their sum
//
// if bit 1 is 1, we have to go down a few more turtles:
//  next two bits are specify the push type: keyref, axis, value, fn_arg
//  - if keyref or axis, the next 5 bits specify how to access that variable:
//      - first, last, min, max, mean, current, prev, etc
//          - eg .keyref .first could mean something like .timestamp_s:first
//  - for .value and .fn_arg, the next 5 bits are undefined
//
// All PUSH operations have a payload. The size and type of that payload is entirely
// determined by the push type enum:
//  - .keyref PUSH is followed by an 8 bit keyref id (an index into the keyref table
//      given by parse_txt.zig:parseDbgFile)
//  - .axis PUSH is followed by a 32 bit bytecode ref (16 bits of the starting index
//      in the bytecode array and 16 bits for the length). the idea with this is that
//      we can have an axis and then create annotations based on that axis by just
//      executing the axis's bytecode to determine location and value of annotations.
//      the access type stored in the operand decides how the axis's per frame values
//      become the pushed value: .current/.prev evaluate the bytecode at that single
//      frame, while first/last/min/max/mean reduce it across the frame window held
//      in the DataStore (nan frames are ignored, an all nan window pushes nan)
//  - .value PUSH is followed by a 32 bit float
//  - .fn_arg PUSH is followed by an 8 bit arg index, arg indices are reverse indexed
//      (so 0 means the last argument)
//
// the only non-PUSH operation to have a payload is .call:
//  - the payload is a 32 bit BytecodeRef (as described earlier) that refers to the
//      contents of the function, along with 16 bits for the number of args passed

// debug info? alongside the byte stream?

// callconv:
//
// PUSH args in left to right order then CALL(fn start, fn len, n)
//
// inside function:
//
// EAT_ARGS(n) where n is number of args (optionally do a sanity check that args passed is correct)
// then for when using function arg, PUSH FN_ARG(n) where n is the index of arg

pub const BytecodeRef = types.Bytecode;

pub const BytecodeOp = packed struct(u8) {
    pub const PushTypes = packed struct(u7) {
        pub const KeyrefArg = packed struct(u8) {
            keyrefId: u8,
        };

        pub const AxisArg = BytecodeRef;

        pub const Value = f32;

        comptime {
            std.debug.assert(@sizeOf(AxisArg) == @sizeOf(Value));
        }

        pub const FnArg = packed struct(u8) {
            argIndex: u8,
        };

        pub const Tp = enum(u2) {
            keyref,
            axis,
            value,
            fn_arg,
        };

        pub const AccessType = enum(u5) {
            first,
            last,
            min,
            max,
            mean,
            current,
            prev,

            pub fn toSaveType(s: AccessType) SaveTypes {
                return switch (s) {
                    .first => .first,
                    .last => .last,
                    .min => .min,
                    .max => .max,
                    .mean => .mean,
                    .current => @panic("no"),
                    .prev => @panic("no 2"),
                };
            }
        };

        tp: Tp,
        rest: packed union(u5) {
            keyref: AccessType,
            axis: AccessType,
            no: u5,
        },
    };

    pub const OpTypes = enum(u7) {
        pub const FnCallArgs = struct {
            bytecode: BytecodeRef,
            argsPassed: u16,
        };
        /// POP 1, PUSH -s[0]
        negate,
        /// POP 2, push s[1] + s[0]
        plus,
        /// POP 2, push s[1] - s[0]
        minus,
        /// POP 2, push s[1] * s[0]
        times,
        /// POP 2, push s[1] / s[0]
        div,
        /// eat a BytecodeRef and then args len then execute it.
        /// After execution, POP retval, POP [argslen], PUSH retval
        call,
        /// POP 1, push ln(s[0])
        sp_ln,
        /// POP 1, push e^s[0]
        sp_exp,
        /// POP 2, push max(s[1], s[0])
        sp_max,
        /// POP 2, push min(s[1], s[0])
        sp_min,
        /// POP 1, push sqrt(s[0])
        sp_sqrt,
        /// POP 1, push abs(s[0])
        sp_abs,
        /// POP 2, push s[1]^s[0]
        sp_pow,
        /// POP 2, push nan if s[1] < s[0], else push s[1]
        gte,
        /// POP 2, push nan if s[1] <= s[0], else push s[1]
        gt,
        /// POP 2, push nan if s[1] > s[0], else push s[1]
        lte,
        /// POP 2, push nan if s[1] >= s[0], else push s[1]
        lt,
        /// POP 3, push s[1] if s[0], else push s[2]
        sp_if,

        pub fn isSpecialFn(self: OpTypes) bool {
            const tag = @tagName(self);
            if (std.mem.startsWith(u8, tag, "sp_")) return true;
            return false;
        }
        pub fn argCountOf(self: OpTypes) ?u16 {
            return switch (self) {
                .sp_ln, .sp_exp, .sp_sqrt, .sp_abs => 1,
                .sp_max, .sp_min, .sp_pow => 2,
                .sp_if => 3,
                .negate, .plus, .minus, .times, .div, .call, .gte, .gt, .lte, .lt => null,
            };
        }
    };

    isKeyref: bool,

    rest: packed union(u7) {
        /// all keyref ops PUSH a value onto the stack
        keyref: PushTypes,
        operation: OpTypes,
    },
};

pub const Frame = struct {
    skip: u32,
    values: []const f32,

    pub fn valueAtFrame(self: *const Frame, frame: u32) f32 {
        if (frame < self.skip) {
            return std.math.nan(f32);
        }
        if (frame >= self.skip + self.values.len) {
            return std.math.nan(f32);
        }
        return self.values[frame - self.skip];
    }
};

pub const OptionalU31 = packed struct(u32) {
    // TODO: this can just be a u32 value where 0 is the null
    value: u32,

    pub const nil: OptionalU31 = .{
        .value = 0,
    };

    pub fn isNil(self: OptionalU31) bool {
        return self.value == nil.value;
    }
    pub fn eql(self: OptionalU31, other: OptionalU31) bool {
        // if they are both nonspecified values, then we consider them equal
        return self.value == other.value;
    }
    pub fn orElse(self: OptionalU31, value: u32) u32 {
        if (self.value == nil.value) {
            return value;
        }
        return self.value;
    }
};

pub const SavedValue = struct {
    derivedFrom: packed struct(u32) {
        isKeyref: bool,
        rest: packed union(u31) {
            bytecodeRef: packed struct(u31) {
                len: u15,
                start: u16,
            },
            keyref: u31,
        },
    },
    value: f32,
    leftFrame: OptionalU31,
    rightFrame: OptionalU31,
};

pub const SaveTypes = enum {
    first,
    last,
    min,
    max,
    mean,
};

pub const ValueCache = struct {
    map: std.EnumMap(SaveTypes, std.ArrayList(SavedValue)),

    pub fn init() ValueCache {
        return .{
            .map = .init(.{
                .first = .empty,
                .last = .empty,
                .min = .empty,
                .mean = .empty,
                .max = .empty,
            }),
        };
    }

    pub fn deinit(self: *ValueCache, alloc: std.mem.Allocator) void {
        for (&self.map.values) |*i| {
            i.deinit(alloc);
        }
    }
};

pub const DataStore = struct {
    frames: []const Frame,
    leftFrame: OptionalU31,
    rightFrame: OptionalU31,
    maxFrame: u32,
    cache: *ValueCache,
};

pub const BytecodeReader = struct {
    bytecode: []const u8,

    pub fn eatOp(self: *const BytecodeReader, ip: *u32) BytecodeOp {
        const value: BytecodeOp = @bitCast(self.bytecode[ip.*]);
        ip.* += 1;
        return value;
    }

    pub fn getTypeSizeForPush(tp: BytecodeOp.PushTypes.Tp) u32 {
        const info_T = @typeInfo(BytecodeOp.PushTypes.Tp).@"enum";
        inline for (info_T.field_values) |value| {
            if (value == @backingInt(tp)) {
                return @sizeOf(GetTypeForPush(@fromBackingInt(@intCast(value))));
            }
        }
        unreachable;
    }
    pub fn GetTypeForPush(comptime tp: BytecodeOp.PushTypes.Tp) type {
        return switch (tp) {
            .keyref => BytecodeOp.PushTypes.KeyrefArg,
            .axis => BytecodeOp.PushTypes.AxisArg,
            .value => BytecodeOp.PushTypes.Value,
            .fn_arg => BytecodeOp.PushTypes.FnArg,
        };
    }
    pub fn eatPushArgs(self: *const BytecodeReader, comptime tp: BytecodeOp.PushTypes.Tp, ip: *u32) GetTypeForPush(tp) {
        return self.eatType(GetTypeForPush(tp), ip);
    }

    pub fn eatType(self: *const BytecodeReader, comptime T: type, ip: *u32) T {
        comptime if (T == void) {
            return {};
        };

        const tSize = @sizeOf(T);

        const slice = self.bytecode[ip.* .. ip.* + tSize];

        ip.* += tSize;

        const v: *align(1) const T = @ptrCast(slice);

        return v.*;
    }
};

pub const BytecodeFilter = struct {
    const FilterSection = struct {
        value: BytecodeRef,
        hint: enum {
            monotonic,
            spike,
            none,
        },
    };
    left: ?FilterSection,
    right: ?FilterSection,
};

pub const BytecodeInterpreter = struct {
    reader: BytecodeReader,
    keyrefNames: []const []const u8,

    datastoreAllocator: std.mem.Allocator,
    store: DataStore,

    /// Remaps every keyref id in the bytecode from an index into the current
    /// `keyrefNames` to an index into `nameTable`, then adopts `nameTable` as the
    /// new names. Every name in `nameTable` must appear in `keyrefNames`, otherwise
    /// `diagnostic` is set to the offending name. Keyrefs in `keyrefNames` that are
    /// not in `nameTable` keep their old names, appended after the new ones. If
    /// `nameTable` is the identity this does nothing.
    pub fn renameKeyrefs(
        self: *BytecodeInterpreter,
        alloc: std.mem.Allocator,
        nameTable: []const []const u8,
        diagnostic: *?[]const u8,
    ) !void {
        if (nameTable.len == self.keyrefNames.len) {
            var identity = true;
            for (nameTable, self.keyrefNames) |newName, oldName| {
                if (!std.mem.eql(u8, newName, oldName)) {
                    identity = false;
                    break;
                }
            }
            if (identity) return;
        }

        // maps an old keyref id (an index into keyrefNames) to its new id (an index
        // into the updated names), maxInt means the old keyref was not renamed
        const unmapped = std.math.maxInt(u16);
        const indexUpdateTable = try alloc.alloc(u16, self.keyrefNames.len);
        defer alloc.free(indexUpdateTable);
        @memset(indexUpdateTable, unmapped);

        for (nameTable, 0..) |name, newIndex| {
            const oldIndex = for (self.keyrefNames, 0..) |oldName, i| {
                if (std.mem.eql(u8, oldName, name)) break i;
            } else {
                diagnostic.* = try alloc.dupe(u8, name);
                return error.KeyrefNotFound;
            };

            if (newIndex > std.math.maxInt(u8)) {
                diagnostic.* = try alloc.dupe(u8, name);
                return error.TooManyKeyrefs;
            }
            indexUpdateTable[oldIndex] = @intCast(newIndex);
        }

        var keptCount: usize = 0;
        for (indexUpdateTable) |newIndex| {
            if (newIndex == unmapped) keptCount += 1;
        }
        const finalLen = nameTable.len + keptCount;
        if (finalLen > std.math.maxInt(u8) + 1) {
            diagnostic.* = try alloc.dupe(u8, "too many keyrefs");
            return error.TooManyKeyrefs;
        }

        var nextIndex: u16 = @intCast(nameTable.len);
        for (indexUpdateTable) |*newIndex| {
            if (newIndex.* == unmapped) {
                newIndex.* = nextIndex;
                nextIndex += 1;
            }
        }

        const stream = @constCast(self.reader.bytecode);
        const reader = self.reader;
        var ip: u32 = 0;
        while (ip < reader.bytecode.len) {
            const op = reader.eatOp(&ip);
            if (op.isKeyref) {
                const tp = op.rest.keyref.tp;
                if (tp == .keyref) {
                    const argPos = ip;
                    const arg = reader.eatPushArgs(.keyref, &ip);
                    if (arg.keyrefId >= indexUpdateTable.len) {
                        diagnostic.* = try alloc.dupe(u8, "keyref id out of range");
                        return error.UnknownKeyref;
                    }
                    stream[argPos] = @intCast(indexUpdateTable[arg.keyrefId]);
                } else {
                    ip += BytecodeReader.getTypeSizeForPush(tp);
                }
            } else if (op.rest.operation == .call) {
                ip += @sizeOf(BytecodeOp.OpTypes.FnCallArgs);
            }
        }

        if (keptCount == 0) {
            self.keyrefNames = nameTable;
        } else {
            const newNames = try alloc.alloc([]const u8, finalLen);
            @memcpy(newNames[0..nameTable.len], nameTable);
            var insertAt = nameTable.len;
            for (indexUpdateTable, 0..) |newIndex, oldIndex| {
                if (newIndex >= nameTable.len) {
                    newNames[insertAt] = self.keyrefNames[oldIndex];
                    insertAt += 1;
                }
            }
            self.keyrefNames = newNames;
        }
    }

    /// Sets the frame window that reductions (axes, keyrefs) operate on by asking
    /// the filters in `filter` where the valid data starts and ends. Both bounds are
    /// resolved against the pre-existing window before either one is stored.
    pub fn setFilterBounds(self: *BytecodeInterpreter, filter: BytecodeFilter, stack: []f32) void {
        // both bounds are resolved against the same (unfiltered) window, just
        // like interpret.zig does
        self.store.leftFrame = .nil;
        self.store.rightFrame = .nil;
        const left = self.resolveFilterBound(true, filter.left, stack);
        const resolvedRight = self.resolveFilterBound(false, filter.right, stack);
        // interpret.zig uses 0 as the "no restriction" sentinel for the right
        // bound, so normalize it back to `.nil` for the rest of the runtime
        const right: OptionalU31 = if (!resolvedRight.isNil() and resolvedRight.value == 0)
            .nil
        else
            resolvedRight;
        self.store.leftFrame = left;
        self.store.rightFrame = right;
    }

    /// Finds the frame that `section` clips the current window to. The left bound is
    /// inclusive and the right bound is exclusive. `.nil` means the filter passes all
    /// the way to the edge of the window, so no restriction is needed on that side.
    pub fn resolveFilterBound(
        self: *BytecodeInterpreter,
        findLeft: bool,
        sectionopt: ?BytecodeFilter.FilterSection,
        stack: []f32,
    ) OptionalU31 {
        if (sectionopt == null) return .nil;
        const section = sectionopt.?;
        const leftFrame = self.store.leftFrame.orElse(0);
        const rightFrame = self.store.rightFrame.orElse(self.store.maxFrame);

        if (leftFrame >= rightFrame) {
            return if (findLeft) self.store.leftFrame else self.store.rightFrame;
        }

        // trivial case where the filter already passes at the edge frame
        const edge = if (findLeft) leftFrame else rightFrame - 1;
        if (!std.math.isNan(self.evalFilter(section.value, edge, stack))) {
            return .nil;
        }

        switch (section.hint) {
            // interpret.zig calls this hint `.normal`: scan inwards from the edge
            .none => {
                var i: u32 = 0;
                while (i < rightFrame - leftFrame) : (i += 1) {
                    const realFrame = if (findLeft) leftFrame + i else rightFrame - 1 - i;
                    if (!std.math.isNan(self.evalFilter(section.value, realFrame, stack))) {
                        return .{
                            .value = @intCast(if (findLeft) realFrame else realFrame + 1),
                        };
                    }
                }
                return .{
                    .value = @intCast(if (findLeft) rightFrame else leftFrame),
                };
            },
            // .spike looks for the edge of a passing run that is surrounded by nans
            .spike => {
                var ready: bool = false;
                var i: u32 = 0;
                while (i < rightFrame - leftFrame) : (i += 1) {
                    const realFrame = if (findLeft) leftFrame + i else rightFrame - 1 - i;
                    if (!std.math.isNan(self.evalFilter(section.value, realFrame, stack))) {
                        if (ready) {
                            return .{
                                .value = @intCast(if (findLeft) realFrame else realFrame + 1),
                            };
                        }
                    } else {
                        ready = true;
                    }
                }
                return .{
                    .value = @intCast(if (findLeft) rightFrame else leftFrame),
                };
            },
            // .monotonic binary searches for the first passing (findLeft) or first
            // failing (findRight) frame
            .monotonic => {
                var leftBound = leftFrame;
                var rightBound = rightFrame;
                while (leftBound < rightBound) {
                    const frame = (leftBound + rightBound) / 2;
                    const passes = !std.math.isNan(self.evalFilter(section.value, frame, stack));
                    if (passes == findLeft) {
                        if (rightBound - leftBound <= 1) {
                            return .{ .value = @intCast(leftBound) };
                        }
                        rightBound = frame;
                    } else {
                        if (rightBound - leftBound <= 1) {
                            return .{ .value = @intCast(rightBound) };
                        }
                        leftBound = frame;
                    }
                }
                return .{ .value = @intCast(leftBound) };
            },
        }
    }

    fn evalFilter(self: *BytecodeInterpreter, ref: BytecodeRef, frameNo: u32, stack: []f32) f32 {
        return self.execRange(ref, frameNo, stack, 0);
    }

    pub fn analyzeFrame(self: *BytecodeInterpreter, keyref: u32, tp: SaveTypes) f32 {
        for (self.store.cache.map.get(tp).?.items) |item| {
            const leftFrameMatches = item.leftFrame.eql(self.store.leftFrame);
            const rightFrameMatches = item.rightFrame.eql(self.store.rightFrame);
            const isKeyref = item.derivedFrom.isKeyref;
            const correctKeyref = item.derivedFrom.rest.keyref == keyref;

            const frameMatches = leftFrameMatches and rightFrameMatches;
            const keyrefGood = isKeyref and correctKeyref;
            if (frameMatches and keyrefGood) {
                return item.value;
            }
        }

        const frame: *const Frame = &self.store.frames[keyref];

        const forcedLeft = frame.skip;
        const forcedRight = frame.skip + frame.values.len;
        const leftBound = @max(self.store.leftFrame.orElse(0), forcedLeft);
        const rightBound = @min(
            self.store.rightFrame.orElse(self.store.maxFrame),
            forcedRight,
        );

        const arrPtr = self.store.cache.map.getPtr(tp).?;
        if (leftBound >= rightBound) {
            const save: SavedValue = .{
                .derivedFrom = .{
                    .isKeyref = true,
                    .rest = .{
                        .keyref = @intCast(keyref),
                    },
                },
                .leftFrame = self.store.leftFrame,
                .rightFrame = self.store.rightFrame,
                .value = std.math.nan(f32),
            };
            arrPtr.append(self.datastoreAllocator, save) catch {};
            return std.math.nan(f32);
        }

        const value = switch (tp) {
            .first => frame.values[leftBound - forcedLeft],
            .last => frame.values[rightBound - 1 - forcedLeft],
            .min => blk: {
                var val = frame.values[leftBound - forcedLeft];
                for (leftBound..rightBound) |frameno| {
                    val = @min(frame.values[frameno - forcedLeft], val);
                }
                break :blk val;
            },
            .max => blk: {
                var val = frame.values[leftBound - forcedLeft];
                for (leftBound..rightBound) |frameno| {
                    val = @max(frame.values[frameno - forcedLeft], val);
                }
                break :blk val;
            },
            .mean => blk: {
                var val: f32 = 0.0;
                for (leftBound..rightBound) |frameno| {
                    val += frame.values[frameno - forcedLeft];
                }
                val /= @floatFromInt(rightBound - leftBound);
                break :blk val;
            },
        };
        const save: SavedValue = .{
            .derivedFrom = .{
                .isKeyref = true,
                .rest = .{
                    .keyref = @intCast(keyref),
                },
            },
            .leftFrame = self.store.leftFrame,
            .rightFrame = self.store.rightFrame,
            .value = value,
        };
        arrPtr.append(self.datastoreAllocator, save) catch {};
        return value;
    }

    pub fn analyzeAxis(
        self: *BytecodeInterpreter,
        ref: BytecodeRef,
        access: BytecodeOp.PushTypes.AccessType,
        frameNo: u32,
        stack: []f32,
        sp: u32,
    ) f32 {
        const nan = std.math.nan(f32);
        switch (access) {
            .current => return self.execRange(ref, frameNo, stack, sp),
            .prev => {
                if (frameNo == 0) return nan;
                return self.execRange(ref, frameNo - 1, stack, sp);
            },
            else => {},
        }

        const tp = access.toSaveType();

        const arrPtr = self.store.cache.map.getPtr(tp).?;
        for (arrPtr.items) |item| {
            if (item.derivedFrom.isKeyref) continue;
            const cached = item.derivedFrom.rest.bytecodeRef;
            if (cached.start != ref.start or cached.len != ref.len) continue;
            if (item.leftFrame.eql(self.store.leftFrame) and
                item.rightFrame.eql(self.store.rightFrame))
            {
                return item.value;
            }
        }

        const leftBound = self.store.leftFrame.orElse(0);
        const rightBound = @min(
            self.store.rightFrame.orElse(self.store.maxFrame),
            self.store.maxFrame,
        );

        var value: f32 = nan;
        if (leftBound < rightBound) {
            value = switch (tp) {
                .first => blk: {
                    for (leftBound..rightBound) |frame| {
                        const v = self.execRange(ref, @intCast(frame), stack, sp);
                        if (!std.math.isNan(v)) break :blk v;
                    }
                    break :blk nan;
                },
                .last => blk: {
                    var frame = rightBound;
                    while (frame > leftBound) {
                        frame -= 1;
                        const v = self.execRange(ref, @intCast(frame), stack, sp);
                        if (!std.math.isNan(v)) break :blk v;
                    }
                    break :blk nan;
                },
                .min, .max => blk: {
                    var val: f32 = nan;
                    for (leftBound..rightBound) |frame| {
                        const v = self.execRange(ref, @intCast(frame), stack, sp);
                        if (std.math.isNan(v)) continue;
                        if (std.math.isNan(val)) {
                            val = v;
                        } else if (tp == .min) {
                            val = @min(val, v);
                        } else {
                            val = @max(val, v);
                        }
                    }
                    break :blk val;
                },
                .mean => blk: {
                    var sum: f32 = 0;
                    var count: u32 = 0;
                    for (leftBound..rightBound) |frame| {
                        const v = self.execRange(ref, @intCast(frame), stack, sp);
                        if (std.math.isNan(v)) continue;
                        sum += v;
                        count += 1;
                    }
                    if (count == 0) break :blk nan;
                    break :blk sum / @as(f32, @floatFromInt(count));
                },
            };
        }

        if (ref.len <= std.math.maxInt(u15)) {
            const save: SavedValue = .{
                .derivedFrom = .{
                    .isKeyref = false,
                    .rest = .{
                        .bytecodeRef = .{
                            .start = ref.start,
                            .len = @intCast(ref.len),
                        },
                    },
                },
                .leftFrame = self.store.leftFrame,
                .rightFrame = self.store.rightFrame,
                .value = value,
            };
            arrPtr.append(self.datastoreAllocator, save) catch {};
        }
        return value;
    }

    pub fn execRange(self: *BytecodeInterpreter, range: BytecodeRef, frameNo: u32, stack: []f32, stackBase: u32) f32 {
        var sp: u32 = stackBase;
        var ip: u32 = range.start;

        while (ip < range.start + range.len) {
            const op = self.reader.eatOp(&ip);

            if (op.isKeyref) {
                const KeyrefArg = BytecodeOp.PushTypes.KeyrefArg;
                const FnArg = BytecodeOp.PushTypes.FnArg;
                switch (op.rest.keyref.tp) {
                    .keyref => {
                        const v: KeyrefArg = self.reader.eatPushArgs(.keyref, &ip);
                        if (op.rest.keyref.rest.keyref == .current) {
                            stack[sp] = self.store.frames[v.keyrefId].valueAtFrame(frameNo);
                            sp += 1;
                        } else if (op.rest.keyref.rest.keyref == .prev) {
                            stack[sp] =
                                self.store.frames[v.keyrefId].valueAtFrame(frameNo - 1);
                            sp += 1;
                        } else {
                            const value = self.analyzeFrame(
                                v.keyrefId,
                                op.rest.keyref.rest.keyref.toSaveType(),
                            );
                            stack[sp] = value;
                            sp += 1;
                        }
                    },
                    .value => {
                        const v = self.reader.eatPushArgs(.value, &ip);
                        stack[sp] = v;
                        sp += 1;
                    },
                    .axis => {
                        const v: BytecodeOp.PushTypes.AxisArg = self.reader.eatPushArgs(.axis, &ip);
                        const value = self.analyzeAxis(v, op.rest.keyref.rest.axis, frameNo, stack, sp);
                        stack[sp] = value;
                        sp += 1;
                    },
                    .fn_arg => {
                        const argId: FnArg = self.reader.eatPushArgs(.fn_arg, &ip);
                        // help:
                        // argId is 0, argBase is 0 (no items in stack)
                        // argId is 0, argBase is 1 (1 item in stack) (valid)

                        const value = stack[stackBase - argId.argIndex - 1];
                        stack[sp] = value;
                        sp += 1;
                    },
                }
            } else {
                switch (op.rest.operation) {
                    .call => {
                        const T = BytecodeOp.OpTypes.FnCallArgs;
                        const args: T = self.reader.eatType(T, &ip);

                        const value = self.execRange(args.bytecode, frameNo, stack, sp);

                        sp -= args.argsPassed;

                        stack[sp] = value;
                        sp += 1;
                    },
                    .plus => {
                        sp -= 1;
                        stack[sp - 1] += stack[sp];
                    },
                    .minus => {
                        sp -= 1;
                        stack[sp - 1] -= stack[sp];
                    },
                    .times => {
                        sp -= 1;
                        stack[sp - 1] *= stack[sp];
                    },
                    .div => {
                        sp -= 1;
                        stack[sp - 1] /= stack[sp];
                    },
                    .sp_if => {
                        sp -= 2;
                        const @"else" = stack[sp + 1];
                        const real = stack[sp];
                        const cond = stack[sp - 1];
                        if (std.math.isNan(cond)) {
                            stack[sp - 1] = @"else";
                        } else {
                            stack[sp - 1] = real;
                        }
                    },
                    .negate => {
                        stack[sp - 1] = -stack[sp - 1];
                    },
                    .sp_ln => {
                        stack[sp - 1] = @log(stack[sp - 1]);
                    },
                    .sp_exp => {
                        stack[sp - 1] = @exp(stack[sp - 1]);
                    },
                    .sp_sqrt => {
                        stack[sp - 1] = @sqrt(stack[sp - 1]);
                    },
                    .sp_abs => {
                        stack[sp - 1] = @abs(stack[sp - 1]);
                    },
                    .sp_max => {
                        sp -= 1;
                        stack[sp - 1] = @max(stack[sp - 1], stack[sp]);
                    },
                    .sp_min => {
                        sp -= 1;
                        stack[sp - 1] = @min(stack[sp - 1], stack[sp]);
                    },
                    .sp_pow => {
                        sp -= 1;
                        const right = stack[sp];
                        const left = stack[sp - 1];
                        stack[sp - 1] = std.math.pow(f32, left, right);
                    },
                    // the comparison ops only pass s[1] through when the gate holds,
                    // otherwise they push nan (so a nan operand always fails the gate)
                    .gte => {
                        sp -= 1;
                        const right = stack[sp];
                        const left = stack[sp - 1];
                        stack[sp - 1] = if (left >= right) left else std.math.nan(f32);
                    },
                    .gt => {
                        sp -= 1;
                        const right = stack[sp];
                        const left = stack[sp - 1];
                        stack[sp - 1] = if (left > right) left else std.math.nan(f32);
                    },
                    .lte => {
                        sp -= 1;
                        const right = stack[sp];
                        const left = stack[sp - 1];
                        stack[sp - 1] = if (left <= right) left else std.math.nan(f32);
                    },
                    .lt => {
                        sp -= 1;
                        const right = stack[sp];
                        const left = stack[sp - 1];
                        stack[sp - 1] = if (left < right) left else std.math.nan(f32);
                    },
                }
            }
        }

        if (stackBase + 1 != sp) {
            @panic("improper stack usage");
        }

        return stack[sp - 1];
    }

    pub fn getMaxStackUsage(self: *BytecodeInterpreter, range: BytecodeRef) !u32 {
        var current: u32 = 0;
        var max: u32 = 0;

        var ip: u32 = range.start;
        var lastPos: u32 = std.math.maxInt(u32);

        while (ip < range.start + range.len) {
            const op = self.reader.eatOp(&ip);

            if (ip == lastPos) {
                return error.hwut;
            }
            lastPos = ip;

            if (op.isKeyref) {
                current += 1;
                max = @max(current, max);
                if (op.rest.keyref.tp == .axis) {
                    const ref = self.reader.eatPushArgs(.axis, &ip);
                    const fnSize = try self.getMaxStackUsage(ref);
                    max = @max(max, current - 1 + fnSize);
                } else {
                    ip += BytecodeReader.getTypeSizeForPush(op.rest.keyref.tp);
                }
            } else {
                switch (op.rest.operation) {
                    // no change
                    .negate, .sp_ln, .sp_exp, .sp_sqrt, .sp_abs => {},
                    .plus,
                    .minus,
                    .times,
                    .div,
                    .sp_max,
                    .sp_min,
                    .sp_pow,
                    .gte,
                    .gt,
                    .lte,
                    .lt,
                    => {
                        current -= 1;
                    },
                    .sp_if => {
                        current -= 2;
                    },
                    .call => {
                        const T = BytecodeOp.OpTypes.FnCallArgs;
                        const v: T = self.reader.eatType(T, &ip);
                        const fnSize = try self.getMaxStackUsage(v.bytecode);
                        max = @max(max, current + fnSize);
                        current += 1;
                        current -= v.argsPassed;
                    },
                }
            }
        }

        return max;
    }

    fn printStackAst(self: *BytecodeInterpreter, range: BytecodeRef, indent: u8) u16 {
        var endPos = range.start;
        var ip: u32 = 0;

        var bytesConsumed: u16 = 0;

        while (true) {
            var len: u16 = 1;
            const op: BytecodeOp = @bitCast(self.reader.bytecode[endPos]);

            if (op.isKeyref) {
                len += @intCast(BytecodeReader.getTypeSizeForPush(op.rest.keyref.tp));
            } else {
                if (op.rest.operation == .call) {
                    len += @sizeOf(BytecodeOp.OpTypes.FnCallArgs);
                }
            }

            if (endPos + len >= range.start + range.len) {
                bytesConsumed = len;
                break;
            }
            endPos += len;
        }

        const op = self.reader.eatOp(&ip);

        for (0..indent) |_| std.debug.print("  ", .{});
        if (op.isKeyref) {
            switch (op.rest.keyref.tp) {
                .keyref => {
                    const args = self.reader.eatPushArgs(.keyref, &ip);
                    std.debug.print("keyref {}:{t}\n", .{
                        args.keyrefId,
                        op.rest.keyref.rest.keyref,
                    });
                },
                .axis => {
                    const args = self.reader.eatPushArgs(.axis, &ip);
                    std.debug.print("axis @ ({}, {}):{t}\n", .{
                        args.start,
                        args.len,
                        op.rest.keyref.rest.keyref,
                    });
                },
                .value => {
                    const args = self.reader.eatPushArgs(.value, &ip);
                    std.debug.print("value={}\n", .{args});
                },
                .fn_arg => {
                    const args = self.reader.eatPushArgs(.fn_arg, &ip);
                    std.debug.print("argument {}\n", .{args.argIndex});
                },
            }
        } else {
            switch (op.rest.operation) {
                .call => {
                    const args = self.reader.eatType(BytecodeOp.OpTypes.FnCallArgs, &ip);
                    std.debug.print("call @ ({}, {}) [{}]\n", .{
                        args.bytecode.start,
                        args.bytecode.len,
                        args.argsPassed,
                    });
                    for (0..args.argsPassed) |_| {
                        bytesConsumed += self.printStackAst(
                            .{
                                .start = range.start,
                                .len = range.len - bytesConsumed,
                            },
                            indent + 1,
                        );
                    }
                },
                .negate => {
                    std.debug.print("*-1\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .plus => {
                    std.debug.print("+\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .sp_if => {
                    std.debug.print("if\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .sp_sqrt => {
                    std.debug.print("sqrt\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .sp_abs => {
                    std.debug.print("abs\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .sp_ln => {
                    std.debug.print("ln\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .sp_exp => {
                    std.debug.print("exp\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .minus => {
                    std.debug.print("-\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .times => {
                    std.debug.print("*\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .div => {
                    std.debug.print("/\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .sp_max => {
                    std.debug.print("max\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .sp_min => {
                    std.debug.print("min\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .sp_pow => {
                    std.debug.print("pow\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .gte => {
                    std.debug.print(">=\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .gt => {
                    std.debug.print(">\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .lte => {
                    std.debug.print("<=\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
                .lt => {
                    std.debug.print("<\n", .{});
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                    bytesConsumed += self.printStackAst(
                        .{
                            .start = range.start,
                            .len = range.len - bytesConsumed,
                        },
                        indent + 1,
                    );
                },
            }
        }
        return @intCast(bytesConsumed);
    }
    pub fn dbgPrint(self: *BytecodeInterpreter, range: BytecodeRef) void {
        var bytesConsumed: u16 = 0;
        while (bytesConsumed < range.len) {
            const c = self.printStackAst(
                .{ .start = range.start, .len = range.len - bytesConsumed },
                0,
            );
            if (c == 0) break;
            bytesConsumed += c;
        }
    }
};

/// A thin wrapper to make building bytecode streams slightly easier
pub const BytecodeBuilder = struct {
    arr: std.ArrayList(u8),

    pub fn addOp(self: *BytecodeBuilder, alloc: std.mem.Allocator, op: BytecodeOp) !void {
        const v: u8 = @bitCast(op);
        try self.arr.append(alloc, v);
    }

    pub fn addType(self: *BytecodeBuilder, T: type, alloc: std.mem.Allocator, v: T) !void {
        const arr: []const u8 = @ptrCast(&v);
        for (arr) |a| {
            try self.arr.append(alloc, a);
        }
    }
};

fn axisTestBody(alloc: std.mem.Allocator, builder: *BytecodeBuilder) !BytecodeRef {
    const start: u16 = @intCast(builder.arr.items.len);
    try builder.addOp(alloc, .{ .isKeyref = true, .rest = .{ .keyref = .{
        .tp = .keyref,
        .rest = .{ .keyref = .current },
    } } });
    try builder.addType(BytecodeOp.PushTypes.KeyrefArg, alloc, .{ .keyrefId = 0 });
    try builder.addOp(alloc, .{ .isKeyref = true, .rest = .{ .keyref = .{
        .tp = .value,
        .rest = .{ .no = 0 },
    } } });
    try builder.addType(f32, alloc, 2.0);
    try builder.addOp(alloc, .{ .isKeyref = false, .rest = .{ .operation = .times } });
    return .{ .start = start, .len = @intCast(builder.arr.items.len - start) };
}

fn runAxisTestCase(
    alloc: std.mem.Allocator,
    access: BytecodeOp.PushTypes.AccessType,
    frameNo: u32,
    values: []const f32,
    left: OptionalU31,
    right: OptionalU31,
) !f32 {
    var builder: BytecodeBuilder = .{ .arr = .empty };
    defer builder.arr.deinit(alloc);

    const body = try axisTestBody(alloc, &builder);

    const mainStart: u16 = @intCast(builder.arr.items.len);
    try builder.addOp(alloc, .{ .isKeyref = true, .rest = .{ .keyref = .{
        .tp = .axis,
        .rest = .{ .axis = access },
    } } });
    try builder.addType(BytecodeOp.PushTypes.AxisArg, alloc, body);
    const mainRef: BytecodeRef = .{
        .start = mainStart,
        .len = @intCast(builder.arr.items.len - mainStart),
    };

    var frames: [1]Frame = .{.{ .skip = 0, .values = values }};
    var cache: ValueCache = .init();
    defer cache.deinit(alloc);

    var stackBuffer: [16]f32 = undefined;

    var interp: BytecodeInterpreter = .{
        .keyrefNames = &.{},
        .reader = .{ .bytecode = builder.arr.items, .pos = 0 },
        .valueStack = .initBuffer(&stackBuffer),
        .stackAllocator = alloc,
        .datastoreAllocator = alloc,
        .store = .{
            .frames = &frames,
            .leftFrame = left,
            .rightFrame = right,
            .maxFrame = @intCast(values.len),
            .cache = &cache,
        },
    };

    // const usage = try interp.getMaxStackUsage(mainRef);
    // std.debug.print("max stack usage for access {t}: {}\n", .{ access, usage });

    const v = try interp.execRange(mainRef, frameNo);
    // second run should hit the cache (except for current/prev)
    const v2 = try interp.execRange(mainRef, frameNo);
    try std.testing.expect(v == v2 or std.math.isNan(v));
    return v;
}

test "axis reductions" {
    const alloc = std.testing.allocator;
    const vals = [_]f32{ 3, 1, 4, 1, 5 };

    try std.testing.expectEqual(@as(f32, 6), try runAxisTestCase(alloc, .current, 0, &vals, .nil, .nil));
    try std.testing.expectEqual(@as(f32, 2), try runAxisTestCase(alloc, .current, 3, &vals, .nil, .nil));
    try std.testing.expectEqual(@as(f32, 2), try runAxisTestCase(alloc, .prev, 4, &vals, .nil, .nil));
    try std.testing.expect(std.math.isNan(try runAxisTestCase(alloc, .prev, 0, &vals, .nil, .nil)));

    try std.testing.expectEqual(@as(f32, 6), try runAxisTestCase(alloc, .first, 0, &vals, .nil, .nil));
    try std.testing.expectEqual(@as(f32, 10), try runAxisTestCase(alloc, .last, 0, &vals, .nil, .nil));
    try std.testing.expectEqual(@as(f32, 2), try runAxisTestCase(alloc, .min, 0, &vals, .nil, .nil));
    try std.testing.expectEqual(@as(f32, 10), try runAxisTestCase(alloc, .max, 0, &vals, .nil, .nil));
    try std.testing.expectEqual(@as(f32, 5.6), try runAxisTestCase(alloc, .mean, 0, &vals, .nil, .nil));
}

test "axis reductions skip nan frames" {
    const alloc = std.testing.allocator;
    const nan = std.math.nan(f32);
    const vals = [_]f32{ nan, 2, nan, 6 };

    try std.testing.expectEqual(@as(f32, 4), try runAxisTestCase(alloc, .first, 0, &vals, .nil, .nil));
    try std.testing.expectEqual(@as(f32, 12), try runAxisTestCase(alloc, .last, 0, &vals, .nil, .nil));
    try std.testing.expectEqual(@as(f32, 4), try runAxisTestCase(alloc, .min, 0, &vals, .nil, .nil));
    try std.testing.expectEqual(@as(f32, 12), try runAxisTestCase(alloc, .max, 0, &vals, .nil, .nil));
    try std.testing.expectEqual(@as(f32, 8), try runAxisTestCase(alloc, .mean, 0, &vals, .nil, .nil));
}

test "axis reductions respect frame window" {
    const alloc = std.testing.allocator;
    const vals = [_]f32{ 3, 1, 4, 1, 5 };
    const left: OptionalU31 = .{ .hasval = true, .value = 2 };
    const right: OptionalU31 = .{ .hasval = true, .value = 4 };

    try std.testing.expectEqual(@as(f32, 8), try runAxisTestCase(alloc, .first, 0, &vals, left, right));
    try std.testing.expectEqual(@as(f32, 2), try runAxisTestCase(alloc, .last, 0, &vals, left, right));
    try std.testing.expectEqual(@as(f32, 2), try runAxisTestCase(alloc, .min, 0, &vals, left, right));
    try std.testing.expectEqual(@as(f32, 5), try runAxisTestCase(alloc, .mean, 0, &vals, left, right));
}

test "empty window is nan" {
    const alloc = std.testing.allocator;
    const vals = [_]f32{3};
    const left: OptionalU31 = .{ .hasval = true, .value = 1 };
    try std.testing.expect(std.math.isNan(
        try runAxisTestCase(alloc, .mean, 0, &vals, left, .nil),
    ));
}

fn runOpExpr(alloc: std.mem.Allocator, op: BytecodeOp.OpTypes, args: []const f32) !f32 {
    var builder: BytecodeBuilder = .{ .arr = .empty };
    defer builder.arr.deinit(alloc);

    const start: u16 = @intCast(builder.arr.items.len);
    for (args) |a| {
        try builder.addOp(alloc, .{ .isKeyref = true, .rest = .{ .keyref = .{
            .tp = .value,
            .rest = .{ .no = 0 },
        } } });
        try builder.addType(f32, alloc, a);
    }
    try builder.addOp(alloc, .{ .isKeyref = false, .rest = .{ .operation = op } });
    const ref: BytecodeRef = .{
        .start = start,
        .len = @intCast(builder.arr.items.len - start),
    };

    var cache: ValueCache = .init();
    defer cache.deinit(alloc);

    var stackBuffer: [8]f32 = undefined;

    var interp: BytecodeInterpreter = .{
        .keyrefNames = &.{},
        .reader = .{ .bytecode = builder.arr.items, .pos = 0 },
        .valueStack = .initBuffer(&stackBuffer),
        .stackAllocator = alloc,
        .datastoreAllocator = alloc,
        .store = .{
            .frames = &.{},
            .leftFrame = .nil,
            .rightFrame = .nil,
            .maxFrame = 0,
            .cache = &cache,
        },
    };

    return try interp.execRange(ref, 0);
}

test "math operations" {
    const alloc = std.testing.allocator;

    try std.testing.expectEqual(@as(f32, 6), try runOpExpr(alloc, .plus, &.{ 2, 4 }));
    try std.testing.expectEqual(@as(f32, -1), try runOpExpr(alloc, .minus, &.{ 2, 3 }));
    try std.testing.expectEqual(@as(f32, 6), try runOpExpr(alloc, .times, &.{ 2, 3 }));
    try std.testing.expectEqual(@as(f32, 3.5), try runOpExpr(alloc, .div, &.{ 7, 2 }));
    try std.testing.expectEqual(@as(f32, -5), try runOpExpr(alloc, .negate, &.{5}));
    try std.testing.expect(std.math.isInf(try runOpExpr(alloc, .div, &.{ 1, 0 })));
    try std.testing.expect(std.math.isNan(try runOpExpr(alloc, .div, &.{ 0, 0 })));

    try std.testing.expectEqual(@as(f32, 3), try runOpExpr(alloc, .sp_sqrt, &.{9}));
    try std.testing.expectEqual(@as(f32, 4), try runOpExpr(alloc, .sp_abs, &.{-4}));
    try std.testing.expectEqual(@as(f32, 1), try runOpExpr(alloc, .sp_exp, &.{0}));
    try std.testing.expectApproxEqAbs(
        @as(f32, 1),
        try runOpExpr(alloc, .sp_ln, &.{@exp(1)}),
        1e-6,
    );
    try std.testing.expectEqual(@as(f32, 5), try runOpExpr(alloc, .sp_max, &.{ 3, 5 }));
    try std.testing.expectEqual(@as(f32, 3), try runOpExpr(alloc, .sp_min, &.{ 3, 5 }));
    try std.testing.expectEqual(@as(f32, 1024), try runOpExpr(alloc, .sp_pow, &.{ 2, 10 }));

    const nan = std.math.nan(f32);
    try std.testing.expect(std.math.isNan(try runOpExpr(alloc, .sp_ln, &.{-1})));
    try std.testing.expect(std.math.isNan(try runOpExpr(alloc, .sp_sqrt, &.{-1})));
    try std.testing.expectEqual(@as(f32, 5), try runOpExpr(alloc, .sp_min, &.{ nan, 5 }));
}

test "comparison operations" {
    const alloc = std.testing.allocator;
    const nan = std.math.nan(f32);

    try std.testing.expectEqual(@as(f32, 5), try runOpExpr(alloc, .gte, &.{ 5, 3 }));
    try std.testing.expect(std.math.isNan(try runOpExpr(alloc, .gte, &.{ 3, 5 })));

    try std.testing.expectEqual(@as(f32, 4), try runOpExpr(alloc, .gt, &.{ 4, 3 }));
    try std.testing.expect(std.math.isNan(try runOpExpr(alloc, .gt, &.{ 3, 3 })));

    try std.testing.expectEqual(@as(f32, 3), try runOpExpr(alloc, .lte, &.{ 3, 3 }));
    try std.testing.expect(std.math.isNan(try runOpExpr(alloc, .lte, &.{ 4, 3 })));

    try std.testing.expectEqual(@as(f32, 2), try runOpExpr(alloc, .lt, &.{ 2, 3 }));
    try std.testing.expect(std.math.isNan(try runOpExpr(alloc, .lt, &.{ 3, 3 })));

    try std.testing.expect(std.math.isNan(try runOpExpr(alloc, .gte, &.{ 5, nan })));
    try std.testing.expect(std.math.isNan(try runOpExpr(alloc, .lt, &.{ nan, 3 })));
}

const FilterHint = @FieldType(BytecodeFilter.FilterSection, "hint");

fn buildFilterBody(
    alloc: std.mem.Allocator,
    builder: *BytecodeBuilder,
    threshold: f32,
) !BytecodeRef {
    const start: u16 = @intCast(builder.arr.items.len);
    try builder.addOp(alloc, .{ .isKeyref = true, .rest = .{ .keyref = .{
        .tp = .keyref,
        .rest = .{ .keyref = .current },
    } } });
    try builder.addType(BytecodeOp.PushTypes.KeyrefArg, alloc, .{ .keyrefId = 0 });
    try builder.addOp(alloc, .{ .isKeyref = true, .rest = .{ .keyref = .{
        .tp = .value,
        .rest = .{ .no = 0 },
    } } });
    try builder.addType(f32, alloc, threshold);
    try builder.addOp(alloc, .{ .isKeyref = false, .rest = .{ .operation = .gte } });
    return .{ .start = start, .len = @intCast(builder.arr.items.len - start) };
}

fn runFilterCase(
    alloc: std.mem.Allocator,
    hint: FilterHint,
    threshold: f32,
    values: []const f32,
) ![2]OptionalU31 {
    var builder: BytecodeBuilder = .{ .arr = .empty };
    defer builder.arr.deinit(alloc);

    const ref = try buildFilterBody(alloc, &builder, threshold);

    var frames: [1]Frame = .{.{ .skip = 0, .values = values }};
    var cache: ValueCache = .init();
    defer cache.deinit(alloc);

    var stackBuffer: [8]f32 = undefined;

    var interp: BytecodeInterpreter = .{
        .keyrefNames = &.{},
        .reader = .{ .bytecode = builder.arr.items, .pos = 0 },
        .valueStack = .initBuffer(&stackBuffer),
        .stackAllocator = alloc,
        .datastoreAllocator = alloc,
        .store = .{
            .frames = &frames,
            .leftFrame = .nil,
            .rightFrame = .nil,
            .maxFrame = @intCast(values.len),
            .cache = &cache,
        },
    };

    interp.setFilterBounds(.{
        .left = .{ .value = ref, .hint = hint },
        .right = .{ .value = ref, .hint = hint },
    });

    return .{ interp.store.leftFrame, interp.store.rightFrame };
}

fn expectBound(bound: OptionalU31, expected: ?u32) !void {
    if (expected) |e| {
        try std.testing.expect(bound.hasval);
        try std.testing.expectEqual(e, @as(u32, bound.value));
    } else {
        try std.testing.expect(!bound.hasval);
    }
}

test "filter bounds: normal hint" {
    const alloc = std.testing.allocator;
    const bounds = try runFilterCase(alloc, .none, 3, &.{ 1, 3, 4, 1, 2 });
    try expectBound(bounds[0], 1);
    try expectBound(bounds[1], 3);
}

test "filter bounds: passing at the edges needs no restriction" {
    const alloc = std.testing.allocator;
    const bounds = try runFilterCase(alloc, .none, 0, &.{ 1, 3, 4 });
    try expectBound(bounds[0], null);
    try expectBound(bounds[1], null);
}

test "filter bounds: spike hint" {
    const alloc = std.testing.allocator;
    const bounds = try runFilterCase(alloc, .spike, 2, &.{ 1, 3, 4, 1, 5, 1 });
    try expectBound(bounds[0], 1);
    try expectBound(bounds[1], 5);
}

test "filter bounds: monotonic hint" {
    const alloc = std.testing.allocator;
    {
        const bounds = try runFilterCase(alloc, .monotonic, 3, &.{ 1, 1, 3, 4, 4 });
        try expectBound(bounds[0], 2);
        try expectBound(bounds[1], null);
    }
    {
        const bounds = try runFilterCase(alloc, .monotonic, 3, &.{ 4, 4, 1, 1, 1 });
        try expectBound(bounds[0], null);
        try expectBound(bounds[1], 2);
    }
}

fn keyrefPush(alloc: std.mem.Allocator, builder: *BytecodeBuilder, keyrefId: u8) !void {
    try builder.addOp(alloc, .{ .isKeyref = true, .rest = .{ .keyref = .{
        .tp = .keyref,
        .rest = .{ .keyref = .current },
    } } });
    try builder.addType(BytecodeOp.PushTypes.KeyrefArg, alloc, .{ .keyrefId = keyrefId });
}

test "renameKeyrefs remaps keyref ids and adopts the new names" {
    const alloc = std.testing.allocator;
    var builder: BytecodeBuilder = .{ .arr = .empty };
    defer builder.arr.deinit(alloc);

    const firstOp = builder.arr.items.len;
    try keyrefPush(alloc, &builder, 0);
    try builder.addOp(alloc, .{ .isKeyref = true, .rest = .{ .keyref = .{
        .tp = .value,
        .rest = .{ .no = 0 },
    } } });
    try builder.addType(f32, alloc, 1.5);
    const secondOp = builder.arr.items.len;
    try keyrefPush(alloc, &builder, 1);
    try builder.addOp(alloc, .{ .isKeyref = false, .rest = .{ .operation = .call } });
    try builder.addType(BytecodeOp.OpTypes.FnCallArgs, alloc, .{
        .bytecode = .{ .start = 0, .len = 0 },
        .argsPassed = 0,
    });
    const thirdOp = builder.arr.items.len;
    try keyrefPush(alloc, &builder, 0);

    const oldNames = [_][]const u8{ "a", "b" };
    const newNames = [_][]const u8{ "b", "a" };

    var cache: ValueCache = .init();
    defer cache.deinit(alloc);

    var stackBuffer: [8]f32 = undefined;

    var interp: BytecodeInterpreter = .{
        .keyrefNames = &oldNames,
        .reader = .{ .bytecode = builder.arr.items, .pos = 0 },
        .valueStack = .initBuffer(&stackBuffer),
        .stackAllocator = alloc,
        .datastoreAllocator = alloc,
        .store = .{
            .frames = &.{},
            .leftFrame = .nil,
            .rightFrame = .nil,
            .maxFrame = 0,
            .cache = &cache,
        },
    };

    var diagnostic: ?[]const u8 = null;
    defer if (diagnostic) |message| alloc.free(message);

    try interp.renameKeyrefs(alloc, &newNames, &diagnostic);

    try std.testing.expect(diagnostic == null);
    try std.testing.expectEqual(@as(u8, 1), builder.arr.items[firstOp + 1]);
    try std.testing.expectEqual(@as(u8, 0), builder.arr.items[secondOp + 1]);
    try std.testing.expectEqual(@as(u8, 1), builder.arr.items[thirdOp + 1]);
    try std.testing.expectEqual(oldNames.len, interp.keyrefNames.len);
    try std.testing.expectEqualStrings("b", interp.keyrefNames[0]);
    try std.testing.expectEqualStrings("a", interp.keyrefNames[1]);
}

test "renameKeyrefs reports a keyref missing from the old names" {
    const alloc = std.testing.allocator;
    var builder: BytecodeBuilder = .{ .arr = .empty };
    defer builder.arr.deinit(alloc);

    try keyrefPush(alloc, &builder, 0);

    const oldNames = [_][]const u8{"a"};
    const newNames = [_][]const u8{ "a", "c" };

    var cache: ValueCache = .init();
    defer cache.deinit(alloc);

    var stackBuffer: [8]f32 = undefined;

    var interp: BytecodeInterpreter = .{
        .keyrefNames = &oldNames,
        .reader = .{ .bytecode = builder.arr.items, .pos = 0 },
        .valueStack = .initBuffer(&stackBuffer),
        .stackAllocator = alloc,
        .datastoreAllocator = alloc,
        .store = .{
            .frames = &.{},
            .leftFrame = .nil,
            .rightFrame = .nil,
            .maxFrame = 0,
            .cache = &cache,
        },
    };

    var diagnostic: ?[]const u8 = null;
    defer if (diagnostic) |message| alloc.free(message);

    try std.testing.expectError(
        error.KeyrefNotFound,
        interp.renameKeyrefs(alloc, &newNames, &diagnostic),
    );
    try std.testing.expectEqualStrings("c", diagnostic.?);
    try std.testing.expectEqual(@as(u8, 0), builder.arr.items[1]);
    try std.testing.expectEqualStrings("a", interp.keyrefNames[0]);
}

test "renameKeyrefs keeps keyrefs that are not renamed" {
    const alloc = std.testing.allocator;
    var builder: BytecodeBuilder = .{ .arr = .empty };
    defer builder.arr.deinit(alloc);

    const firstOp = builder.arr.items.len;
    try keyrefPush(alloc, &builder, 0);
    const secondOp = builder.arr.items.len;
    try keyrefPush(alloc, &builder, 1);
    const thirdOp = builder.arr.items.len;
    try keyrefPush(alloc, &builder, 2);

    const oldNames = [_][]const u8{ "a", "b", "c" };
    const newNames = [_][]const u8{ "c", "a" };

    var cache: ValueCache = .init();
    defer cache.deinit(alloc);

    var stackBuffer: [8]f32 = undefined;

    var interp: BytecodeInterpreter = .{
        .keyrefNames = &oldNames,
        .reader = .{ .bytecode = builder.arr.items, .pos = 0 },
        .valueStack = .initBuffer(&stackBuffer),
        .stackAllocator = alloc,
        .datastoreAllocator = alloc,
        .store = .{
            .frames = &.{},
            .leftFrame = .nil,
            .rightFrame = .nil,
            .maxFrame = 0,
            .cache = &cache,
        },
    };

    var diagnostic: ?[]const u8 = null;
    defer if (diagnostic) |message| alloc.free(message);

    try interp.renameKeyrefs(alloc, &newNames, &diagnostic);
    defer alloc.free(interp.keyrefNames);

    try std.testing.expect(diagnostic == null);
    try std.testing.expectEqual(@as(u8, 1), builder.arr.items[firstOp + 1]);
    try std.testing.expectEqual(@as(u8, 2), builder.arr.items[secondOp + 1]);
    try std.testing.expectEqual(@as(u8, 0), builder.arr.items[thirdOp + 1]);
    try std.testing.expectEqual(@as(usize, 3), interp.keyrefNames.len);
    try std.testing.expectEqualStrings("c", interp.keyrefNames[0]);
    try std.testing.expectEqualStrings("a", interp.keyrefNames[1]);
    try std.testing.expectEqualStrings("b", interp.keyrefNames[2]);
}

test "renameKeyrefs skips an identity rename" {
    const alloc = std.testing.allocator;
    var builder: BytecodeBuilder = .{ .arr = .empty };
    defer builder.arr.deinit(alloc);

    try keyrefPush(alloc, &builder, 5);

    const names = [_][]const u8{"a"};

    var cache: ValueCache = .init();
    defer cache.deinit(alloc);

    var stackBuffer: [8]f32 = undefined;

    var interp: BytecodeInterpreter = .{
        .keyrefNames = &names,
        .reader = .{ .bytecode = builder.arr.items, .pos = 0 },
        .valueStack = .initBuffer(&stackBuffer),
        .stackAllocator = alloc,
        .datastoreAllocator = alloc,
        .store = .{
            .frames = &.{},
            .leftFrame = .nil,
            .rightFrame = .nil,
            .maxFrame = 0,
            .cache = &cache,
        },
    };

    var diagnostic: ?[]const u8 = null;
    defer if (diagnostic) |message| alloc.free(message);

    try interp.renameKeyrefs(alloc, &names, &diagnostic);

    try std.testing.expect(diagnostic == null);
    try std.testing.expectEqual(@as(u8, 5), builder.arr.items[1]);
    try std.testing.expectEqualStrings("a", interp.keyrefNames[0]);
}
