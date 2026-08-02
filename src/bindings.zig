const std = @import("std");
const raw = @import("wren_raw");
const slots = @import("slots.zig");

/// A borrowed, typed view of a Wren list.
pub const List = slots.List;
/// A borrowed, typed view of a Wren map.
pub const Map = slots.Map;

/// Identifies how a Zig function is exposed in a generated Wren class.
pub const MethodKind = enum { static, instance, getter, setter };

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
/// callbacks accepted by `Vm.Config`. Use `mergeApis` when a VM hosts more than
/// one generated foreign module.
pub fn wrenApi(comptime config: anytype) type {
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
                        if ((bound_method.kind == .static) == is_static and
                            std.mem.eql(u8, requested_signature, methodSignature(class, bound_method)))
                        {
                            if (bound_method.kind == .static) return wrap(null, bound_method.function);
                            return wrap(class.foreign_type, bound_method.function);
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

/// Combines generated APIs for distinct Wren modules into one callback pair.
///
/// Existing APIs keep their own `module` and `source`; interpret each source
/// once before importing it. The returned type exposes `apis`, `sourceFor`,
/// `bindForeignMethod`, and `bindForeignClass`. Duplicate module names are a
/// compile error.
///
/// ```zig
/// const AllApis = wren.mergeApis(.{ MathApi, GameApi });
/// var vm = try wren.Vm.init(allocator, .{
///     .bindForeignMethodFn = AllApis.bindForeignMethod,
///     .bindForeignClassFn = AllApis.bindForeignClass,
/// });
/// ```
pub fn mergeApis(comptime apis_value: anytype) type {
    validateMergedApis(apis_value);

    return struct {
        /// The tuple of generated API types supplied to `mergeApis`.
        pub const apis = apis_value;

        /// Finds generated declarations by resolved Wren module name.
        pub fn sourceFor(module_name: []const u8) ?[:0]const u8 {
            inline for (apis_value) |Api| {
                if (std.mem.eql(u8, module_name, Api.module)) return Api.source;
            }
            return null;
        }

        /// Dispatches Wren's method-binding callback to the matching module API.
        pub fn bindForeignMethod(
            vm: ?*raw.WrenVM,
            module_ptr: [*c]const u8,
            class_ptr: [*c]const u8,
            is_static: bool,
            signature_ptr: [*c]const u8,
        ) callconv(.c) raw.WrenForeignMethodFn {
            inline for (apis_value) |Api| {
                if (Api.bindForeignMethod(vm, module_ptr, class_ptr, is_static, signature_ptr)) |callback| {
                    return callback;
                }
            }
            return null;
        }

        /// Dispatches Wren's foreign-class callback to the matching module API.
        pub fn bindForeignClass(
            vm: ?*raw.WrenVM,
            module_ptr: [*c]const u8,
            class_ptr: [*c]const u8,
        ) callconv(.c) raw.WrenForeignClassMethods {
            inline for (apis_value) |Api| {
                const methods = Api.bindForeignClass(vm, module_ptr, class_ptr);
                if (methods.allocate != null) return methods;
            }
            return .{ .allocate = null, .finalize = null };
        }
    };
}

fn validateMergedApis(comptime apis: anytype) void {
    inline for (apis, 0..) |Api, index| {
        inline for (apis, 0..) |Other, other_index| {
            if (other_index > index and std.mem.eql(u8, Api.module, Other.module)) {
                @compileError("duplicate Wren module: " ++ Api.module);
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

fn decodeArgs(comptime Owner: ?type, comptime func: anytype, vm: ?*raw.WrenVM) slots.Error!std.meta.ArgsTuple(@TypeOf(func)) {
    const info = functionInfo(func);
    var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
    inline for (info.params, 0..) |param, index| {
        const T = param.type.?;
        if (Owner != null and index == 0) {
            args[index] = try slots.getForeign(T, vm, 0);
        } else {
            const receiver_count: usize = if (Owner == null) 0 else 1;
            args[index] = try slots.read(T, vm, @intCast(index + 1 - receiver_count));
        }
    }
    return args;
}

fn callAndWrite(comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func)), vm: ?*raw.WrenVM) void {
    const Return = functionInfo(func).return_type orelse @compileError("function must have a return type");
    switch (@typeInfo(Return)) {
        .error_union => |info| {
            const result = @call(.auto, func, args) catch |err| {
                if (err != error.BindingAborted) slots.abortMessage(vm, @errorName(err));
                return;
            };
            slots.write(info.payload, vm, 0, result) catch {};
        },
        else => {
            const result: Return = @call(.auto, func, args);
            slots.write(Return, vm, 0, result) catch {};
        },
    }
}

fn wrap(comptime Owner: ?type, comptime func: anytype) raw.WrenForeignMethodFn {
    return struct {
        fn callback(vm: ?*raw.WrenVM) callconv(.c) void {
            const args = decodeArgs(Owner, func, vm) catch return;
            callAndWrite(func, args, vm);
        }
    }.callback;
}

fn allocator(comptime T: type, comptime constructor: anytype) raw.WrenForeignMethodFn {
    return struct {
        fn allocate(vm: ?*raw.WrenVM) callconv(.c) void {
            const args = decodeArgs(null, constructor, vm) catch return;
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
    const count = functionInfo(bound_method.function).params.len;
    return if (bound_method.kind == .static) count else count - 1;
}

const ArgumentStyle = enum { signature, declaration };

fn arguments(comptime arity: usize, comptime style: ArgumentStyle) []const u8 {
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
    const args = comptime arguments(exposedArity(bound_method), .signature);
    return switch (bound_method.kind) {
        .getter => bound_method.wren_name,
        .setter => bound_method.wren_name ++ "=(_)",
        .static, .instance => bound_method.wren_name ++ args,
    };
}

fn methodDeclaration(comptime class: anytype, comptime bound_method: anytype) []const u8 {
    _ = class;
    const args = comptime arguments(exposedArity(bound_method), .declaration);
    return switch (bound_method.kind) {
        .static => "static " ++ bound_method.wren_name ++ args,
        .instance => bound_method.wren_name ++ args,
        .getter => bound_method.wren_name,
        .setter => bound_method.wren_name ++ "=" ++ args,
    };
}

fn generateSource(comptime config: anytype) [:0]const u8 {
    comptime var source: []const u8 = "";
    inline for (config.classes) |class| {
        source = source ++ (if (class.is_foreign) "foreign class " else "class ") ++ class.name ++ " {\n";
        if (class.is_foreign) {
            source = source ++ "  construct " ++ class.constructor.wren_name ++
                arguments(functionInfo(class.constructor.function).params.len, .declaration) ++ " {}\n";
        }
        inline for (class.methods) |bound_method| {
            source = source ++ "  foreign " ++ methodDeclaration(class, bound_method) ++ "\n";
        }
        source = source ++ "}\n\n";
    }
    // wrenInterpret consumes a C string, while the public slice should exclude
    // that terminator. Appending then sentinel-slicing provides both properties.
    return (source ++ "\x00")[0..source.len :0];
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
            validateMethod(class, bound_method);
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
    inline for (info.params) |param| slots.validateReadable(param.type.?);
    validateFinalizer(class.foreign_type, class.finalizer);
}

fn validateFinalizer(comptime T: type, comptime func: anytype) void {
    if (@TypeOf(func) == @TypeOf(null)) return;
    const info = functionInfo(func);
    if (info.params.len != 1 or info.params[0].type.? != *T or info.return_type.? != void)
        @compileError("foreign finalizer must have signature fn (*" ++ @typeName(T) ++ ") void");
}

fn validateMethod(comptime class: anytype, comptime bound_method: anytype) void {
    if (bound_method.wren_name.len == 0) @compileError("Wren method name cannot be empty");
    const info = functionInfo(bound_method.function);
    const receiver_count: usize = if (bound_method.kind == .static) 0 else 1;
    if (receiver_count == 1) {
        if (!class.is_foreign) @compileError("instance methods require a foreign class");
        if (info.params.len == 0) @compileError("instance method requires a receiver");
        const Receiver = info.params[0].type.?;
        if (Receiver != *class.foreign_type and Receiver != *const class.foreign_type)
            @compileError("invalid receiver for " ++ class.name);
    }
    const arity = info.params.len - receiver_count;
    if (bound_method.kind == .getter and arity != 0) @compileError("Wren getter must take no arguments");
    if (bound_method.kind == .setter and arity != 1) @compileError("Wren setter must take one argument");
    inline for (info.params[receiver_count..]) |param| slots.validateReadable(param.type.?);
    slots.validateWritable(payloadType(info.return_type orelse @compileError("function must have a return type")));
}
