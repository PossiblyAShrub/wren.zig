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

const MethodKind = enum {
    static,
    instance,
    getter,
    setter,
};

pub fn Static(
    comptime name: []const u8,
    comptime func: anytype,
) type {
    return struct {
        pub const kind: MethodKind = .static;
        pub const wren_name = name;
        pub const function = func;
    };
}

pub fn Method(
    comptime name: []const u8,
    comptime func: anytype,
) type {
    return struct {
        pub const kind: MethodKind = .instance;
        pub const wren_name = name;
        pub const function = func;
    };
}

pub fn Getter(
    comptime name: []const u8,
    comptime func: anytype,
) type {
    return struct {
        pub const kind: MethodKind = .getter;
        pub const wren_name = name;
        pub const function = func;
    };
}

pub fn Setter(
    comptime name: []const u8,
    comptime func: anytype,
) type {
    return struct {
        pub const kind: MethodKind = .setter;
        pub const wren_name = name;
        pub const function = func;
    };
}

pub fn Constructor(
    comptime name: []const u8,
    comptime func: anytype,
) type {
    return struct {
        pub const wren_name = name;
        pub const function = func;
    };
}

pub fn Class(comptime options: anytype) type {
    return struct {
        pub const is_foreign = false;
        pub const name = options.name;
        pub const methods = options.methods;
    };
}

pub fn ForeignClass(
    comptime T: type,
    comptime options: anytype,
) type {
    return struct {
        pub const is_foreign = true;
        pub const foreign_type = T;
        pub const name = options.name;
        pub const constructor = options.constructor;
        pub const methods = options.methods;
        pub const finalizer = options.finalizer;
    };
}

pub fn wrenApi(comptime config: anytype) type {
    comptime validateApi(config);

    return struct {
        pub const module = config.module;
        pub const source: [:0]const u8 = generateSource(config);

        pub fn bindForeignMethod(
            vm: ?*wren_raw.WrenVM,
            module_ptr: [*c]const u8,
            class_ptr: [*c]const u8,
            is_static: bool,
            signature_ptr: [*c]const u8,
        ) callconv(.c) wren_raw.WrenForeignMethodFn {
            _ = vm;

            if (module_ptr == null or
                class_ptr == null or
                signature_ptr == null)
            {
                return null;
            }

            const requested_module = std.mem.span(module_ptr);
            const requested_class = std.mem.span(class_ptr);
            const requested_signature = std.mem.span(signature_ptr);

            if (!std.mem.eql(
                u8,
                requested_module,
                config.module,
            )) {
                return null;
            }

            inline for (config.classes) |ClassSpec| {
                if (std.mem.eql(
                    u8,
                    requested_class,
                    ClassSpec.name,
                )) {
                    inline for (ClassSpec.methods) |MethodSpec| {
                        const method_is_static =
                            MethodSpec.kind == .static;

                        if (method_is_static == is_static) {
                            const signature = methodSignature(
                                ClassSpec,
                                MethodSpec,
                            );

                            if (std.mem.eql(
                                    u8,
                                    requested_signature,
                                    signature,
                            )) {
                                if (MethodSpec.kind == .static) {
                                    return wrenWrap(MethodSpec.function);
                                }

                                if (!ClassSpec.is_foreign) {
                                    @compileError(
                                        "instance methods require a foreign class",
                                    );
                                }

                                return wrenWrapInstance(
                                    ClassSpec.foreign_type,
                                    MethodSpec.function,
                                );
                            }
                        }
                    }
                }
            }

            return null;
        }

        pub fn bindForeignClass(
            vm: ?*wren_raw.WrenVM,
            module_ptr: [*c]const u8,
            class_ptr: [*c]const u8,
        ) callconv(.c) wren_raw.WrenForeignClassMethods {
            _ = vm;

            const no_methods: wren_raw.WrenForeignClassMethods = .{
                .allocate = null,
                .finalize = null,
            };

            if (module_ptr == null or class_ptr == null) {
                return no_methods;
            }

            const requested_module = std.mem.span(module_ptr);
            const requested_class = std.mem.span(class_ptr);

            if (!std.mem.eql(
                u8,
                requested_module,
                config.module,
            )) {
                return no_methods;
            }

            inline for (config.classes) |ClassSpec| {
                if (!ClassSpec.is_foreign) {
                    continue;
                }

                if (std.mem.eql(
                    u8,
                    requested_class,
                    ClassSpec.name,
                )) {
                    return .{
                        .allocate = foreignAllocator(
                            ClassSpec.foreign_type,
                            ClassSpec.constructor.function,
                        ),
                        .finalize = foreignFinalizer(
                            ClassSpec.foreign_type,
                            ClassSpec.finalizer,
                        ),
                    };
                }
            }

            return no_methods;
        }
    };
}

