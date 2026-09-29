const std = @import("std");
// debug info? alongside the byte stream?

// callconv:
//
// PUSH args in left to right order then CALL(fn start, fn len, n)
//
// inside function:
//
// EAT_ARGS(n) where n is number of args (optionally do a sanity check that args passed is correct)
// then for when using function arg, PUSH FN_ARG(n) where n is the index of arg

pub const BytecodeRef = struct {
    start: u16,
    len: u16,
};

// TODO: use this

pub const BytecodeOp = packed struct(u8) {
    pub const PushTypes = packed struct(u7) {
        pub const KeyrefArg = packed struct(u8) {
            keyrefId: u8,
        };

        pub const AxisArg = BytecodeRef;

        pub const Value = f32;

        comptime {
            std.debug.assert(@bitSizeOf(AxisArg) == @bitSizeOf(Value));
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

        pub fn isSpecialFn(self: OpTypes) bool {
            const tag = @tagName(self);
            if (std.mem.startsWith(u8, tag, "sp_")) return true;
            return false;
        }
        pub fn argCountOf(self: OpTypes) ?u16 {
            return switch (self) {
                .sp_ln, .sp_exp, .sp_sqrt, .sp_abs => 1,
                .sp_max, .sp_min, .sp_pow => 2,
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
    hasval: bool,
    value: u31,

    pub const nil: OptionalU31 = .{
        .hasval = false,
        .value = 0,
    };

    pub fn eql(self: OptionalU31, other: OptionalU31) bool {
        // if they are both nonspecified values, then we consider them equal
        if (!self.hasval and !other.hasval) {
            return true;
        }
        return self.value == other.value;
    }
    pub fn orElse(self: OptionalU31, value: u32) u32 {
        if (!self.hasval) {
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

pub const BytecodeInterpreter = struct {
    bytecode: []const u8,
    pos: u32,
    valueStack: std.ArrayList(f32),
    stackAllocator: std.mem.Allocator,
    datastoreAllocator: std.mem.Allocator,
    store: DataStore,

    pub fn eatOp(self: *BytecodeInterpreter) BytecodeOp {
        std.debug.assert(self.pos < self.bytecode.len);
        const value: BytecodeOp = @bitCast(self.bytecode[self.pos]);
        self.pos += 1;
        return value;
    }

    pub fn getTypeSizeForPush(tp: BytecodeOp.PushTypes.Tp) u32 {
        inline for (@typeInfo(BytecodeOp.PushTypes.Tp).@"enum".fields) |field| {
            if (field.value == @intFromEnum(tp)) {
                return @sizeOf(GetTypeForPush(@enumFromInt(field.value)));
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
    pub fn eatPushArgs(self: *BytecodeInterpreter, comptime tp: BytecodeOp.PushTypes.Tp) GetTypeForPush(tp) {
        return self.eatType(GetTypeForPush(tp));
    }
    pub fn eatType(self: *BytecodeInterpreter, comptime T: type) T {
        comptime if (T == void) {
            return {};
        };

        comptime if (@bitSizeOf(T) % 8 != 0) {
            @compileError(std.fmt.comptimePrint("Passed type {} to eatType does not have byte multiple size (note: expected size multiple of 8, got {})", .{ T, @bitSizeOf(T) }));
        };

        const tSize = @bitSizeOf(T) / 8;

        std.debug.assert(self.pos + tSize < self.bytecode.len);

        const slice = self.bytecode[self.pos .. self.pos + tSize];

        self.pos += tSize;

        const v: *align(1) const T = @ptrCast(slice);

        return v.*;
    }

    pub fn popValue(self: *BytecodeInterpreter) f32 {
        return self.valueStack.pop().?;
    }

    pub fn pushValue(self: *BytecodeInterpreter, item: f32) void {
        self.valueStack.append(self.stackAllocator, item) catch @panic("whut whoa");
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
            .first => frame.values[leftBound],
            .last => frame.values[rightBound - 1],
            .min => blk: {
                var val: f32 = frame.values[leftBound];
                for (leftBound..rightBound) |frameno| {
                    val = @min(frame.values[frameno], val);
                }
                break :blk val;
            },
            .max => blk: {
                var val: f32 = frame.values[leftBound];
                for (leftBound..rightBound) |frameno| {
                    val = @max(frame.values[frameno], val);
                }
                break :blk val;
            },
            .mean => blk: {
                var val: f32 = 0.0;
                for (leftBound..rightBound) |frameno| {
                    val += frame.values[frameno];
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

    pub fn execOne(self: *BytecodeInterpreter, frameNo: u32, argBase: u32) void {
        const op = self.eatOp();

        if (op.isKeyref) {
            const KeyrefArg = BytecodeOp.PushTypes.KeyrefArg;
            const FnArg = BytecodeOp.PushTypes.FnArg;
            switch (op.rest.keyref.tp) {
                else => unreachable,
                .keyref => {
                    const v: KeyrefArg = self.eatPushArgs(.keyref);
                    if (op.rest.keyref.rest.keyref == .current) {
                        self.pushValue(
                            self.store.frames[v.keyrefId].valueAtFrame(frameNo),
                        );
                    } else if (op.rest.keyref.rest.keyref == .prev) {
                        self.pushValue(
                            self.store.frames[v.keyrefId].valueAtFrame(frameNo - 1),
                        );
                    } else {
                        const value = self.analyzeFrame(v.keyrefId, op.rest.keyref.rest.keyref.toSaveType());
                        self.pushValue(value);
                    }
                },
                .value => {
                    const v = self.eatPushArgs(.value);
                    self.pushValue(v);
                },
                .fn_arg => {
                    const argId: FnArg = self.eatPushArgs(.fn_arg);
                    // help:
                    // argId is 0, argBase is 0 (no items in stack)
                    // argId is 0, argBase is 1 (1 item in stack) (valid)
                    std.debug.assert(argId.argIndex + 1 <= argBase);

                    const value = self.valueStack.items[argBase - argId.argIndex - 1];
                    self.pushValue(value);
                },
            }
        } else {
            switch (op.rest.operation) {
                .call => {
                    const T = BytecodeOp.OpTypes.FnCallArgs;
                    const args: T = self.eatType(T);

                    const value = self.execRange(args.bytecode, 0.0) catch unreachable;

                    for (0..args.argsPassed) |_| {
                        _ = self.popValue();
                    }
                    self.pushValue(value);
                },
                .plus => {
                    const right = self.popValue();
                    const left = self.popValue();
                    self.pushValue(left + right);
                },
                .minus => {
                    const right = self.popValue();
                    const left = self.popValue();
                    self.pushValue(left - right);
                },
                .times => {
                    const right = self.popValue();
                    const left = self.popValue();
                    self.pushValue(left * right);
                },
                .negate => {
                    const v = self.popValue();
                    self.pushValue(-v);
                },
                else => unreachable,
            }
        }
    }

    pub fn execRange(self: *BytecodeInterpreter, range: BytecodeRef, frameNo: u32) !f32 {
        const stackStart = self.valueStack.items.len;

        const old = self.pos;
        defer self.pos = old;

        self.pos = range.start;
        var lastPos: u32 = std.math.maxInt(u32);

        while (self.pos < range.start + range.len) {
            std.debug.print("Exec at pos {}\n", .{self.pos});
            self.execOne(frameNo, @intCast(stackStart));
            if (self.pos == lastPos) {
                return std.math.nan(f32);
            }
            lastPos = self.pos;
        }

        if (self.valueStack.items.len != stackStart + 1) {
            return error.ImproperStackUsage;
        }

        const last = self.popValue();

        return last;
    }

    pub fn getMaxStackUsage(self: *BytecodeInterpreter, range: BytecodeRef) !u32 {
        var current: u32 = 0;
        var max: u32 = 0;

        const old = self.pos;
        defer self.pos = old;

        self.pos = range.start;
        var lastPos: u32 = std.math.maxInt(u32);

        while (self.pos < range.start + range.len) {
            const op = self.eatOp();

            if (self.pos == lastPos) {
                return error.hwut;
            }
            lastPos = self.pos;

            if (op.isKeyref) {
                current += 1;
                max = @max(current, max);
                self.pos += getTypeSizeForPush(op.rest.keyref.tp);
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
                    .call => {
                        const T = BytecodeOp.OpTypes.FnCallArgs;
                        const v: T = self.eatType(T);
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
