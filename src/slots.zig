const std = @import("std");
const raw = @import("wren_raw");
const runtime = @import("context.zig");

/// A value stored in a temporary Wren slot. It is valid only while the active
/// foreign callback is running.
pub const Value = struct {
    vm: ?*raw.WrenVM,
    slot: c_int,

    pub fn typeOf(self: Value) raw.WrenType {
        return raw.wrenGetSlotType(self.vm, self.slot);
    }

    pub fn asBool(self: Value) Error!bool {
        return read(bool, self.vm, self.slot);
    }

    pub fn asNum(self: Value) Error!f64 {
        return read(f64, self.vm, self.slot);
    }

    pub fn asString(self: Value) Error!String {
        _ = try readString(self.vm, self.slot);
        return .{ .value = self };
    }

    pub fn asList(self: Value) Error!List {
        try expectType(self.vm, self.slot, raw.WREN_TYPE_LIST, "List");
        return .{ .value = self };
    }

    pub fn asMap(self: Value) Error!Map {
        try expectType(self.vm, self.slot, raw.WREN_TYPE_MAP, "Map");
        return .{ .value = self };
    }

    pub fn asObject(self: Value) Error!Object {
        if (self.typeOf() == raw.WREN_TYPE_NULL or self.typeOf() == raw.WREN_TYPE_NUM or self.typeOf() == raw.WREN_TYPE_BOOL)
            return error.BindingAborted;
        return .{ .value = self };
    }
};

pub const Bool = struct {
    value: Value,
    pub fn get(self: Bool) Error!bool {
        return self.value.asBool();
    }
};
pub const Num = struct {
    value: Value,
    pub fn get(self: Num) Error!f64 {
        return self.value.asNum();
    }
};
pub const Null = struct {
    value: Value,
    pub fn valueRef(self: Null) Value {
        return self.value;
    }
};
pub const String = struct {
    value: Value,

    pub fn bytes(self: String) Error![]const u8 {
        return readString(self.value.vm, self.value.slot);
    }
};
pub const Object = struct {
    value: Value,
    pub fn typeOf(self: Object) raw.WrenType {
        return self.value.typeOf();
    }
};

pub fn Foreign(comptime T: type) type {
    return struct {
        pub const wren_foreign_type = T;
        value: Object,

        pub fn fromObject(item: Object) Error!@This() {
            _ = try getForeign(*T, item.value.vm, item.value.slot);
            return .{ .value = item };
        }

        pub fn object(self: @This()) Object {
            return self.value;
        }

        /// Returns the validated Zig storage behind this foreign object.
        ///
        /// Foreign arguments are checked while decoding the callback, so a
        /// typed foreign value cannot become invalid between decoding and use.
        pub fn get(self: @This()) *T {
            return getForeign(*T, self.value.value.vm, self.value.value.slot) catch unreachable;
        }

    };
}

/// A rooted Wren value that may outlive the callback that created it.
pub const Handle = struct {
    vm: ?*raw.WrenVM,
    handle: *raw.WrenHandle,

    pub fn set(self: Handle, slot: c_int) void {
        raw.wrenSetSlotHandle(self.vm, slot, self.handle);
    }

    pub fn release(self: *Handle) void {
        raw.wrenReleaseHandle(self.vm, self.handle);
        self.* = undefined;
    }
};

