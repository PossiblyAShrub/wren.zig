const std = @import("std");
const wren = @import("wren");

test "No side effects" {
    var config: wren.WrenConfiguration = .{};
    wren.wrenInitConfiguration(&config);
    const vm = wren.wrenNewVM(&config);
    defer wren.wrenFreeVM(vm);

    const result = wren.wrenInterpret(vm, "main.wren", "var x = 42");
    try std.testing.expectEqual(wren.WREN_RESULT_SUCCESS, @as(c_int, @intCast(result)));
}

test "Compile error" {
    var config: wren.WrenConfiguration = .{};
    wren.wrenInitConfiguration(&config);
    const vm = wren.wrenNewVM(&config);
    defer wren.wrenFreeVM(vm);

    const result = wren.wrenInterpret(vm, "main.wren", "var x = 42;"); // bad semi!
    try std.testing.expectEqual(wren.WREN_RESULT_COMPILE_ERROR, @as(c_int, @intCast(result)));
}

test "Runtime error" {
    var config: wren.WrenConfiguration = .{};
    wren.wrenInitConfiguration(&config);
    const vm = wren.wrenNewVM(&config);
    defer wren.wrenFreeVM(vm);

    const result = wren.wrenInterpret(vm, "main.wren", "System.unknown()"); // unknown method
    try std.testing.expectEqual(wren.WREN_RESULT_RUNTIME_ERROR, @as(c_int, @intCast(result)));
}
