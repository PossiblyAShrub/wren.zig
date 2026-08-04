const std = @import("std");
const raw = @import("wren_raw");
const slots = @import("slots.zig");

/// A borrowed, typed view of a Wren list.
pub const List = slots.List;
/// A borrowed, typed view of a Wren map.
pub const Map = slots.Map;
pub const String = slots.String;
pub const Value = slots.Value;
pub const Handle = slots.Handle;
pub const Context = slots.Context;
pub const Bool = slots.Bool;
pub const Num = slots.Num;
pub const Null = slots.Null;
pub const Object = slots.Object;
pub const Foreign = slots.Foreign;

/// Identifies how a Zig function is exposed in a generated Wren class.
pub const MethodKind = enum { static, instance, getter, setter, property };

pub const PropertyMode = enum { read_only, read_write };

fn MethodSpec(comptime Func: type) type {
    return struct {
        kind: MethodKind,
        wren_name: []const u8,
        function: Func,
    };
}

fn method(comptime kind: MethodKind, comptime name: []const u8, comptime func: anytype) MethodSpec(@TypeOf(func)) {
    return .{ .kind = kind, .wren_name = name, .function = func };
}

/// Declares a property backed directly by a field on a foreign Zig value.
/// The field name is a Zig field name; the first name is the Wren property.
pub fn Property(comptime name: []const u8, comptime field_name: []const u8, comptime mode: PropertyMode) struct {
    kind: MethodKind = .property,
    wren_name: []const u8 = name,
    field_name: []const u8 = field_name,
    mode: PropertyMode = mode,
} {
    return .{};
}

/// Declares a foreign static method named `name` backed by `func`.
pub fn Static(comptime name: []const u8, comptime func: anytype) MethodSpec(@TypeOf(func)) {
    return method(.static, name, func);
}

/// Declares a foreign instance method named `name` backed by `func`.
/// The first Zig parameter must be `*T` or `*const T` for the foreign class.
pub fn Method(comptime name: []const u8, comptime func: anytype) MethodSpec(@TypeOf(func)) {
    return method(.instance, name, func);
}

/// Declares a foreign getter named `name` backed by `func`.
pub fn Getter(comptime name: []const u8, comptime func: anytype) MethodSpec(@TypeOf(func)) {
    return method(.getter, name, func);
}

/// Declares a foreign setter named `name` backed by `func`.
pub fn Setter(comptime name: []const u8, comptime func: anytype) MethodSpec(@TypeOf(func)) {
    return method(.setter, name, func);
}

/// Declares a Wren constructor backed by a Zig function returning the foreign type.
/// The constructor may return either `T` or `!T`.
pub fn Constructor(comptime name: []const u8, comptime func: anytype) struct {
    wren_name: []const u8,
    function: @TypeOf(func),
} {
    return .{ .wren_name = name, .function = func };
}

/// Declares a Wren class containing foreign static methods.
/// `options` must contain `.name` and a tuple of `.methods`.
pub fn Class(comptime options: anytype) struct {
    is_foreign: bool,
    name: []const u8,
    methods: @TypeOf(options.methods),
} {
    return .{ .is_foreign = false, .name = options.name, .methods = options.methods };
}

/// Declares a foreign Wren class whose instance storage contains a `T`.
/// `options` must contain `.name`, `.constructor`, `.methods`, and an optional
/// `.finalizer` with the signature `fn (*T) void`.
pub fn ForeignClass(comptime T: type, comptime options: anytype) struct {
    is_foreign: bool,
    foreign_type: type,
    name: []const u8,
    constructor: @TypeOf(options.constructor),
    methods: @TypeOf(options.methods),
    finalizer: @TypeOf(options.finalizer),
} {
    return .{
        .is_foreign = true,
        .foreign_type = T,
        .name = options.name,
        .constructor = options.constructor,
        .methods = options.methods,
        .finalizer = options.finalizer,
    };
}

