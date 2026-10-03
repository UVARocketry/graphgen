const std = @import("std");

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
//      executing the axis's bytecode to determine location and value of annotations
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

pub const BytecodeRef = struct {
    start: u16,
    len: u16,
};

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

pub const BytecodeReader = struct {
    bytecode: []const u8,
    pos: u32,

    pub fn eatOp(self: *BytecodeReader) BytecodeOp {
        std.debug.assert(self.pos < self.bytecode.len);
        const value: BytecodeOp = @bitCast(self.bytecode[self.pos]);
        self.pos += 1;
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
    pub fn eatPushArgs(self: *BytecodeReader, comptime tp: BytecodeOp.PushTypes.Tp) GetTypeForPush(tp) {
        return self.eatType(GetTypeForPush(tp));
    }

    pub fn eatType(self: *BytecodeReader, comptime T: type) T {
        comptime if (T == void) {
            return {};
        };

        const tSize = @sizeOf(T);

        std.debug.assert(self.pos + tSize <= self.bytecode.len);

        const slice = self.bytecode[self.pos .. self.pos + tSize];

        self.pos += tSize;

        const v: *align(1) const T = @ptrCast(slice);

        return v.*;
    }
};

pub const BytecodeInterpreter = struct {
    reader: BytecodeReader,
    valueStack: std.ArrayList(f32),
    stackAllocator: std.mem.Allocator,
    datastoreAllocator: std.mem.Allocator,
    store: DataStore,
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
        const op = self.reader.eatOp();

        if (op.isKeyref) {
            const KeyrefArg = BytecodeOp.PushTypes.KeyrefArg;
            const FnArg = BytecodeOp.PushTypes.FnArg;
            switch (op.rest.keyref.tp) {
                else => unreachable,
                .keyref => {
                    const v: KeyrefArg = self.reader.eatPushArgs(.keyref);
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
                    const v = self.reader.eatPushArgs(.value);
                    self.pushValue(v);
                },
                .fn_arg => {
                    const argId: FnArg = self.reader.eatPushArgs(.fn_arg);
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
                    const args: T = self.reader.eatType(T);

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

        const old = self.reader.pos;
        defer self.reader.pos = old;

        self.reader.pos = range.start;
        var lastPos: u32 = std.math.maxInt(u32);

        while (self.reader.pos < range.start + range.len) {
            std.debug.print("Exec at pos {}\n", .{self.reader.pos});
            self.execOne(frameNo, @intCast(stackStart));
            if (self.reader.pos == lastPos) {
                return std.math.nan(f32);
            }
            lastPos = self.reader.pos;
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

        const old = self.reader.pos;
        defer self.reader.pos = old;

        self.reader.pos = range.start;
        var lastPos: u32 = std.math.maxInt(u32);

        while (self.reader.pos < range.start + range.len) {
            const op = self.reader.eatOp();

            if (self.reader.pos == lastPos) {
                return error.hwut;
            }
            lastPos = self.reader.pos;

            if (op.isKeyref) {
                current += 1;
                max = @max(current, max);
                self.reader.pos += BytecodeReader.getTypeSizeForPush(op.rest.keyref.tp);
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
                        const v: T = self.reader.eatType(T);
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
        const startPos = self.reader.pos;
        defer self.reader.pos = startPos;
        var endPos = range.start;

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

        self.reader.pos = endPos;

        const op = self.reader.eatOp();

        for (0..indent) |_| std.debug.print("  ", .{});
        if (op.isKeyref) {
            switch (op.rest.keyref.tp) {
                .keyref => {
                    const args = self.reader.eatPushArgs(.keyref);
                    std.debug.print("keyref {}:{t}\n", .{
                        args.keyrefId,
                        op.rest.keyref.rest.keyref,
                    });
                },
                .axis => {
                    const args = self.reader.eatPushArgs(.axis);
                    std.debug.print("axis @ ({}, {}):{t}\n", .{
                        args.start,
                        args.len,
                        op.rest.keyref.rest.keyref,
                    });
                },
                .value => {
                    const args = self.reader.eatPushArgs(.value);
                    std.debug.print("value={}\n", .{args});
                },
                .fn_arg => {
                    const args = self.reader.eatPushArgs(.fn_arg);
                    std.debug.print("argument {}\n", .{args.argIndex});
                },
            }
        } else {
            switch (op.rest.operation) {
                .call => {
                    const args = self.reader.eatType(BytecodeOp.OpTypes.FnCallArgs);
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