/// VM-facing helpers available to context-aware bound functions.
pub const Context = struct {
    pub const wren_context = true;
    const Self = @This();
    vm: ?*raw.WrenVM,

    pub fn allocator(self: Self) std.mem.Allocator {
        return runtime.runtimeData(self.vm).allocator;
    }

    pub fn value(self: Self, slot: c_int) Value {
        return .{ .vm = self.vm, .slot = slot };
    }

    pub fn string(self: Self, bytes: []const u8) String {
        const slot = scratchSlots(self.vm, 1);
        raw.wrenSetSlotBytes(self.vm, slot, bytes.ptr, bytes.len);
        return .{ .value = self.value(slot) };
    }

    pub fn list(self: Self) List {
        const slot = scratchSlots(self.vm, 1);
        raw.wrenSetSlotNewList(self.vm, slot);
        return .{ .value = self.value(slot) };
    }

    pub fn map(self: Self) Map {
        const slot = scratchSlots(self.vm, 1);
        raw.wrenSetSlotNewMap(self.vm, slot);
        return .{ .value = self.value(slot) };
    }

    pub fn retain(self: Self, item: anytype) !Handle {
        const item_value = toValue(item);
        if (item_value.vm != self.vm) return error.WrongVm;
        const handle = raw.wrenGetSlotHandle(self.vm, item_value.slot) orelse return error.OutOfMemory;
        return .{ .vm = self.vm, .handle = handle };
    }
};

/// Internal signal that a codec has already aborted the active Wren fiber.
pub const Error = error{BindingAborted};

fn toValue(value: anytype) Value {
    const T = @TypeOf(value);
    if (T == Value) return value;
    if (T == String or T == List or T == Map or T == Object or T == Num or T == Bool or T == Null) return value.value;
    if (comptime isForeignWrapper(T)) return value.value.value;
    @compileError("value is not a Wren value wrapper: " ++ @typeName(T));
}

fn isForeignWrapper(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "wren_foreign_type"),
        else => false,
    };
}

// Read as big-endian bytes, this is ASCII "WRENZIG" followed by layout
// version 1. It distinguishes storage created by this binder from arbitrary
// foreign storage before we inspect the type tag or value.
const foreign_magic: u64 = 0x5752_454E_5A49_4701;

const ForeignHeader = extern struct {
    magic: u64,
    type_hash: u64,
};

/// Returns the bytes needed for a tagged and correctly aligned foreign `T`.
pub fn foreignAllocationSize(comptime T: type) usize {
    return @sizeOf(ForeignHeader) + @alignOf(T) - 1 + @sizeOf(T);
}

fn foreignTypeHash(comptime T: type) u64 {
    // Wren exposes only an untyped data pointer for foreign objects. Hashing
    // Zig's fully-qualified type name lets us reject a different foreign class
    // before casting its storage to T.
    return std.hash.Wyhash.hash(0, @typeName(T));
}

/// Initializes storage returned by `wrenSetSlotNewForeign` with a typed value.
pub fn initForeign(comptime T: type, raw_storage: *anyopaque, value: T) void {
    const header: *ForeignHeader = @ptrCast(@alignCast(raw_storage));
    header.* = .{ .magic = foreign_magic, .type_hash = foreignTypeHash(T) };
    valuePointer(T, raw_storage).* = value;
}

fn valuePointer(comptime T: type, raw_storage: *anyopaque) *T {
    // ObjForeign exposes a byte array whose address may not satisfy T's
    // alignment. The allocation includes enough padding to align this address.
    const unaligned = @intFromPtr(raw_storage) + @sizeOf(ForeignHeader);
    const aligned = std.mem.alignForward(usize, unaligned, @alignOf(T));
    return @ptrFromInt(aligned);
}

/// Reads a tagged foreign object from `slot` as `*T` or `*const T`.
pub fn getForeign(comptime Pointer: type, vm: ?*raw.WrenVM, slot: c_int) Error!Pointer {
    const pointer = switch (@typeInfo(Pointer)) {
        .pointer => |info| info,
        else => @compileError("foreign values must use *T or *const T"),
    };
    if (pointer.size != .one) @compileError("foreign values must use *T or *const T");

    if (raw.wrenGetSlotType(vm, slot) != raw.WREN_TYPE_FOREIGN) {
        abortExpected(vm, slot, @typeName(Pointer));
        return error.BindingAborted;
    }

    const data = raw.wrenGetSlotForeign(vm, slot) orelse {
        abortMessage(vm, "Foreign object has no data");
        return error.BindingAborted;
    };
    const header: *const ForeignHeader = @ptrCast(@alignCast(data));
    if (header.magic != foreign_magic or header.type_hash != foreignTypeHash(pointer.child)) {
        abortExpected(vm, slot, @typeName(Pointer));
        return error.BindingAborted;
    }
    return valuePointer(pointer.child, data);
}

