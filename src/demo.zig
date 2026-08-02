const std = @import("std");
const wren = @import("wren");

fn wrenWriteFn(vm: ?*wren.WrenVM, text: [*c]const u8) callconv(.c) void {
    _ = vm;
    std.debug.print("{s}", .{text});
}

fn wrenErrorFn(vm: ?*wren.WrenVM, @"type": wren.WrenErrorType, module: [*c]const u8, line: c_int, message: [*c]const u8) callconv(.c) void {
    _ = vm;
    var errorType: []const u8 = "COMPILE ERROR";
    switch (@"type") {
        wren.WREN_ERROR_COMPILE => {},
        wren.WREN_ERROR_RUNTIME => { errorType = "RUNTIME ERROR"; },
        wren.WREN_ERROR_STACK_TRACE => { errorType = "STACK TRACE"; },
        else => unreachable,
    }
    if (module != null) {
        std.debug.print("{s}:{} [{s}] {s}\n", .{module, line, errorType, message});
    } else {
        std.debug.print("[{s}] {s}\n", .{errorType, message});
    }
}

pub fn main() void {
    var config: wren.WrenConfiguration = .{};
    wren.wrenInitConfiguration(&config);
    config.writeFn = wrenWriteFn;
    config.errorFn = wrenErrorFn;

    const vm = wren.wrenNewVM(&config);
    defer wren.wrenFreeVM(vm);

    const result = wren.wrenInterpret(vm, "main.wren", "System.print(\"Hello, wren!\")");
    switch (result) {
        wren.WREN_RESULT_SUCCESS => { std.debug.print("Success!\n", .{}); },
        wren.WREN_RESULT_COMPILE_ERROR => { std.debug.print("Compile Error!\n", .{}); },
        wren.WREN_RESULT_RUNTIME_ERROR => { std.debug.print("Runtime Error!\n", .{}); },
        else => unreachable,
    }
}
