const std = @import("std");
const wren_raw = @import("wren_raw");

fn wrenWriteFn(vm: ?*wren_raw.WrenVM, text: [*c]const u8) callconv(.c) void {
    const data_ptr_raw = wren_raw.wrenGetUserData(vm);
    const data_ptr: *Vm.VmData = @ptrCast(@alignCast(data_ptr_raw));
    if (data_ptr.config.writeFn == null) return;

    data_ptr.config.writeFn.?(text);
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

    data_ptr.config.errorFn.?(error_type, module, @intCast(line), message);
}

pub const ErrorType = enum {
    Compile,
    Runtime,
    StackTrace,
};

pub const Vm = struct {
    pub const WriteFn = fn (text: [*c]const u8) void;
    pub const ErrorFn = fn (error_type: ErrorType, module: [*c]const u8, line: i32, message: [*c]const u8) void;

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