/// Generates one Wren foreign module from a declarative class configuration.
///
/// The returned type exposes `module`, generated `source`, and the two binding
/// callbacks used internally by `Vm`. Pass the returned type in `Vm.init`'s
/// `.modules` tuple to install it.
pub fn module(comptime config: anytype) type {
    validateApi(config);

    return struct {
        /// The module name supplied in the API configuration.
        pub const module = config.module;
        /// Generated, sentinel-terminated Wren declarations for this module.
        pub const source: [:0]const u8 = generateSource(config);

        /// Resolves a generated foreign method for Wren's C callback ABI.
        pub fn bindForeignMethod(
            vm: ?*raw.WrenVM,
            module_ptr: [*c]const u8,
            class_ptr: [*c]const u8,
            is_static: bool,
            signature_ptr: [*c]const u8,
        ) callconv(.c) raw.WrenForeignMethodFn {
            _ = vm;
            if (!std.mem.eql(u8, std.mem.span(module_ptr), config.module)) return null;

            const class_name = std.mem.span(class_ptr);
            const requested_signature = std.mem.span(signature_ptr);
            inline for (config.classes) |class| {
                if (std.mem.eql(u8, class_name, class.name)) {
                    inline for (class.methods) |bound_method| {
                        if ((bound_method.kind == .static) == is_static) {
                            if (bound_method.kind == .property) {
                                if (std.mem.eql(u8, requested_signature, bound_method.wren_name))
                                    return propertyWrap(class.foreign_type, bound_method.field_name, false);
                                if (bound_method.mode == .read_write and
                                    std.mem.eql(u8, requested_signature, bound_method.wren_name ++ "=(_)"))
                                    return propertyWrap(class.foreign_type, bound_method.field_name, true);
                            } else if (std.mem.eql(u8, requested_signature, methodSignature(class, bound_method))) {
                                if (bound_method.kind == .static) return wrap(config, null, bound_method.function);
                                return wrap(config, class.foreign_type, bound_method.function);
                            }
                        }
                    }
                }
            }
            return null;
        }

        /// Resolves allocation and finalization callbacks for a foreign class.
        pub fn bindForeignClass(
            vm: ?*raw.WrenVM,
            module_ptr: [*c]const u8,
            class_ptr: [*c]const u8,
        ) callconv(.c) raw.WrenForeignClassMethods {
            _ = vm;
            const none: raw.WrenForeignClassMethods = .{ .allocate = null, .finalize = null };
            if (!std.mem.eql(u8, std.mem.span(module_ptr), config.module)) return none;

            const class_name = std.mem.span(class_ptr);
            inline for (config.classes) |class| {
                if (class.is_foreign and std.mem.eql(u8, class_name, class.name)) {
                    return .{
                        .allocate = allocator(class.foreign_type, class.constructor.function),
                        .finalize = finalizer(class.foreign_type, class.finalizer),
                    };
                }
            }
            return none;
        }
    };
}

/// Combines generated modules into the callback pair required by Wren's C API.
///
/// This is public for the VM implementation; applications should normally pass
/// the tuple directly as `.modules` to `Vm.init`. Duplicate names are rejected.
pub fn mergeModules(comptime modules_value: anytype) type {
    validateMergedModules(modules_value);

    return struct {
        pub const modules = modules_value;

        /// Finds generated declarations by resolved module name.
        pub fn sourceFor(module_name: []const u8) ?[:0]const u8 {
            inline for (modules_value) |Module| {
                if (std.mem.eql(u8, module_name, Module.module)) return Module.source;
            }
            return null;
        }

        /// Dispatches Wren's method-binding callback to the matching module.
        pub fn bindForeignMethod(
            vm: ?*raw.WrenVM,
            module_ptr: [*c]const u8,
            class_ptr: [*c]const u8,
            is_static: bool,
            signature_ptr: [*c]const u8,
        ) callconv(.c) raw.WrenForeignMethodFn {
            inline for (modules_value) |Module| {
                if (Module.bindForeignMethod(vm, module_ptr, class_ptr, is_static, signature_ptr)) |callback| {
                    return callback;
                }
            }
            return null;
        }

        /// Dispatches Wren's foreign-class callback to the matching module.
        pub fn bindForeignClass(
            vm: ?*raw.WrenVM,
            module_ptr: [*c]const u8,
            class_ptr: [*c]const u8,
        ) callconv(.c) raw.WrenForeignClassMethods {
            inline for (modules_value) |Module| {
                const methods = Module.bindForeignClass(vm, module_ptr, class_ptr);
                if (methods.allocate != null) return methods;
            }
            return .{ .allocate = null, .finalize = null };
        }
    };
}