fn methodSignature(
    comptime ClassSpec: type,
    comptime MethodSpec: type,
) []const u8 {
    const arity = comptime exposedArity(ClassSpec, MethodSpec);

    return switch (MethodSpec.kind) {
        .getter => MethodSpec.wren_name,

        .setter => MethodSpec.wren_name ++ "=(_)",

        .static, .instance => callableSignature(
            MethodSpec.wren_name,
            arity,
        ),
    };
}

fn callableSignature(
    comptime name: []const u8,
    comptime arity: usize,
) []const u8 {
    comptime var result: []const u8 = name ++ "(";

    inline for (0..arity) |index| {
        if (index != 0) {
            result = result ++ ",";
        }

        result = result ++ "_";
    }

    return result ++ ")";
}

fn exposedArity(
    comptime ClassSpec: type,
    comptime MethodSpec: type,
) usize {
    const info = functionInfo(MethodSpec.function);

    return switch (MethodSpec.kind) {
        .static => info.params.len,

        .instance, .getter, .setter => blk: {
            if (!ClassSpec.is_foreign) {
                @compileError(
                    "instance methods require a foreign class",
                );
            }

            if (info.params.len == 0) {
                @compileError(
                    "instance method requires a receiver",
                );
            }

            validateReceiver(
                ClassSpec.foreign_type,
                info.params[0].type.?,
            );

            break :blk info.params.len - 1;
        },
    };
}

fn functionInfo(comptime func: anytype) std.builtin.Type.Fn {
    return switch (@typeInfo(@TypeOf(func))) {
        .@"fn" => |info| info,
        else => @compileError("expected a function"),
    };
}

fn generateSource(comptime config: anytype) [:0]const u8 {
    comptime var source: []const u8 = "";

    inline for (config.classes) |ClassSpec| {
        if (ClassSpec.is_foreign) {
            source = source ++ "foreign class ";
        } else {
            source = source ++ "class ";
        }

        source = source ++ ClassSpec.name ++ " {\n";

        if (ClassSpec.is_foreign) {
            source = source ++
                "  construct " ++
                ClassSpec.constructor.wren_name ++
                argumentDeclaration(
                    constructorArity(ClassSpec),
                ) ++
                " {}\n";
        }

        inline for (ClassSpec.methods) |MethodSpec| {
            source = source ++
                "  foreign " ++
                methodDeclaration(
                    ClassSpec,
                    MethodSpec,
                ) ++
                "\n";
        }

        source = source ++ "}\n\n";
    }

    return (source ++ "\x00")[0..source.len :0];
}

fn methodDeclaration(
    comptime ClassSpec: type,
    comptime MethodSpec: type,
) []const u8 {
    const args = argumentDeclaration(
        exposedArity(ClassSpec, MethodSpec),
    );

    return switch (MethodSpec.kind) {
        .static =>
            "static " ++ MethodSpec.wren_name ++ args,

        .instance =>
            MethodSpec.wren_name ++ args,

        .getter =>
            MethodSpec.wren_name,

        .setter =>
            MethodSpec.wren_name ++ "=" ++ args,
    };
}

fn argumentDeclaration(
    comptime arity: usize,
) []const u8 {
    comptime var result: []const u8 = "(";

    inline for (0..arity) |index| {
        if (index != 0) {
            result = result ++ ", ";
        }

        result = result ++ std.fmt.comptimePrint(
            "arg{d}",
            .{index},
        );
    }

    return result ++ ")";
}

fn constructorArity(comptime ClassSpec: type) usize {
    return functionInfo(
        ClassSpec.constructor.function,
    ).params.len;
}

const foreign_magic: u64 = 0x5752_454E_5A49_4701;

const ForeignHeader = extern struct {
    magic: u64,
    type_id: *const anyopaque,
};

