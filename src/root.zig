const std = @import("std");
const wren_raw = @import("wren_raw");

fn wrenWriteFn(vm: ?*wren_raw.WrenVM, text: [*c]const u8) callconv(.c) void {
    const data_ptr_raw = wren_raw.wrenGetUserData(vm);
    const data_ptr: *Vm.VmData = @ptrCast(@alignCast(data_ptr_raw));
    if (data_ptr.config.writeFn == null) return;

    data_ptr.config.writeFn.?(std.mem.span(text));
}

fn wrenErrorFn(vm: ?*wren_raw.WrenVM, @"type": wren_raw.WrenErrorType, module: [*c]const u8, line: c_int, message: [*c]const u8) callconv(.c) void {
    const data_ptr_raw = wren_raw.wrenGetUserData(vm);
    const data_ptr: *Vm.VmData = @ptrCast(@alignCast(data_ptr_raw));
    if (data_ptr.config.writeFn == null) return;

    var error_type: ErrorType = .Compile;
    switch (@"type") {
        wren_raw.WREN_ERROR_COMPILE => {},
        wren_raw.WREN_ERROR_RUNTIME => { error_type = .Runtime; },
        wren_raw.WREN_ERROR_STACK_TRACE => { error_type = .StackTrace; },
        else => unreachable,
    }

    var moduleStr: ?[]const u8 = null;
    if (module != null) moduleStr = std.mem.span(module);
    data_ptr.config.errorFn.?(error_type, moduleStr, @intCast(line), std.mem.span(message));
}

fn demo_add(x: f64) f64 {
    return x + 1;
}

fn wrenBindForeignMethodFn(
    vm: ?*wren_raw.WrenVM,
    module: [*c]const u8,
    className: [*c]const u8,
    isStatic: bool,
    signature: [*c]const u8,
) callconv(.c) wren_raw.WrenForeignMethodFn {
    _ = vm;
    if (isStatic and std.mem.eql(u8, std.mem.span(module), "main.wren") and std.mem.eql(u8, std.mem.span(className), "Test") and std.mem.eql(u8, std.mem.span(signature), "add1(_)")) {
        return wrenWrap(demo_add);
    }

    return null;
}

pub const ErrorType = enum {
    Compile,
    Runtime,
    StackTrace,
};

/// Generates a Wren foreign-method wrapper for `func`.
///
/// Supported here:
/// - arguments: f64, bool
/// - returns: f64, bool, void
pub fn wrenWrap(comptime func: anytype) wren_raw.WrenForeignMethodFn {
    const Func = @TypeOf(func);
    const func_info = switch (@typeInfo(Func)) {
        .@"fn" => |info| info,
        else => @compileError("wrenWrap expects a function"),
    };

    // Reject generic functions and parameters whose types are not concrete.
    inline for (func_info.params) |param| {
        if (param.type == null) {
            @compileError(
                "wrenWrap does not support generic or anytype parameters",
            );
        }
    }

    const Args = std.meta.ArgsTuple(Func);
    const Return = func_info.return_type orelse
        @compileError("function has no return type");

    return struct {
        fn wrapper(vm: ?*wren_raw.WrenVM) callconv(.c) void {
            var args: Args = undefined;

            inline for (func_info.params, 0..) |param, index| {
                const T = param.type.?;
                const slot: c_int = @intCast(index + 1);

                args[index] = Slots.read(T, vm, slot) catch return;
            }

            if (Return == void) {
                @call(.auto, func, args);
                wren_raw.wrenSetSlotNull(vm, 0);
            } else {
                const result: Return = @call(.auto, func, args);
                Slots.write(Return, vm, 0, result);
            }
        }
    }.wrapper;
}

fn wrenTypeName(comptime T: type) []const u8 {
    if (T == f64) return "Num";
    if (T == bool) return "Bool";

    @compileError(
        "unsupported Wren type: " ++ @typeName(T),
    );
}

