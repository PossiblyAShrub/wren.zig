const std = @import("std");
const raw = @import("wren_raw");
const bindings = @import("bindings.zig");

/// Declares a foreign static method in a generated Wren class.
pub const Static = bindings.Static;
/// Declares a foreign instance method for a Zig-backed foreign class.
pub const Method = bindings.Method;
/// Declares a foreign property getter for a Zig-backed foreign class.
pub const Getter = bindings.Getter;
/// Declares a foreign property setter for a Zig-backed foreign class.
pub const Setter = bindings.Setter;
/// Declares the constructor used to initialize a Zig-backed foreign class.
pub const Constructor = bindings.Constructor;
/// Declares a Wren class containing foreign static methods.
pub const Class = bindings.Class;
/// Declares a Wren foreign class whose instances contain a Zig value.
pub const ForeignClass = bindings.ForeignClass;
/// Generates source and binding callbacks for one Wren foreign module.
pub const wrenApi = bindings.wrenApi;
/// Combines generated APIs for distinct modules into one binding callback pair.
pub const mergeApis = bindings.mergeApis;
/// A borrowed, typed view of a Wren list passed to a foreign method.
pub const List = bindings.List;
/// A borrowed, typed view of a Wren map passed to a foreign method.
pub const Map = bindings.Map;

/// Describes an error reported by the Wren VM.
pub const ErrorType = enum {
    /// A source parsing or compilation error.
    Compile,
    /// The error that aborted the running fiber.
    Runtime,
    /// One frame in the stack trace following a runtime error.
    StackTrace,
};

fn writeCallback(vm: ?*raw.WrenVM, text: [*c]const u8) callconv(.c) void {
    // VmData is installed as Wren's user data during VM construction, allowing
    // this C callback to recover the Zig callback configuration.
    const data: *Vm.VmData = @ptrCast(@alignCast(raw.wrenGetUserData(vm)));
    const callback = data.config.writeFn orelse return;
    callback(std.mem.span(text));
}

fn errorCallback(
    vm: ?*raw.WrenVM,
    kind: raw.WrenErrorType,
    module: [*c]const u8,
    line: c_int,
    message: [*c]const u8,
) callconv(.c) void {
    const data: *Vm.VmData = @ptrCast(@alignCast(raw.wrenGetUserData(vm)));
    const callback = data.config.errorFn orelse return;
    const error_type: ErrorType = switch (kind) {
        raw.WREN_ERROR_COMPILE => .Compile,
        raw.WREN_ERROR_RUNTIME => .Runtime,
        raw.WREN_ERROR_STACK_TRACE => .StackTrace,
        else => unreachable,
    };
    callback(
        error_type,
        if (module == null) null else std.mem.span(module),
        @intCast(line),
        std.mem.span(message),
    );
}

/// Owns a Wren virtual machine and adapts its C callbacks to Zig functions.
pub const Vm = struct {
    /// Receives text written by Wren's `System.write` and `System.print`.
    pub const WriteFn = fn (text: []const u8) void;
    /// Receives compile errors, runtime errors, and stack-trace frames.
    pub const ErrorFn = fn (error_type: ErrorType, module: ?[]const u8, line: i32, message: []const u8) void;

    /// Controls host callbacks installed when creating a VM.
    pub const Config = struct {
        /// Optional output callback.
        writeFn: ?*const WriteFn = null,
        /// Optional error-reporting callback.
        errorFn: ?*const ErrorFn = null,
        /// Optional method resolver, usually from `wrenApi` or `mergeApis`.
        bindForeignMethodFn: raw.WrenBindForeignMethodFn = null,
        /// Optional class resolver, usually from `wrenApi` or `mergeApis`.
        bindForeignClassFn: raw.WrenBindForeignClassFn = null,
    };

    /// Errors returned after Wren reports compilation or runtime failure.
    pub const InterpretError = error{ CompileError, RuntimeError };

    const VmData = struct {
        config: Config,
        raw_vm: ?*raw.WrenVM = null,
    };

    data: *VmData,

    /// Creates a VM whose auxiliary Zig state is allocated with `gpa`.
    pub fn init(gpa: std.mem.Allocator, config: Config) !Vm {
        const data = try gpa.create(VmData);
        errdefer gpa.destroy(data);
        data.* = .{ .config = config };

        var raw_config: raw.WrenConfiguration = undefined;
        raw.wrenInitConfiguration(&raw_config);
        raw_config.writeFn = writeCallback;
        raw_config.errorFn = errorCallback;
        raw_config.bindForeignMethodFn = config.bindForeignMethodFn;
        raw_config.bindForeignClassFn = config.bindForeignClassFn;
        raw_config.userData = data;

        data.raw_vm = raw.wrenNewVM(&raw_config);
        if (data.raw_vm == null) return error.OutOfMemory;
        return .{ .data = data };
    }

    /// Frees the Wren VM and its auxiliary state using the allocator from `init`.
    pub fn deinit(self: *Vm, gpa: std.mem.Allocator) void {
        raw.wrenFreeVM(self.data.raw_vm);
        gpa.destroy(self.data);
        self.* = undefined;
    }

    /// Compiles and executes sentinel-terminated Wren source as `module`.
    pub fn interpret(self: *Vm, module: [*c]const u8, source: [*c]const u8) InterpretError!void {
        return switch (raw.wrenInterpret(self.data.raw_vm, module, source)) {
            raw.WREN_RESULT_SUCCESS => {},
            raw.WREN_RESULT_COMPILE_ERROR => error.CompileError,
            raw.WREN_RESULT_RUNTIME_ERROR => error.RuntimeError,
            else => unreachable,
        };
    }

    /// Immediately runs Wren's garbage collector and pending finalizers.
    pub fn collectGarbage(self: *Vm) void {
        raw.wrenCollectGarbage(self.data.raw_vm);
    }
};