fn validateMergedModules(comptime modules: anytype) void {
    inline for (modules, 0..) |Module, index| {
        inline for (modules, 0..) |Other, other_index| {
            if (other_index > index and std.mem.eql(u8, Module.module, Other.module)) {
                @compileError("duplicate Wren module: " ++ Module.module);
            }
        }
    }
}

fn functionInfo(comptime func: anytype) std.builtin.Type.Fn {
    return switch (@typeInfo(@TypeOf(func))) {
        .@"fn" => |info| info,
        else => @compileError("expected a function"),
    };
}

fn payloadType(comptime Return: type) type {
    return switch (@typeInfo(Return)) {
        .error_union => |info| info.payload,
        else => Return,
    };
}

fn isContextType(comptime T: type) bool {
    return T == *slots.Context;
}

fn foreignClassName(comptime config: anytype, comptime T: type) []const u8 {
    inline for (config.classes) |class| {
        if (class.is_foreign and class.foreign_type == T) return class.name;
    }
    @compileError("foreign return type is not registered in this module: " ++ @typeName(T));
}

fn isRegisteredForeign(comptime config: anytype, comptime T: type) bool {
    inline for (config.classes) |class| {
        if (class.is_foreign and class.foreign_type == T) return true;
    }
    return false;
}

fn contextIndex(comptime Owner: ?type, comptime func: anytype) ?usize {
    const info = functionInfo(func);
    const first = if (Owner == null) 0 else 1;
    if (info.params.len > first and isContextType(info.params[first].type.?)) return first;
    return null;
}

fn contextType(comptime Owner: ?type, comptime func: anytype) type {
    const index = contextIndex(Owner, func) orelse return void;
    _ = index;
    return slots.Context;
}

fn decodeArgs(comptime Owner: ?type, comptime func: anytype, vm: ?*raw.WrenVM, context_ptr: ?*anyopaque) slots.Error!std.meta.ArgsTuple(@TypeOf(func)) {
    const info = functionInfo(func);
    var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
    const context_at = comptime contextIndex(Owner, func);
    inline for (info.params, 0..) |param, index| {
        const T = param.type.?;
        if (Owner != null and index == 0) {
            args[index] = try slots.read(T, vm, 0);
        } else if (comptime context_at != null) {
            if (index == context_at.?) {
                args[index] = @ptrCast(@alignCast(context_ptr.?));
            } else {
                const receiver_count: usize = if (Owner == null) 0 else 1;
                const context_count: usize = if (comptime index > context_at.?) 1 else 0;
                args[index] = try slots.read(T, vm, @intCast(index + 1 - receiver_count - context_count));
            }
        } else {
            const receiver_count: usize = if (Owner == null) 0 else 1;
            args[index] = try slots.read(T, vm, @intCast(index + 1 - receiver_count));
        }
    }
    return args;
}

