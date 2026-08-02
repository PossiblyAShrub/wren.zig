const std = @import("std");
const wren = @import("wren");

test "No side effects" {
    const gpa = std.testing.allocator;
    var vm = try wren.Vm.init(gpa, .{});
    defer vm.deinit(gpa);

    try vm.interpret("main.wren", "var x = 42");
}

test "Compile error" {
    const gpa = std.testing.allocator;
    var vm = try wren.Vm.init(gpa, .{});
    defer vm.deinit(gpa);

    const err = vm.interpret("main.wren", "var x = 42;");
    try std.testing.expectError(error.CompileError, err);
}

test "Runtime error" {
    const gpa = std.testing.allocator;
    var vm = try wren.Vm.init(gpa, .{});
    defer vm.deinit(gpa);


    const err = vm.interpret("main.wren", "System.unknown()");
    try std.testing.expectError(error.RuntimeError, err);
}