fn ForeignStorage(comptime T: type) type {
    return struct {
        header: ForeignHeader,
        value: T,
    };
}

fn foreignTypeId(comptime T: type) *const anyopaque {
    _ = T;
    const Token = struct {
        var value: u8 = 0;
    };

    return @ptrCast(&Token.value);
}

fn foreignAllocator(
    comptime T: type,
    comptime constructor: anytype,
) wren_raw.WrenForeignMethodFn {
    const ConstructorFn = @TypeOf(constructor);
    const info = functionInfo(constructor);
    const Args = std.meta.ArgsTuple(ConstructorFn);
    const Return = info.return_type orelse
        @compileError("constructor must return a value");

    comptime {
        if (Return != T) {
            @compileError(
                "foreign constructor must return " ++
                    @typeName(T) ++
                    ", found " ++
                    @typeName(Return),
            );
        }
    }

    return struct {
        fn allocate(
            vm: ?*wren_raw.WrenVM,
        ) callconv(.c) void {
            var args: Args = undefined;

            inline for (info.params, 0..) |param, index| {
                const Arg = param.type.?;
                const slot: c_int = @intCast(index + 1);

                args[index] = Slots.read(
                    Arg,
                    vm,
                    slot,
                ) catch return;
            }

            const raw = wren_raw.wrenSetSlotNewForeign(
                vm,
                0,
                0,
                @sizeOf(ForeignStorage(T)),
            );

            if (raw == null) {
                Slots.abortMessage(
                    vm,
                    "Failed to allocate foreign object",
                );
                return;
            }

            const storage: *ForeignStorage(T) =
                @ptrCast(@alignCast(raw));

            storage.* = .{
                .header = .{
                    .magic = foreign_magic,
                    .type_id = foreignTypeId(T),
                },
                .value = @call(.auto, constructor, args),
            };
        }
    }.allocate;
}

fn foreignFinalizer(
    comptime T: type,
    comptime finalizer: anytype,
) wren_raw.WrenFinalizerFn {
    if (@TypeOf(finalizer) == @TypeOf(null)) {
        return null;
    }

    const info = functionInfo(finalizer);

    comptime {
        if (info.params.len != 1 or
            info.params[0].type.? != *T or
            info.return_type.? != void)
        {
            @compileError(
                "foreign finalizer must have signature fn (*" ++
                    @typeName(T) ++ ") void",
            );
        }
    }

    return struct {
        fn finalize(raw: ?*anyopaque) callconv(.c) void {
            const pointer = raw orelse return;

            const storage: *ForeignStorage(T) =
                @ptrCast(@alignCast(pointer));

            if (storage.header.magic != foreign_magic or
                storage.header.type_id != foreignTypeId(T))
            {
                return;
            }

            @call(.auto, finalizer, .{
                &storage.value,
            });
        }
    }.finalize;
}

fn wrenWrapInstance(
    comptime Owner: type,
    comptime func: anytype,
) wren_raw.WrenForeignMethodFn {
    const Func = @TypeOf(func);
    const info = functionInfo(func);
    const Args = std.meta.ArgsTuple(Func);
    const Return = info.return_type orelse
        @compileError("function has no return type");

    comptime {
        if (info.params.len == 0) {
            @compileError(
                "instance method requires a receiver",
            );
        }

        validateReceiver(
            Owner,
            info.params[0].type.?,
        );
    }

    return struct {
        fn wrapper(
            vm: ?*wren_raw.WrenVM,
        ) callconv(.c) void {
            var args: Args = undefined;

            const Receiver = info.params[0].type.?;

            args[0] = Slots.readForeignPointer(
                Receiver,
                vm,
                0,
            ) catch return;

            inline for (info.params[1..], 1..) |param, index| {
                const T = param.type.?;
                const slot: c_int = @intCast(index);

                args[index] = Slots.read(
                    T,
                    vm,
                    slot,
                ) catch return;
            }

            if (Return == void) {
                @call(.auto, func, args);
                wren_raw.wrenSetSlotNull(vm, 0);
            } else {
                const result: Return =
                    @call(.auto, func, args);

                Slots.write(Return, vm, 0, result);
            }
        }
    }.wrapper;
}