fn writeResult(comptime config: anytype, comptime Return: type, value: Return, vm: ?*raw.WrenVM) void {
    if (comptime isRegisteredForeign(config, Return)) {
        const T = Return;
        const class_slot = scratchSlots(vm, 1);
        raw.wrenGetVariable(vm, config.module.ptr, foreignClassName(config, T).ptr, class_slot);
        const storage = raw.wrenSetSlotNewForeign(vm, 0, class_slot, slots.foreignAllocationSize(T)) orelse {
            slots.abortMessage(vm, "Failed to allocate returned foreign object");
            return;
        };
        slots.initForeign(T, storage, value);
        return;
    }
    slots.write(Return, vm, 0, value) catch {};
}

fn scratchSlots(vm: ?*raw.WrenVM, count: c_int) c_int {
    const first = raw.wrenGetSlotCount(vm);
    raw.wrenEnsureSlots(vm, first + count);
    return first;
}

fn callAndWrite(comptime config: anytype, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func)), vm: ?*raw.WrenVM) void {
    const Return = functionInfo(func).return_type orelse @compileError("function must have a return type");
    switch (@typeInfo(Return)) {
        .error_union => |info| {
            const result = @call(.auto, func, args) catch |err| {
                if (err != error.BindingAborted) slots.abortMessage(vm, @errorName(err));
                return;
            };
            writeResult(config, info.payload, result, vm);
        },
        else => {
            const result: Return = @call(.auto, func, args);
            writeResult(config, Return, result, vm);
        },
    }
}

fn wrap(comptime config: anytype, comptime Owner: ?type, comptime func: anytype) raw.WrenForeignMethodFn {
    return struct {
        fn callback(vm: ?*raw.WrenVM) callconv(.c) void {
            const ContextType = contextType(Owner, func);
            var context: ContextType = undefined;
            if (comptime ContextType != void) context = .{ .vm = vm };
            const context_ptr: ?*anyopaque = if (comptime ContextType == void) null else @ptrCast(&context);
            const args = decodeArgs(Owner, func, vm, context_ptr) catch return;
            callAndWrite(config, func, args, vm);
        }
    }.callback;
}

fn propertyWrap(comptime T: type, comptime field_name: []const u8, comptime setter: bool) raw.WrenForeignMethodFn {
    return struct {
        fn callback(vm: ?*raw.WrenVM) callconv(.c) void {
            const receiver = slots.getForeign(*T, vm, 0) catch return;
            const Field = @TypeOf(@field(receiver.*, field_name));
            if (setter) {
                const value = slots.read(Field, vm, 1) catch return;
                @field(receiver.*, field_name) = value;
            } else {
                slots.write(Field, vm, 0, @field(receiver.*, field_name)) catch {};
            }
        }
    }.callback;
}

fn allocator(comptime T: type, comptime constructor: anytype) raw.WrenForeignMethodFn {
    return struct {
        fn allocate(vm: ?*raw.WrenVM) callconv(.c) void {
            const ContextType = contextType(null, constructor);
            var context: ContextType = undefined;
            if (comptime ContextType != void) context = .{ .vm = vm };
            const context_ptr: ?*anyopaque = if (comptime ContextType == void) null else @ptrCast(&context);
            const args = decodeArgs(null, constructor, vm, context_ptr) catch return;
            const Return = functionInfo(constructor).return_type.?;
            const value: T = switch (@typeInfo(Return)) {
                .error_union => @call(.auto, constructor, args) catch |err| {
                    if (err != error.BindingAborted) slots.abortMessage(vm, @errorName(err));
                    return;
                },
                else => @call(.auto, constructor, args),
            };
            const storage = raw.wrenSetSlotNewForeign(vm, 0, 0, slots.foreignAllocationSize(T)) orelse {
                slots.abortMessage(vm, "Failed to allocate foreign object");
                return;
            };
            slots.initForeign(T, storage, value);
        }
    }.allocate;
}