const Slots = struct {
    const SlotError = error{
        WrongWrenType,
    };

    fn read(
        comptime T: type,
        vm: ?*wren_raw.WrenVM,
        slot: c_int,
    ) SlotError!T {
        if (T == f64) {
            if (wren_raw.wrenGetSlotType(vm, slot) != wren_raw.WREN_TYPE_NUM) {
                abort(T, vm, slot);
                return error.WrongWrenType;
            }

            return wren_raw.wrenGetSlotDouble(vm, slot);
        }

        if (T == bool) {
            if (wren_raw.wrenGetSlotType(vm, slot) != wren_raw.WREN_TYPE_BOOL) {
                return error.WrongWrenType;
            }

            return wren_raw.wrenGetSlotBool(vm, slot);
        }

        @compileError(
            "unsupported Wren argument type: " ++ @typeName(T),
        );
    }

    fn write(
        comptime T: type,
        vm: ?*wren_raw.WrenVM,
        slot: c_int,
        value: T,
    ) void {
        if (T == f64) {
            wren_raw.wrenSetSlotDouble(vm, slot, value);
            return;
        }

        if (T == bool) {
            wren_raw.wrenSetSlotBool(vm, slot, value);
            return;
        }

        @compileError(
            "unsupported Wren return type: " ++ @typeName(T),
        );
    }

    fn abort(comptime T: type, vm: ?*wren_raw.WrenVM, slot: i32) void {
        var message_buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrintZ(
            &message_buffer,
            "Argument {d}: expected {s}",
            .{ slot + 1, wrenTypeName(T) },
        ) catch {
            wren_raw.wrenSetSlotString(
                vm,
                0,
                "Invalid argument",
            );
            wren_raw.wrenAbortFiber(vm, 0);
            return;
        };

        wren_raw.wrenSetSlotString(vm, 0, message);
        wren_raw.wrenAbortFiber(vm, 0);
    }
};

pub const Vm = struct {
    pub const WriteFn = fn (text: []const u8) void;
    pub const ErrorFn = fn (error_type: ErrorType, module: ?[]const u8, line: i32, message: []const u8) void;

    pub const Config = struct {
        writeFn: ?*const WriteFn = null,
        errorFn: ?*const ErrorFn = null,
    };

    pub const InterpretError = error {
        CompileError,
        RuntimeError,
    };

    const VmData = struct {
        config: Config,
        raw_vm: ?*wren_raw.WrenVM = null,
        raw_config: wren_raw.WrenConfiguration = .{},
    };

    data: *VmData,

    pub fn init(gpa: std.mem.Allocator, config: Config) !Vm {
        var data = try gpa.create(VmData);
        data.config = config;

        wren_raw.wrenInitConfiguration(&data.raw_config);
        data.raw_config.writeFn = wrenWriteFn;
        data.raw_config.errorFn = wrenErrorFn;
        data.raw_config.bindForeignMethodFn = wrenBindForeignMethodFn;

        data.raw_vm = wren_raw.wrenNewVM(&data.raw_config);

        wren_raw.wrenSetUserData(data.raw_vm, @ptrCast(data));

        return .{
            .data = data,
        };
    }

    pub fn deinit(self: *Vm, gpa: std.mem.Allocator) void {
        wren_raw.wrenFreeVM(self.data.raw_vm);
        gpa.destroy(self.data);
    }

    pub fn interpret(self: *Vm, module: [*c]const u8, source: [*c]const u8) InterpretError!void {
        const result = wren_raw.wrenInterpret(self.data.raw_vm, module, source);
        switch (result) {
            wren_raw.WREN_RESULT_SUCCESS => return,
            wren_raw.WREN_RESULT_COMPILE_ERROR => return error.CompileError,
            wren_raw.WREN_RESULT_RUNTIME_ERROR => return error.RuntimeError,
            else => unreachable,
        }
    }
};
