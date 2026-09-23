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
pub const AxisId = enum(u8) {
    x = 0,
    _,

    pub fn isY(self: AxisId) bool {
        return self != .x;
    }
    // a 0 indexed y id
    pub fn fromYId(yId: u8) AxisId {
        return @enumFromInt(yId + 1);
    }
    // a 0 indexed y id
    pub fn toYId(self: AxisId) u8 {
        std.debug.assert(self != .x);
        return @intFromError(self) - 1;
    }
};
pub const BytecodeValue = packed struct(u8) {
    pub const PushTypes = enum(u7) {
        pub const KeyrefArg = packed struct(u8) {
            keyrefId: u8,
        };
        pub const AxisArg = AxisId;

        pub const Value = f32;

        pub const FnArg = packed struct(u8) {
            argIndex: u8,
        };

        // for all keyref_ keys, the next 8 bits are which keyref it is
        // for all axis_ keys, the next 8 bits are axis number

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

        keyref_prev,

        axis_selection,
        keyref_selection,

        /// access the n-th arg of a function, eat 8 bits for arg pos
        fn_arg,
    };

    pub const OpTypes = enum(u7) {
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
        /// eat 16 bits for fn start, eat 16 bits for fn len, eat 16 bits for
        /// number of args passed, then switch control to the fn
        call,
        /// next 8 bits determines the number of args to pop off the args stack
        /// into the local function args array
        eat_args,
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
};

pub const SavedValue = struct {
    pub const OptionalU31 = packed struct(u32) {
        hasval: bool,
        value: u31,
    };
    value: f32,
    leftFrame: OptionalU31,
    rightFrame: OptionalU31,
};

pub const ValueCache = struct {
    max: std.ArrayList(SavedValue),
    min: std.ArrayList(SavedValue),
    first: std.ArrayList(SavedValue),
    last: std.ArrayList(SavedValue),
    alloc: std.mem.Allocator,
};

pub const BytecodeStream = struct {
    bytecode: []const u8,
    pos: u32,
    /// it is the stream's job to ensure the stack length always stays above this
    stackTop: u32,
    args: []const f32,
    valueStack: *std.ArrayList(f32),

    pub fn eatOp(self: *BytecodeStream) BytecodeValue {
        std.debug.assert(self.pos < self.bytecode.len);
        const value: BytecodeValue = @bitCast(self.bytecode[self.pos]);
        self.pos += 1;
        return value;
    }

    pub fn GetTypeForPush(comptime tp: BytecodeValue.PushTypes) type {
        const str = @tagName(tp);
        if (std.mem.startsWith(u8, str, "keyref_")) {
            return BytecodeValue.PushTypes.KeyrefArg;
        }
        if (std.mem.startsWith(u8, str, "axis_")) {
            return BytecodeValue.PushTypes.AxisArg;
        }
        if (std.mem.eql(u8, str, "value")) {
            return BytecodeValue.PushTypes.Value;
        }
        if (std.mem.eql(u8, str, "fn_arg")) {
            return BytecodeValue.PushTypes.FnArg;
        }
        @compileError(std.fmt.comptimePrint(
            "Cannot determine type for enum value BytecodeValue.PushTypes.{t}",
            .{tp},
        ));
    }
    pub fn eatPushArgs(self: *BytecodeStream, comptime tp: BytecodeValue.PushTypes) GetTypeForPush(tp) {
        return self.eatType(GetTypeForPush(tp));
    }
    pub fn eatType(self: *BytecodeStream, comptime T: type) T {
        comptime if (T == void) {
            return {};
        };

        comptime if (@bitSizeOf(T) % 8 != 0) {
            @compileError(std.fmt.comptimePrint("Passed type {} to eatType does not have byte multiple size (note: expected size multiple of 8, got {})", .{ T, @bitSizeOf(T) }));
        };

        const tSize = @bitSizeOf(T) / 8 - 1;

        std.debug.assert(self.pos + tSize - 1 < self.bytecode.len);

        const slice = self.bytecode[self.pos .. self.pos + tSize];

        self.pos += tSize;

        const v: *T align(1) = @ptrCast(slice);

        return v.*;
    }

    pub fn popValue(self: *BytecodeStream) f32 {
        std.debug.assert(self.valueStack.items.len > self.stackTop);
        return self.valueStack.pop().?;
    }
    pub fn pushValue(self: *BytecodeStream, alloc: std.mem.Allocator, item: f32) void {
        self.valueStack.append(alloc, item);
    }

    pub fn execOne(self: *BytecodeStream, alloc: std.mem.Allocator, keyVals: []const f32) void {
        const op = self.eatOp();

        if (op.isKeyref) {
            switch (op.rest.keyref) {
                .keyref_get => {
                    const v = self.eatPushArgs(.keyref_get);
                    self.pushValue(alloc, keyVals[v.keyrefId]);
                },
            }
        } else {
            switch (op.rest.operation) {}
        }
    }
};