/// Validates finalizer storage and returns its contained value.
pub fn finalizeForeign(comptime T: type, data: ?*anyopaque) ?*T {
    const pointer = data orelse return null;
    const header: *const ForeignHeader = @ptrCast(@alignCast(pointer));
    if (header.magic != foreign_magic or header.type_hash != foreignTypeHash(T)) return null;
    return valuePointer(T, pointer);
}

/// Returns a borrowed typed view over a Wren list argument.
/// The view and values borrowed from it must not outlive the foreign callback.
pub const List = struct {
    const Self = @This();
    value: Value,

    /// Returns the current number of list elements.
    pub fn len(self: Self) usize {
        return @intCast(raw.wrenGetListCount(self.value.vm, self.value.slot));
    }

    /// Reads and converts the element at `index`.
    pub fn get(self: Self, index: usize) Error!Value {
        if (index >= self.len()) {
            abortMessage(self.value.vm, "List index out of bounds");
            return error.BindingAborted;
        }
        const scratch = scratchSlots(self.value.vm, 1);
        raw.wrenGetListElement(self.value.vm, self.value.slot, @intCast(index), scratch);
        return .{ .vm = self.value.vm, .slot = scratch };
    }

    /// Converts `value` and replaces the element at `index`.
    pub fn set(self: Self, index: usize, item: anytype) Error!void {
        if (index >= self.len()) {
            abortMessage(self.value.vm, "List index out of bounds");
            return error.BindingAborted;
        }
        const scratch = scratchSlots(self.value.vm, 1);
        try writeAny(self.value.vm, scratch, item);
        raw.wrenSetListElement(self.value.vm, self.value.slot, @intCast(index), scratch);
    }

    /// Converts and appends `value` to the list.
    pub fn append(self: Self, item: anytype) Error!void {
        const scratch = scratchSlots(self.value.vm, 1);
        try writeAny(self.value.vm, scratch, item);
        raw.wrenInsertInList(self.value.vm, self.value.slot, -1, scratch);
    }
};

/// Returns a borrowed typed view over a Wren map argument.
/// The view and values borrowed from it must not outlive the foreign callback.
pub const Map = struct {
    const Self = @This();
    value: Value,

    /// Returns the current number of map entries.
    pub fn len(self: Self) usize {
        return @intCast(raw.wrenGetMapCount(self.value.vm, self.value.slot));
    }

    /// Returns whether the converted `key` exists in the map.
    pub fn contains(self: Self, key: anytype) Error!bool {
        const scratch = scratchSlots(self.value.vm, 1);
        try writeAny(self.value.vm, scratch, key);
        return raw.wrenGetMapContainsKey(self.value.vm, self.value.slot, scratch);
    }

    /// Retrieves and converts the value associated with `key`.
    pub fn get(self: Self, key: anytype) Error!Value {
        const scratch = scratchSlots(self.value.vm, 2);
        try writeAny(self.value.vm, scratch, key);
        raw.wrenGetMapValue(self.value.vm, self.value.slot, scratch, scratch + 1);
        return .{ .vm = self.value.vm, .slot = scratch + 1 };
    }

    /// Converts and associates `value` with `key`.
    pub fn put(self: Self, key: anytype, item: anytype) Error!void {
        const scratch = scratchSlots(self.value.vm, 2);
        try writeAny(self.value.vm, scratch, key);
        try writeAny(self.value.vm, scratch + 1, item);
        raw.wrenSetMapValue(self.value.vm, self.value.slot, scratch, scratch + 1);
    }

    /// Removes `key` and converts its previous value.
    pub fn remove(self: Self, key: anytype) Error!Value {
        const scratch = scratchSlots(self.value.vm, 2);
        try writeAny(self.value.vm, scratch, key);
        raw.wrenRemoveMapValue(self.value.vm, self.value.slot, scratch, scratch + 1);
        return .{ .vm = self.value.vm, .slot = scratch + 1 };
    }
};

