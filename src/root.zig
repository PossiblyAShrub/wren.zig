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
/// Generates a foreign module that can be passed to `Vm.init`.
pub const module = bindings.module;
/// A borrowed, typed view of a Wren list passed to a foreign method.
pub const List = bindings.List;
/// A borrowed, typed view of a Wren map passed to a foreign method.
pub const Map = bindings.Map;
/// An allocated string consumed and freed after being copied into Wren.
pub const OwnedString = bindings.OwnedString;

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
    module_ptr: [*c]const u8,
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
        if (module_ptr == null) null else std.mem.span(module_ptr),
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

    const RuntimeConfig = struct {
        /// Optional output callback.
        writeFn: ?*const WriteFn = null,
        /// Optional error-reporting callback.
        errorFn: ?*const ErrorFn = null,
    };

    /// Errors returned after Wren reports compilation or runtime failure.
    pub const InterpretError = error{ CompileError, RuntimeError };

    const VmData = struct {
        config: RuntimeConfig,
        raw_vm: ?*raw.WrenVM = null,
    };

    data: *VmData,

    /// Creates and configures a Wren VM.
    ///
    /// `options` may contain `writeFn`, `errorFn`, and a heterogeneous tuple of
    /// generated `modules`. The modules are bound and interpreted in tuple order
    /// before this function returns, so application code may import them
    /// immediately.
    pub fn init(gpa: std.mem.Allocator, comptime options: anytype) !Vm {
        const Options = @TypeOf(options);
        inline for (std.meta.fields(Options)) |field| {
            if (comptime !std.mem.eql(u8, field.name, "writeFn") and
                !std.mem.eql(u8, field.name, "errorFn") and
                !std.mem.eql(u8, field.name, "modules"))
            {
                @compileError("unknown Vm.init option: " ++ field.name);
            }
        }
        const runtime_config: RuntimeConfig = .{
            .writeFn = if (@hasField(Options, "writeFn")) options.writeFn else null,
            .errorFn = if (@hasField(Options, "errorFn")) options.errorFn else null,
        };

        const data = try gpa.create(VmData);
        data.* = .{ .config = runtime_config };
        var vm_created = false;
        errdefer if (!vm_created) gpa.destroy(data);

        var raw_config: raw.WrenConfiguration = undefined;
        raw.wrenInitConfiguration(&raw_config);
        raw_config.writeFn = writeCallback;
        raw_config.errorFn = errorCallback;
        if (@hasField(Options, "modules")) {
            const Merged = bindings.mergeModules(options.modules);
            raw_config.bindForeignMethodFn = Merged.bindForeignMethod;
            raw_config.bindForeignClassFn = Merged.bindForeignClass;
        }
        raw_config.userData = data;

        data.raw_vm = raw.wrenNewVM(&raw_config);
        if (data.raw_vm == null) return error.OutOfMemory;
        vm_created = true;

        var vm: Vm = .{ .data = data };
        errdefer vm.deinit(gpa);
        if (@hasField(Options, "modules")) {
            inline for (options.modules) |Module| {
                try vm.interpret(Module.module, Module.source);
            }
        }
        return vm;
    }

    /// Frees the Wren VM and its auxiliary state using the allocator from `init`.
    pub fn deinit(self: *Vm, gpa: std.mem.Allocator) void {
        raw.wrenFreeVM(self.data.raw_vm);
        gpa.destroy(self.data);
        self.* = undefined;
    }

    /// Compiles and executes sentinel-terminated Wren source as `module_name`.
    pub fn interpret(self: *Vm, module_name: [*c]const u8, source: [*c]const u8) InterpretError!void {
        return switch (raw.wrenInterpret(self.data.raw_vm, module_name, source)) {
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