fn validateReceiver(
    comptime Owner: type,
    comptime Receiver: type,
) void {
    if (Receiver != *Owner and Receiver != *const Owner) {
        @compileError(
            "expected receiver *" ++ @typeName(Owner) ++
                " or *const " ++ @typeName(Owner) ++
                ", found " ++ @typeName(Receiver),
        );
    }
}

fn validateApi(comptime config: anytype) void {
    if (config.module.len == 0) {
        @compileError("Wren module name cannot be empty");
    }

    inline for (config.classes, 0..) |ClassSpec, class_index| {
        if (ClassSpec.name.len == 0) {
            @compileError("Wren class name cannot be empty");
        }

        // Tuples cannot be sliced. Compare only later elements.
        inline for (config.classes, 0..) |OtherClass, other_class_index| {
            if (other_class_index <= class_index) {
                continue;
            }

            if (std.mem.eql(
                u8,
                ClassSpec.name,
                OtherClass.name,
            )) {
                @compileError(
                    "duplicate Wren class: " ++ ClassSpec.name,
                );
            }
        }

        if (ClassSpec.is_foreign) {
            validateConstructor(ClassSpec);
        }

        inline for (
            ClassSpec.methods,
            0..,
        ) |MethodSpec, method_index| {
            validateMethod(ClassSpec, MethodSpec);

            const signature = methodSignature(
                ClassSpec,
                MethodSpec,
            );

            // ClassSpec.methods is also a heterogeneous tuple.
            inline for (
                ClassSpec.methods,
                0..,
            ) |OtherMethod, other_method_index| {
                if (other_method_index <= method_index) {
                    continue;
                }

                const both_static =
                    (MethodSpec.kind == .static) ==
                    (OtherMethod.kind == .static);

                if (both_static and std.mem.eql(
                    u8,
                    signature,
                    methodSignature(
                        ClassSpec,
                        OtherMethod,
                    ),
                )) {
                    @compileError(
                        "duplicate Wren method in class " ++
                            ClassSpec.name ++
                            ": " ++
                            signature,
                    );
                }
            }
        }
    }
}

fn validateConstructor(comptime ClassSpec: type) void {
    const info = functionInfo(
        ClassSpec.constructor.function,
    );

    const Return = info.return_type orelse
        @compileError(
            "foreign constructor must return a value",
        );

    if (Return != ClassSpec.foreign_type) {
        @compileError(
            "constructor for " ++ ClassSpec.name ++
                " must return " ++
                @typeName(ClassSpec.foreign_type),
        );
    }

    inline for (info.params) |param| {
        validateValueType(param.type.?);
    }
}

fn validateMethod(
    comptime ClassSpec: type,
    comptime MethodSpec: type,
) void {
    const info = functionInfo(MethodSpec.function);

    if (MethodSpec.wren_name.len == 0) {
        @compileError("Wren method name cannot be empty");
    }

    switch (MethodSpec.kind) {
        .static => {},

        .instance => {
            if (info.params.len == 0) {
                @compileError(
                    "instance method requires a receiver",
                );
            }
        },

        .getter => {
            if (exposedArity(ClassSpec, MethodSpec) != 0) {
                @compileError(
                    "Wren getter must take no arguments",
                );
            }
        },

        .setter => {
            if (exposedArity(ClassSpec, MethodSpec) != 1) {
                @compileError(
                    "Wren setter must take one argument",
                );
            }
        },
    }
}

fn validateValueType(comptime T: type) void {
    if (T == f64 or T == bool) {
        return;
    }

    @compileError(
        "unsupported Wren value type: " ++ @typeName(T),
    );
}

pub const ErrorType = enum {
    Compile,
    Runtime,
    StackTrace,
};

pub fn wrenWrap(
    comptime func: anytype,
) wren_raw.WrenForeignMethodFn {
    const Func = @TypeOf(func);
    const info = functionInfo(func);

    inline for (info.params) |param| {
        if (param.type == null) {
            @compileError(
                "wrenWrap does not support generic " ++
                    "or anytype parameters",
            );
        }
    }

    const Args = std.meta.ArgsTuple(Func);
    const Return = info.return_type orelse
        @compileError("function has no return type");

    return struct {
        fn wrapper(
            vm: ?*wren_raw.WrenVM,
        ) callconv(.c) void {
            var args: Args = undefined;

            inline for (info.params, 0..) |param, index| {
                const T = param.type.?;
                const slot: c_int = @intCast(index + 1);

                args[index] = Slots.read(
                    T,
                    vm,
                    slot,
                ) catch return;
            }

            if (Return == void) {
                @call(.auto, func, args);
                wren_raw.wrenSetSlotNull(vm, 0);
            } else {
                const result: Return =
                    @call(.auto, func, args);

                Slots.write(Return, vm, 0, result);
            }
        }
    }.wrapper;
}

