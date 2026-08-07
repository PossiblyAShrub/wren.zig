const raw = @import("wren_raw");
const std = @import("std");

/// The prefix of the VM-owned callback data. This is shared by root.zig and
/// bindings.zig so generated callbacks can recover application state without
/// depending on the concrete Vm type.
pub const RuntimeData = struct {
    allocator: std.mem.Allocator,
    user_data: ?*anyopaque = null,
};

pub fn runtimeData(vm: ?*raw.WrenVM) *RuntimeData {
    return @ptrCast(@alignCast(raw.wrenGetUserData(vm)));
}