fn scratchSlots(vm: ?*raw.WrenVM, count: c_int) c_int {
    // Collection operations communicate through slots. Always grow beyond the
    // callback's current slots so arguments and the receiver remain untouched.
    const first = raw.wrenGetSlotCount(vm);
    raw.wrenEnsureSlots(vm, first + count);
    return first;
}

fn slotKind(comptime T: type) ?enum { list, map } {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => if (@hasDecl(T, "wren_slot_kind")) T.wren_slot_kind else null,
        else => null,
    };
}

pub fn validateReadable(comptime T: type) void {
    if (T == f64 or T == bool or T == []const u8 or T == Value or T == String or T == List or T == Map or T == Object or T == Num or T == Bool or T == Null) return;
    switch (@typeInfo(T)) {
        .optional => |info| validateReadable(info.child),
        .pointer => |info| {
            if (info.size != .one) @compileError("foreign values must use wren.Foreign(T)");
        },
        .@"struct" => if (!isForeignWrapper(T)) @compileError("unsupported Wren argument type: " ++ @typeName(T)),
        else => @compileError("unsupported Wren argument type: " ++ @typeName(T)),
    }
}

pub fn validateWritable(comptime T: type) void {
    if (T == void or T == f64 or T == bool or T == []const u8 or T == Value or T == Handle or T == String or T == List or T == Map or T == Object or T == Num or T == Bool or T == Null) return;
    switch (@typeInfo(T)) {
        .optional => |info| validateWritable(info.child),
        .@"struct" => if (!isForeignWrapper(T)) @compileError("unsupported Wren return type: " ++ @typeName(T)),
        else => @compileError("unsupported Wren return type: " ++ @typeName(T)),
    }
}

fn readString(vm: ?*raw.WrenVM, slot: c_int) Error![]const u8 {
    try expectType(vm, slot, raw.WREN_TYPE_STRING, "String");
    var len: c_int = 0;
    const bytes = raw.wrenGetSlotBytes(vm, slot, &len);
    return bytes[0..@intCast(len)];
}

pub fn read(comptime T: type, vm: ?*raw.WrenVM, slot: c_int) Error!T {
    if (T == Value) return .{ .vm = vm, .slot = slot };
    if (T == f64) {
        try expectType(vm, slot, raw.WREN_TYPE_NUM, "Num");
        return raw.wrenGetSlotDouble(vm, slot);
    }
    if (T == bool) {
        try expectType(vm, slot, raw.WREN_TYPE_BOOL, "Bool");
        return raw.wrenGetSlotBool(vm, slot);
    }
    if (T == []const u8) return readString(vm, slot);
    if (T == String) {
        _ = try readString(vm, slot);
        return .{ .value = .{ .vm = vm, .slot = slot } };
    }
    if (T == List) return (try (Value{ .vm = vm, .slot = slot }).asList());
    if (T == Map) return (try (Value{ .vm = vm, .slot = slot }).asMap());
    if (T == Object) return (try (Value{ .vm = vm, .slot = slot }).asObject());
    if (T == Num) {
        try expectType(vm, slot, raw.WREN_TYPE_NUM, "Num");
        return .{ .value = .{ .vm = vm, .slot = slot } };
    }
    if (T == Bool) {
        try expectType(vm, slot, raw.WREN_TYPE_BOOL, "Bool");
        return .{ .value = .{ .vm = vm, .slot = slot } };
    }
    if (T == Null) {
        try expectType(vm, slot, raw.WREN_TYPE_NULL, "Null");
        return .{ .value = .{ .vm = vm, .slot = slot } };
    }
    switch (@typeInfo(T)) {
        .optional => |info| {
            if (raw.wrenGetSlotType(vm, slot) == raw.WREN_TYPE_NULL) return null;
            return try read(info.child, vm, slot);
        },
        .pointer => return getForeign(T, vm, slot),
        .@"struct" => if (comptime isForeignWrapper(T)) {
            const object = try (Value{ .vm = vm, .slot = slot }).asObject();
            _ = try getForeign(*T.wren_foreign_type, vm, slot);
            return .{ .value = object };
        },
        else => unreachable,
    }
}

