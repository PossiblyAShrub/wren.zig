const std = @import("std");
const wren = @import("wren");

fn wrenWriteFn(text: []const u8) void {
    std.debug.print("{s}", .{text});
}

fn wrenErrorFn(errorType: wren.ErrorType, module: ?[]const u8, line: i32, message: []const u8) void {
    var errorTypeStr: []const u8 = "COMPILE ERROR";
    switch (errorType) {
        .Compile => {},
        .Runtime => { errorTypeStr = "RUNTIME ERROR"; },
        .StackTrace => { errorTypeStr = "STACK TRACE"; },
    }

    if (module != null) {
        std.debug.print("{s}:{} [{s}] {s}\n", .{module.?, line, errorTypeStr, message});
    } else {
        std.debug.print("[{s}] {s}\n", .{errorTypeStr, message});
    }
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var vm = try wren.Vm.init(gpa, .{
        .writeFn = wrenWriteFn,
        .errorFn = wrenErrorFn,
    });
    defer vm.deinit(gpa);

    try vm.interpret("main.wren",
        \\class Test {
        \\  foreign static add1(x)
        \\}
        \\
        \\System.print(Test.add1(41))
        );
}
