const std = @import("std");
const raw = @import("wren_raw");

/// Internal signal that a codec has already aborted the active Wren fiber.
pub const Error = error{BindingAborted};

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
pub fn List(comptime T: type) type {
    return struct {
        pub const wren_slot_kind = .list;
        const Self = @This();

        vm: ?*raw.WrenVM,
        slot: c_int,

        /// Returns the current number of list elements.
        pub fn len(self: Self) usize {
            return @intCast(raw.wrenGetListCount(self.vm, self.slot));
        }

        /// Reads and converts the element at `index`.
        pub fn get(self: Self, index: usize) Error!T {
            if (index >= self.len()) {
                abortMessage(self.vm, "List index out of bounds");
                return error.BindingAborted;
            }
            const scratch = scratchSlots(self.vm, 1);
            raw.wrenGetListElement(self.vm, self.slot, @intCast(index), scratch);
            return read(T, self.vm, scratch);
        }

        /// Converts `value` and replaces the element at `index`.
        pub fn set(self: Self, index: usize, value: T) Error!void {
            if (index >= self.len()) {
                abortMessage(self.vm, "List index out of bounds");
                return error.BindingAborted;
            }
            const scratch = scratchSlots(self.vm, 1);
            try write(T, self.vm, scratch, value);
            raw.wrenSetListElement(self.vm, self.slot, @intCast(index), scratch);
        }

        /// Converts and appends `value` to the list.
        pub fn append(self: Self, value: T) Error!void {
            const scratch = scratchSlots(self.vm, 1);
            try write(T, self.vm, scratch, value);
            raw.wrenInsertInList(self.vm, self.slot, -1, scratch);
        }
    };
}

/// Returns a borrowed typed view over a Wren map argument.
/// The view and values borrowed from it must not outlive the foreign callback.
pub fn Map(comptime K: type, comptime V: type) type {
    return struct {
        pub const wren_slot_kind = .map;
        const Self = @This();

        vm: ?*raw.WrenVM,
        slot: c_int,

        /// Returns the current number of map entries.
        pub fn len(self: Self) usize {
            return @intCast(raw.wrenGetMapCount(self.vm, self.slot));
        }

        /// Returns whether the converted `key` exists in the map.
        pub fn contains(self: Self, key: K) Error!bool {
            const scratch = scratchSlots(self.vm, 1);
            try write(K, self.vm, scratch, key);
            return raw.wrenGetMapContainsKey(self.vm, self.slot, scratch);
        }

        /// Retrieves and converts the value associated with `key`.
        /// A missing key follows Wren semantics and reads as `null`, so use an
        /// optional `V` when absence is expected.
        pub fn get(self: Self, key: K) Error!V {
            const scratch = scratchSlots(self.vm, 2);
            try write(K, self.vm, scratch, key);
            raw.wrenGetMapValue(self.vm, self.slot, scratch, scratch + 1);
            return read(V, self.vm, scratch + 1);
        }

        /// Converts and associates `value` with `key`.
        pub fn put(self: Self, key: K, value: V) Error!void {
            const scratch = scratchSlots(self.vm, 2);
            try write(K, self.vm, scratch, key);
            try write(V, self.vm, scratch + 1, value);
            raw.wrenSetMapValue(self.vm, self.slot, scratch, scratch + 1);
        }

        /// Removes `key` and converts its previous value.
        pub fn remove(self: Self, key: K) Error!V {
            const scratch = scratchSlots(self.vm, 2);
            try write(K, self.vm, scratch, key);
            raw.wrenRemoveMapValue(self.vm, self.slot, scratch, scratch + 1);
            return read(V, self.vm, scratch + 1);
        }
    };
}

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

/// Checks that `T` can be decoded from a Wren slot.
pub fn validateReadable(comptime T: type) void {
    if (T == f64 or T == bool or T == []const u8) return;
    switch (@typeInfo(T)) {
        .optional => |info| validateReadable(info.child),
        .pointer => |info| if (info.size != .one) @compileError("foreign values must use *T or *const T"),
        else => if (slotKind(T) == null) @compileError("unsupported Wren argument type: " ++ @typeName(T)),
    }
}

/// Checks that `T` can be encoded into a Wren slot.
pub fn validateWritable(comptime T: type) void {
    if (T == void or T == f64 or T == bool or T == []const u8) return;
    switch (@typeInfo(T)) {
        .optional => |info| validateWritable(info.child),
        else => if (slotKind(T) == null) @compileError("unsupported Wren return type: " ++ @typeName(T)),
    }
}

/// Decodes slot `slot` into the requested Zig type or aborts the Wren fiber.
pub fn read(comptime T: type, vm: ?*raw.WrenVM, slot: c_int) Error!T {
    if (T == f64) {
        try expectType(vm, slot, raw.WREN_TYPE_NUM, "Num");
        return raw.wrenGetSlotDouble(vm, slot);
    }
    if (T == bool) {
        try expectType(vm, slot, raw.WREN_TYPE_BOOL, "Bool");
        return raw.wrenGetSlotBool(vm, slot);
    }
    if (T == []const u8) {
        try expectType(vm, slot, raw.WREN_TYPE_STRING, "String");
        var len: c_int = 0;
        const bytes = raw.wrenGetSlotBytes(vm, slot, &len);
        // Wren owns this memory; it remains borrowed for this callback only.
        return bytes[0..@intCast(len)];
    }

    switch (@typeInfo(T)) {
        .optional => |info| {
            if (raw.wrenGetSlotType(vm, slot) == raw.WREN_TYPE_NULL) return null;
            return try read(info.child, vm, slot);
        },
        .pointer => return getForeign(T, vm, slot),
        else => if (slotKind(T)) |kind| {
            switch (kind) {
                .list => try expectType(vm, slot, raw.WREN_TYPE_LIST, "List"),
                .map => try expectType(vm, slot, raw.WREN_TYPE_MAP, "Map"),
            }
            return .{ .vm = vm, .slot = slot };
        },
    }
    unreachable;
}

/// Encodes a supported Zig value into a Wren slot.
pub fn write(comptime T: type, vm: ?*raw.WrenVM, slot: c_int, value: T) Error!void {
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

    switch (@typeInfo(T)) {
        .optional => |info| {
            if (value) |item| return write(info.child, vm, slot, item);
            raw.wrenSetSlotNull(vm, slot);
            return;
        },
        else => if (slotKind(T) != null) {
            if (value.vm != vm) {
                abortMessage(vm, "Cannot return a view from another Wren VM");
                return error.BindingAborted;
            }
            const handle = raw.wrenGetSlotHandle(vm, value.slot);
            raw.wrenSetSlotHandle(vm, slot, handle);
            raw.wrenReleaseHandle(vm, handle);
            return;
        },
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