fn wrenTypeName(comptime T: type) []const u8 {
    if (T == f64) return "Num";
    if (T == bool) return "Bool";

    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size == .one) {
                return @typeName(pointer.child);
            }
        },
        else => {},
    }

    @compileError(
        "unsupported Wren type: " ++ @typeName(T),
    );
}

const Slots = struct {
    const SlotError = error{
        WrongWrenType,
        WrongForeignType,
        NullForeignData,
    };

    fn read(
        comptime T: type,
        vm: ?*wren_raw.WrenVM,
        slot: c_int,
    ) SlotError!T {
        if (T == f64) {
            if (wren_raw.wrenGetSlotType(vm, slot) !=
                wren_raw.WREN_TYPE_NUM)
            {
                abort(T, vm, slot);
                return error.WrongWrenType;
            }

            return wren_raw.wrenGetSlotDouble(vm, slot);
        }

        if (T == bool) {
            if (wren_raw.wrenGetSlotType(vm, slot) !=
                wren_raw.WREN_TYPE_BOOL)
            {
                abort(T, vm, slot);
                return error.WrongWrenType;
            }

            return wren_raw.wrenGetSlotBool(vm, slot);
        }

        switch (@typeInfo(T)) {
            .pointer => {
                return readForeignPointer(T, vm, slot);
            },
            else => {},
        }

        @compileError(
            "unsupported Wren argument type: " ++
                @typeName(T),
        );
    }

    fn readForeignPointer(
        comptime Pointer: type,
        vm: ?*wren_raw.WrenVM,
        slot: c_int,
    ) SlotError!Pointer {
        const pointer_info = switch (@typeInfo(Pointer)) {
            .pointer => |info| info,
            else => @compileError("expected a foreign object pointer"),
        };

        if (pointer_info.size != .one) {
            @compileError(
                "foreign arguments must use *T or *const T",
            );
        }

        const T = pointer_info.child;

        if (wren_raw.wrenGetSlotType(vm, slot) !=
            wren_raw.WREN_TYPE_FOREIGN)
        {
            abort(Pointer, vm, slot);
            return error.WrongWrenType;
        }

        const raw = wren_raw.wrenGetSlotForeign(vm, slot) orelse {
            abort(Pointer, vm, slot);
            return error.NullForeignData;
        };

        const Storage = ForeignStorage(T);
        const storage: *Storage =
            @ptrCast(@alignCast(raw));

        if (storage.header.magic != foreign_magic or
            storage.header.type_id != foreignTypeId(T))
        {
            abort(Pointer, vm, slot);
            return error.WrongForeignType;
        }

        return &storage.value;
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
            "unsupported Wren return type: " ++
                @typeName(T),
        );
    }

    fn abort(
        comptime T: type,
        vm: ?*wren_raw.WrenVM,
        slot: c_int,
    ) void {
        var message_buffer: [256]u8 = undefined;

        const message = std.fmt.bufPrintZ(
            &message_buffer,
            "Argument {d}: expected {s}",
            .{ slot, wrenTypeName(T) },
        ) catch {
            abortMessage(vm, "Invalid argument");
            return;
        };

        wren_raw.wrenSetSlotString(
            vm,
            0,
            message.ptr,
        );
        wren_raw.wrenAbortFiber(vm, 0);
    }

    fn abortMessage(
        vm: ?*wren_raw.WrenVM,
        message: [*:0]const u8,
    ) void {
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
        bindForeignMethodFn: wren_raw.WrenBindForeignMethodFn = null,
        bindForeignClassFn: wren_raw.WrenBindForeignClassFn = null,
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
        data.raw_config.bindForeignMethodFn = config.bindForeignMethodFn;
        data.raw_config.bindForeignClassFn = config.bindForeignClassFn;

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