fn finalizer(comptime T: type, comptime func: anytype) raw.WrenFinalizerFn {
    if (@TypeOf(func) == @TypeOf(null)) return null;
    return struct {
        fn finalize(data: ?*anyopaque) callconv(.c) void {
            const value = slots.finalizeForeign(T, data) orelse return;
            @call(.auto, func, .{value});
        }
    }.finalize;
}

fn exposedArity(comptime bound_method: anytype) usize {
    if (comptime bound_method.kind == .property) return if (comptime bound_method.mode == .read_write) 1 else 0;
    const count = functionInfo(bound_method.function).params.len;
    const receiver_count: usize = if (comptime bound_method.kind == .static) 0 else 1;
    const context_at = comptime contextParam(bound_method.kind, bound_method.function);
    const result = count - receiver_count - if (context_at != null) 1 else 0;
    return result;
}

fn contextParam(comptime kind: MethodKind, comptime func: anytype) ?usize {
    return contextIndex(if (kind == .static) null else @as(?type, u8), func);
}

const ArgumentStyle = enum { signature, declaration };

fn arguments(comptime arity: usize, comptime style: ArgumentStyle) []const u8 {
    @setEvalBranchQuota(100000);
    comptime var result: []const u8 = "(";
    inline for (0..arity) |index| {
        if (index != 0) result = result ++ switch (style) {
            .signature => ",",
            .declaration => ", ",
        };
        result = result ++ switch (style) {
            .signature => "_",
            .declaration => std.fmt.comptimePrint("arg{d}", .{index}),
        };
    }
    return result ++ ")";
}

fn methodSignature(comptime class: anytype, comptime bound_method: anytype) []const u8 {
    _ = class;
    return comptime switch (bound_method.kind) {
        .property => bound_method.wren_name,
        .getter => bound_method.wren_name,
        .setter => bound_method.wren_name ++ "=(_)",
        .static, .instance => bound_method.wren_name ++ arguments(exposedArity(bound_method), .signature),
    };
}

fn methodDeclaration(comptime class: anytype, comptime bound_method: anytype) []const u8 {
    _ = class;
    return comptime switch (bound_method.kind) {
        .property => bound_method.wren_name,
        .static => "static " ++ bound_method.wren_name ++ arguments(exposedArity(bound_method), .declaration),
        .instance => bound_method.wren_name ++ arguments(exposedArity(bound_method), .declaration),
        .getter => bound_method.wren_name,
        .setter => bound_method.wren_name ++ "=" ++ arguments(exposedArity(bound_method), .declaration),
    };
}

fn generateSource(comptime config: anytype) [:0]const u8 {
    comptime var source: []const u8 = "";
    inline for (config.classes) |class| {
        source = source ++ (if (class.is_foreign) "foreign class " else "class ") ++ class.name ++ " {\n";
        if (class.is_foreign) {
            source = source ++ "  construct " ++ class.constructor.wren_name ++
                arguments(constructorArity(class.constructor.function), .declaration) ++ " {}\n";
        }
        inline for (class.methods) |bound_method| {
            source = source ++ "  foreign " ++ methodDeclaration(class, bound_method) ++ "\n";
            if (bound_method.kind == .property and bound_method.mode == .read_write) {
                source = source ++ "  foreign " ++ bound_method.wren_name ++ "=(arg0)\n";
            }
        }
        source = source ++ "}\n\n";
    }
    // wrenInterpret consumes a C string, while the public slice should exclude
    // that terminator. Appending then sentinel-slicing provides both properties.
    return (source ++ "\x00")[0..source.len :0];
}

fn constructorArity(comptime func: anytype) usize {
    const info = functionInfo(func);
    const context_at = comptime contextIndex(null, func);
    return info.params.len - if (context_at != null) 1 else 0;
}

