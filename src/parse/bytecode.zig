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

pub const BytecodeOp = packed struct(u8) {
    pub const PushTypes = enum(u7) {
        pub const KeyrefArg = packed struct(u8) {
            keyrefId: u8,
        };
        pub const AxisArg = BytecodeRef;

        pub const Value = f32;

        pub const FnArg = packed struct(u8) {
            argIndex: u8,
        };

        // for all keyref_ keys, the next 8 bits are which keyref it is
        // for all axis_ keys, the next value is a BytecodeRef

        /// just a plain keyref
        keyref_get,
        /// a 32 bit float, the float is the next 32 bits in the bytecode stream
        value,

        keyref_first,
        axis_first,
        keyref_last,
        axis_last,
        keyref_min,
        axis_min,
        keyref_max,
        axis_max,

        keyref_mean,
        axis_mean,

        keyref_prev,

        axis_selection,
        keyref_selection,

        /// access the `N-n`-th arg of a function, eat 8 bits for arg pos.
        /// NOTE: the 8 bits are REVERSE INDEXED, thus 0 means last arg!
        fn_arg,
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
        ln,
        /// POP 1, push e^s[0]
        exp,
        /// POP 2, push max(s[1], s[0])
        max,
        /// POP 2, push min(s[1], s[0])
        min,
        /// POP 1, push sqrt(s[0])
        sqrt,
        /// POP 1, push abs(s[0])
        abs,
        /// POP 2, push s[1]^s[0]
        pow,
        /// POP 2, push nan if s[1] < s[0], else push s[1]
        gte,
        /// POP 2, push nan if s[1] <= s[0], else push s[1]
        gt,
        /// POP 2, push nan if s[1] > s[0], else push s[1]
        lte,
        /// POP 2, push nan if s[1] >= s[0], else push s[1]
        lt,
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
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) ValueCache {
        return .{
            .alloc = alloc,
            .map = .init(.{
                .first = .empty,
                .last = .empty,
                .min = .empty,
                .mean = .empty,
                .max = .empty,
            }),
        };
    }

    pub fn deinit(self: *ValueCache) void {
        for (self.map.values) |*i| {
            i.deinit(self.alloc);
        }
    }
};

pub const DataStore = struct {
    frames: []const Frame,
    leftFrame: OptionalU31,
    rightFrame: OptionalU31,
    cache: *ValueCache,
};

// ok so some weird things are starting to appear:
//
// BytecodeInterpreter is kinda intended to be an isolated thing, but it still needs global
// ctx for calling functions (it also needs passed context for resolving keyvals and
// axes and their derivations)
//
// it also needs parent context for resolving fn args hmmmmmm
//
// so technically we can static-analyze the bytecode and then produce a cache with
// the correct :first, :last, etc resolutions AOT
//
// could we just in-place replace all fancy bytecodes (.keyref_, .axis_) with .value?
// but that can get very complciated

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

    pub fn GetTypeForPush(comptime tp: BytecodeOp.PushTypes) type {
        const str = @tagName(tp);
        if (std.mem.startsWith(u8, str, "keyref_")) {
            return BytecodeOp.PushTypes.KeyrefArg;
        }
        if (std.mem.startsWith(u8, str, "axis_")) {
            return BytecodeOp.PushTypes.AxisArg;
        }
        if (std.mem.eql(u8, str, "value")) {
            return BytecodeOp.PushTypes.Value;
        }
        if (std.mem.eql(u8, str, "fn_arg")) {
            return BytecodeOp.PushTypes.FnArg;
        }
        @compileError(std.fmt.comptimePrint(
            "Cannot determine type for enum value BytecodeValue.PushTypes.{t}",
            .{tp},
        ));
    }
    pub fn eatPushArgs(self: *BytecodeInterpreter, comptime tp: BytecodeOp.PushTypes) GetTypeForPush(tp) {
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

    pub fn execOne(self: *BytecodeInterpreter, frameNo: u32, argBase: u32) void {
        const op = self.eatOp();

        if (op.isKeyref) {
            switch (op.rest.keyref) {
                else => unreachable,
                .keyref_get => {
                    const v = self.eatPushArgs(.keyref_get);
                    self.pushValue(
                        self.store.frames[v.keyrefId].valueAtFrame(frameNo),
                    );
                },
                .value => {
                    const v = self.eatPushArgs(.value);
                    self.pushValue(v);
                },
                .keyref_first => {
                    const v = self.eatPushArgs(.value);
                    _ = v;
                    const value = for (self.store.cache.map.get(.first).?.items) |item| {
                        // TODO: derivedFrom check
                        if (item.leftFrame.eql(self.store.leftFrame) and item.rightFrame.eql(self.store.rightFrame)) {
                            break item.value;
                        }
                    } else 0.0;
                    self.pushValue(value);
                },
                .fn_arg => {
                    const argId: BytecodeOp.PushTypes.FnArg = self.eatPushArgs(.fn_arg);
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
};

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