fn writeAny(vm: ?*raw.WrenVM, slot: c_int, value: anytype) Error!void {
    const T = @TypeOf(value);
    if (T == comptime_int) return write(f64, vm, slot, @floatFromInt(value));
    if (T == comptime_float) return write(f64, vm, slot, value);
    if (T == []const u8) return write(T, vm, slot, value);
    if (T == @TypeOf(null)) {
        raw.wrenSetSlotNull(vm, slot);
        return;
    }
    if (@typeInfo(T) == .pointer) {
        const info = @typeInfo(T).pointer;
        if (info.size == .one and @typeInfo(info.child) == .array and @typeInfo(info.child).array.child == u8)
            return write([]const u8, vm, slot, value);
    }
    if (T == f64 or T == bool or T == Value or T == String or T == List or T == Map or T == Object or T == Num or T == Bool or T == Null) return write(T, vm, slot, value);
    if (@typeInfo(T) == .optional) {
        if (value) |item| return writeAny(vm, slot, item);
        raw.wrenSetSlotNull(vm, slot);
        return;
    }
    if (comptime isForeignWrapper(T)) return write(T, vm, slot, value);
    @compileError("unsupported Wren value: " ++ @typeName(T));
}

pub fn write(comptime T: type, vm: ?*raw.WrenVM, slot: c_int, value: T) Error!void {
    if (T == Value) {
        if (value.vm != vm) {
            abortMessage(vm, "Cannot return a value from another Wren VM");
            return error.BindingAborted;
        }
        const handle = raw.wrenGetSlotHandle(vm, value.slot) orelse {
            abortMessage(vm, "Failed to retain Wren value");
            return error.BindingAborted;
        };
        raw.wrenSetSlotHandle(vm, slot, handle);
        raw.wrenReleaseHandle(vm, handle);
        return;
    }
    if (T == Handle) {
        if (value.vm != vm) {
            abortMessage(vm, "Cannot return a handle from another Wren VM");
            return error.BindingAborted;
        }
        raw.wrenSetSlotHandle(vm, slot, value.handle);
        var owned = value;
        owned.release();
        return;
    }
    if (T == void) {
        raw.wrenSetSlotNull(vm, slot);
        return;
    }
    if (T == f64) {
        raw.wrenSetSlotDouble(vm, slot, value);
        return;
    }
    if (T == bool) {
        raw.wrenSetSlotBool(vm, slot, value);
        return;
    }
    if (T == []const u8) {
        raw.wrenSetSlotBytes(vm, slot, value.ptr, value.len);
        return;
    }
    if (T == String or T == List or T == Map or T == Object or T == Num or T == Bool or T == Null) return write(Value, vm, slot, toValue(value));

    switch (@typeInfo(T)) {
        .optional => |info| {
            if (value) |item| return write(info.child, vm, slot, item);
            raw.wrenSetSlotNull(vm, slot);
            return;
        },
        else => if (comptime isForeignWrapper(T)) return write(Value, vm, slot, toValue(value)),
    }
    unreachable;
}

fn expectType(vm: ?*raw.WrenVM, slot: c_int, expected: raw.WrenType, name: []const u8) Error!void {
    if (raw.wrenGetSlotType(vm, slot) == expected) return;
    abortExpected(vm, slot, name);
    return error.BindingAborted;
}

fn abortExpected(vm: ?*raw.WrenVM, slot: c_int, name: []const u8) void {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "Argument {d}: expected {s}", .{ slot, name }) catch "Invalid argument";
    abortMessage(vm, message);
}

/// Aborts the active Wren fiber with a byte string message.
pub fn abortMessage(vm: ?*raw.WrenVM, message: []const u8) void {
    raw.wrenSetSlotBytes(vm, 0, message.ptr, message.len);
    raw.wrenAbortFiber(vm, 0);
}