fn validateApi(comptime config: anytype) void {
    if (config.module.len == 0) @compileError("Wren module name cannot be empty");
    inline for (config.classes, 0..) |class, class_index| {
        if (class.name.len == 0) @compileError("Wren class name cannot be empty");
        inline for (config.classes, 0..) |other, other_index| {
            if (other_index > class_index and std.mem.eql(u8, class.name, other.name))
                @compileError("duplicate Wren class: " ++ class.name);
        }
        if (class.is_foreign) validateConstructor(class);
        inline for (class.methods, 0..) |bound_method, method_index| {
            validateMethod(config, class, bound_method);
            inline for (class.methods, 0..) |other, other_index| {
                if (other_index > method_index and
                    (bound_method.kind == .static) == (other.kind == .static) and
                    std.mem.eql(u8, methodSignature(class, bound_method), methodSignature(class, other)))
                {
                    @compileError("duplicate Wren method in class " ++ class.name ++ ": " ++ methodSignature(class, bound_method));
                }
            }
        }
    }
}

fn validateConstructor(comptime class: anytype) void {
    const info = functionInfo(class.constructor.function);
    const Return = info.return_type orelse @compileError("constructor must return a value");
    if (payloadType(Return) != class.foreign_type)
        @compileError("constructor for " ++ class.name ++ " must return " ++ @typeName(class.foreign_type));
    const context_at = contextIndex(null, class.constructor.function);
    inline for (info.params, 0..) |param, index| {
        if (context_at != null and index == context_at.?) continue;
        slots.validateReadable(param.type.?);
    }
    validateFinalizer(class.foreign_type, class.finalizer);
}

fn validateFinalizer(comptime T: type, comptime func: anytype) void {
    if (@TypeOf(func) == @TypeOf(null)) return;
    const info = functionInfo(func);
    if (info.params.len != 1 or info.params[0].type.? != *T or info.return_type.? != void)
        @compileError("foreign finalizer must have signature fn (*" ++ @typeName(T) ++ ") void");
}

fn validateMethod(comptime config: anytype, comptime class: anytype, comptime bound_method: anytype) void {
    if (bound_method.wren_name.len == 0) @compileError("Wren method name cannot be empty");
    if (bound_method.kind == .property) {
        if (!class.is_foreign) @compileError("properties require a foreign class");
        if (!@hasField(class.foreign_type, bound_method.field_name))
            @compileError("unknown property field " ++ bound_method.field_name ++ " on " ++ @typeName(class.foreign_type));
        const Field = @TypeOf(@field(@as(class.foreign_type, undefined), bound_method.field_name));
        slots.validateWritable(Field);
        if (bound_method.mode == .read_write) slots.validateReadable(Field);
        return;
    }
    const info = functionInfo(bound_method.function);
    const receiver_count: usize = if (bound_method.kind == .static) 0 else 1;
    if (receiver_count == 1) {
        if (!class.is_foreign) @compileError("instance methods require a foreign class");
        if (info.params.len == 0) @compileError("instance method requires a receiver");
        const Receiver = info.params[0].type.?;
        const receiver_is_foreign = Receiver == slots.Foreign(class.foreign_type);
        if (!receiver_is_foreign and Receiver != *class.foreign_type and Receiver != *const class.foreign_type)
            @compileError("invalid receiver for " ++ class.name);
    }
    const arity = info.params.len - receiver_count;
    const context_at = contextParam(bound_method.kind, bound_method.function);
    const exposed = arity - if (context_at != null) 1 else 0;
    if (bound_method.kind == .getter and exposed != 0) @compileError("Wren getter must take no arguments");
    if (bound_method.kind == .setter and exposed != 1) @compileError("Wren setter must take one argument");
    inline for (info.params[receiver_count..], receiver_count..) |param, index| {
        if (context_at != null and index == context_at.?) continue;
        slots.validateReadable(param.type.?);
    }
    const Return = payloadType(info.return_type orelse @compileError("function must have a return type"));
    if (comptime isRegisteredForeign(config, Return)) {
        _ = foreignClassName(config, Return);
    } else {
        slots.validateWritable(Return);
    }
}
