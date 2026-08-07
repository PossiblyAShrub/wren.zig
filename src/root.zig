const std = @import("std");
const raw = @import("wren_raw");
const bindings = @import("bindings.zig");
const context = @import("context.zig");

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
/// A Wren-owned string value.
pub const String = bindings.String;
/// A callback-scoped value stored in a Wren VM slot.
pub const Value = bindings.Value;
/// A rooted Wren value that must be explicitly released.
pub const Handle = bindings.Handle;
/// Typed access to the active Wren VM.
pub const Context = bindings.Context;
pub const Bool = bindings.Bool;
pub const Num = bindings.Num;
pub const Null = bindings.Null;
pub const Object = bindings.Object;
pub const Foreign = bindings.Foreign;
/// Generates Wren property accessors for a foreign struct field.
pub const Property = bindings.Property;
/// Declares a field-backed property using the same Wren and Zig name.
pub const Field = bindings.Field;
pub const PropertyMode = bindings.PropertyMode;

/// Describes an error reported by the Wren VM.
pub const ErrorType = enum {
    /// A source parsing or compilation error.
    Compile,
    /// The error that aborted the running fiber.
    Runtime,
    /// One frame in the stack trace following a runtime error.
    StackTrace,
};

/// Owns a Wren virtual machine and adapts its C callbacks to Zig functions.
pub fn Vm(comptime T: type) type {
    return struct {
        const Self = @This();

        fn writeCallback(vm: ?*raw.WrenVM, text: [*c]const u8) callconv(.c) void {
            // VmData is installed as Wren's user data during VM construction, allowing
            // this C callback to recover the Zig callback configuration.
            const data: *VmData = @ptrCast(@alignCast(raw.wrenGetUserData(vm)));
            const callback = data.config.writeFn orelse return;
            callback(data.user_data, std.mem.span(text));
        }

        fn errorCallback(
            vm: ?*raw.WrenVM,
            kind: raw.WrenErrorType,
            module_ptr: [*c]const u8,
            line: c_int,
            message: [*c]const u8,
        ) callconv(.c) void {
            const data: *VmData = @ptrCast(@alignCast(raw.wrenGetUserData(vm)));
            const callback = data.config.errorFn orelse return;
            const error_type: ErrorType = switch (kind) {
                raw.WREN_ERROR_COMPILE => .Compile,
                raw.WREN_ERROR_RUNTIME => .Runtime,
                raw.WREN_ERROR_STACK_TRACE => .StackTrace,
                else => unreachable,
            };
            callback(
                data.user_data,
                error_type,
                if (module_ptr == null) null else std.mem.span(module_ptr),
                @intCast(line),
                std.mem.span(message),
            );
        }

        /// Receives text written by Wren's `System.write` and `System.print`.
        pub const WriteFn = fn (user_data: ?*T, text: []const u8) void;
        /// Receives compile errors, runtime errors, and stack-trace frames.
        pub const ErrorFn = fn (user_data: ?*T, error_type: ErrorType, module: ?[]const u8, line: i32, message: []const u8) void;

        const RuntimeConfig = struct {
            /// Optional output callback.
            writeFn: ?*const WriteFn = null,
            /// Optional error-reporting callback.
            errorFn: ?*const ErrorFn = null,
        };

        /// Errors returned after Wren reports compilation or runtime failure.
        pub const InterpretError = error{ CompileError, RuntimeError };

        const VmData = struct {
            runtime: context.RuntimeData,
            config: RuntimeConfig,
            raw_vm: ?*raw.WrenVM = null,
            user_data: ?*T,
        };

        data: *VmData,

        /// Creates and configures a Wren VM.
        ///
        /// `options` may contain `writeFn`, `errorFn`, and a heterogeneous tuple of
        /// generated `modules`. The modules are bound and interpreted in tuple order
        /// before this function returns, so application code may import them
        /// immediately.
        pub fn init(gpa: std.mem.Allocator, user_data: ?*T, comptime options: anytype) !Self {
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
            data.* = .{
                .runtime = .{
                    .allocator = gpa,
                    .user_data = if (user_data) |ptr| @ptrCast(ptr) else null,
                },
                .config = runtime_config,
                .user_data = user_data,
            };
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

            var vm: Self = .{ .data = data };
            errdefer vm.deinit(gpa);
            if (@hasField(Options, "modules")) {
                inline for (options.modules) |Module| {
                    try vm.interpret(Module.module, Module.source);
                }
            }
            return vm;
        }

        /// Frees the Wren VM and its auxiliary state using the allocator from `init`.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            raw.wrenFreeVM(self.data.raw_vm);
            allocator.destroy(self.data);
            self.* = undefined;
        }

        /// Frees the VM using the allocator supplied to `init`.
        pub fn deinitOwned(self: *Self) void {
            raw.wrenFreeVM(self.data.raw_vm);
            self.data.runtime.allocator.destroy(self.data);
            self.* = undefined;
        }

        /// Compiles and executes sentinel-terminated Wren source as `module_name`.
        pub fn interpret(self: *Self, module_name: [:0]const u8, source: [:0]const u8) InterpretError!void {
            return switch (raw.wrenInterpret(self.data.raw_vm, module_name.ptr, source.ptr)) {
                raw.WREN_RESULT_SUCCESS => {},
                raw.WREN_RESULT_COMPILE_ERROR => error.CompileError,
                raw.WREN_RESULT_RUNTIME_ERROR => error.RuntimeError,
                else => unreachable,
            };
        }

        /// Immediately runs Wren's garbage collector and pending finalizers.
        pub fn collectGarbage(self: *Self) void {
            raw.wrenCollectGarbage(self.data.raw_vm);
        }

        fn fromSlot(self: *Self) !bindings.Handle {
            const handle = raw.wrenGetSlotHandle(self.data.raw_vm, 0) orelse return error.OutOfMemory;
            return .{ .vm = self.data.raw_vm, .handle = handle };
        }

        /// Creates a rooted Wren number.
        pub fn number(self: *Self, value: f64) !bindings.Handle {
            raw.wrenEnsureSlots(self.data.raw_vm, 1);
            raw.wrenSetSlotDouble(self.data.raw_vm, 0, value);
            return self.fromSlot();
        }

        /// Creates a rooted Wren boolean.
        pub fn boolean(self: *Self, value: bool) !bindings.Handle {
            raw.wrenEnsureSlots(self.data.raw_vm, 1);
            raw.wrenSetSlotBool(self.data.raw_vm, 0, value);
            return self.fromSlot();
        }

        /// Creates a rooted Wren string from arbitrary bytes.
        pub fn string(self: *Self, bytes: []const u8) !bindings.Handle {
            raw.wrenEnsureSlots(self.data.raw_vm, 1);
            raw.wrenSetSlotBytes(self.data.raw_vm, 0, bytes.ptr, bytes.len);
            return self.fromSlot();
        }

        /// Creates a rooted Wren null value.
        pub fn nullValue(self: *Self) !bindings.Handle {
            raw.wrenEnsureSlots(self.data.raw_vm, 1);
            raw.wrenSetSlotNull(self.data.raw_vm, 0);
            return self.fromSlot();
        }

        /// Creates a rooted foreign value outside a Wren callback.
        pub fn foreign(self: *Self, comptime Module: type, comptime ForeignType: type, value: ForeignType) !bindings.Handle {
            raw.wrenEnsureSlots(self.data.raw_vm, 1);
            try Module.setForeign(self.data.raw_vm, 0, ForeignType, value);
            const handle = raw.wrenGetSlotHandle(self.data.raw_vm, 0) orelse return error.OutOfMemory;
            return .{ .vm = self.data.raw_vm, .handle = handle };
        }

        /// Roots a top-level Wren variable for host-side use.
        pub fn variable(self: *Self, module_name: [:0]const u8, name: [:0]const u8) !bindings.Handle {
            if (!raw.wrenHasVariable(self.data.raw_vm, module_name.ptr, name.ptr)) return error.VariableNotFound;
            raw.wrenEnsureSlots(self.data.raw_vm, 1);
            raw.wrenGetVariable(self.data.raw_vm, module_name.ptr, name.ptr, 0);
            const handle = raw.wrenGetSlotHandle(self.data.raw_vm, 0) orelse return error.OutOfMemory;
            return .{ .vm = self.data.raw_vm, .handle = handle };
        }

        /// Returns whether a top-level variable exists in a module.
        pub fn hasVariable(self: *Self, module_name: [:0]const u8, name: [:0]const u8) bool {
            return raw.wrenHasVariable(self.data.raw_vm, module_name.ptr, name.ptr);
        }

        /// Returns whether a module has been loaded by Wren.
        pub fn hasModule(self: *Self, module_name: [:0]const u8) bool {
            return raw.wrenHasModule(self.data.raw_vm, module_name.ptr);
        }

        /// Invokes a Wren method with a rooted receiver and rooted arguments.
        pub fn call(self: *Self, receiver: bindings.Handle, signature: [:0]const u8, args: []const bindings.Handle) !bindings.Handle {
            if (receiver.vm != self.data.raw_vm) return error.WrongVm;
            raw.wrenEnsureSlots(self.data.raw_vm, @intCast(args.len + 1));
            receiver.set(0);
            for (args, 0..) |arg, index| {
                if (arg.vm != self.data.raw_vm) return error.WrongVm;
                arg.set(@intCast(index + 1));
            }

            const method = raw.wrenMakeCallHandle(self.data.raw_vm, signature.ptr) orelse return error.OutOfMemory;
            defer raw.wrenReleaseHandle(self.data.raw_vm, method);
            switch (raw.wrenCall(self.data.raw_vm, method)) {
                raw.WREN_RESULT_SUCCESS => {},
                raw.WREN_RESULT_COMPILE_ERROR => return error.CompileError,
                raw.WREN_RESULT_RUNTIME_ERROR => return error.RuntimeError,
                else => unreachable,
            }
            return self.fromSlot();
        }

        /// Calls a method and decodes its rooted result as `Result`.
        pub fn callValue(self: *Self, comptime Result: type, receiver: bindings.Handle, signature: [:0]const u8, args: []const bindings.Handle) !Result {
            var result = try self.call(receiver, signature, args);
            defer result.release();
            return result.as(Result);
        }
    };
}
