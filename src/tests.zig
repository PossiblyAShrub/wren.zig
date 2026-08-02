const std = @import("std");
const wren = @import("wren");

const Point = struct {
    x: f64,

    fn init(x: f64) Point {
        return .{ .x = x };
    }

    fn getX(self: *const Point) f64 {
        return self.x;
    }
};

const Other = struct {
    fn init() Other {
        return .{};
    }
};

const Meter = struct {
    value: f64,

    fn init(value: f64) Meter {
        return .{ .value = value };
    }

    fn getValue(self: *const Meter) f64 {
        return self.value;
    }
};

var finalized: usize = 0;
var expected_error_seen = false;
var binding_abort_seen = false;

fn finalizePoint(_: *Point) void {
    finalized += 1;
}

fn echo(value: []const u8) []const u8 {
    return value;
}

fn byteLength(value: []const u8) f64 {
    return @floatFromInt(value.len);
}

fn allocatedGreeting(name: []const u8) !wren.OwnedString {
    const gpa = std.testing.allocator;
    const str = try std.fmt.allocPrint(gpa, "Hello, {s}!", .{name});
    return .init(gpa, str);
}

fn optionalNumber(value: ?f64) ?f64 {
    return value;
}

fn inspectList(list: wren.List(f64)) !f64 {
    try list.append(3);
    try list.set(0, 4);
    return (try list.get(0)) + (try list.get(2));
}

fn inspectMap(map: wren.Map([]const u8, f64)) !f64 {
    try map.put("answer", 42);
    return try map.get("answer");
}

fn pointX(point: *const Point) f64 {
    return point.x;
}

fn expectedFailure() error{ExpectedFailure}!void {
    return error.ExpectedFailure;
}

const Bindings = wren.module(.{
    .module = "bindings.wren",
    .classes = .{
        wren.Class(.{
            .name = "Bridge",
            .methods = .{
                wren.Static("echo", echo),
                wren.Static("byteLength", byteLength),
                wren.Static("allocatedGreeting", allocatedGreeting),
                wren.Static("optionalNumber", optionalNumber),
                wren.Static("inspectList", inspectList),
                wren.Static("inspectMap", inspectMap),
                wren.Static("pointX", pointX),
                wren.Static("fail", expectedFailure),
            },
        }),
        wren.ForeignClass(Point, .{
            .name = "Point",
            .constructor = wren.Constructor("new", Point.init),
            .methods = .{wren.Getter("x", Point.getX)},
            .finalizer = finalizePoint,
        }),
        wren.ForeignClass(Other, .{
            .name = "Other",
            .constructor = wren.Constructor("new", Other.init),
            .methods = .{},
            .finalizer = null,
        }),
    },
});

const MoreBindings = wren.module(.{
    .module = "more-bindings.wren",
    .classes = .{
        wren.ForeignClass(Meter, .{
            .name = "Meter",
            .constructor = wren.Constructor("new", Meter.init),
            .methods = .{wren.Getter("value", Meter.getValue)},
            .finalizer = null,
        }),
    },
});

fn captureError(_: ?*void, kind: wren.ErrorType, _: ?[]const u8, _: i32, message: []const u8) void {
    if (kind == .Runtime and std.mem.eql(u8, message, "ExpectedFailure")) {
        expected_error_seen = true;
    }
    if (kind == .Runtime and std.mem.eql(u8, message, "List index out of bounds")) {
        binding_abort_seen = true;
    }
}

fn bindingVm() !wren.Vm(void) {
    return wren.Vm(void).init(std.testing.allocator, null, .{
        .errorFn = captureError,
        .modules = .{ Bindings, MoreBindings },
    });
}

test "No side effects" {
    const gpa = std.testing.allocator;
    var vm = try wren.Vm(void).init(gpa, null, .{});
    defer vm.deinit(gpa);

    try vm.interpret("main.wren", "var x = 42");
}

test "Compile error" {
    const gpa = std.testing.allocator;
    var vm = try wren.Vm(void).init(gpa, null, .{});
    defer vm.deinit(gpa);

    const err = vm.interpret("main.wren", "var x = 42;");
    try std.testing.expectError(error.CompileError, err);
}

test "Runtime error" {
    const gpa = std.testing.allocator;
    var vm = try wren.Vm(void).init(gpa, null, .{});
    defer vm.deinit(gpa);

    const err = vm.interpret("main.wren", "System.unknown()");
    try std.testing.expectError(error.RuntimeError, err);
}

test "generated binding source" {
    try std.testing.expectEqualStrings(
        \\class Bridge {
        \\  foreign static echo(arg0)
        \\  foreign static byteLength(arg0)
        \\  foreign static allocatedGreeting(arg0)
        \\  foreign static optionalNumber(arg0)
        \\  foreign static inspectList(arg0)
        \\  foreign static inspectMap(arg0)
        \\  foreign static pointX(arg0)
        \\  foreign static fail()
        \\}
        \\
        \\foreign class Point {
        \\  construct new(arg0) {}
        \\  foreign x
        \\}
        \\
        \\foreign class Other {
        \\  construct new() {}
        \\}
        \\
        \\
    , Bindings.source);
}

test "Vm.init preloads multiple generated modules" {
    var vm = try bindingVm();
    defer vm.deinit(std.testing.allocator);

    try vm.interpret("merged.wren",
        \\import "bindings.wren" for Bridge
        \\import "more-bindings.wren" for Meter
        \\if (Bridge.echo("first") != "first") Fiber.abort("bad first module")
        \\if (Meter.new(17).value != 17) Fiber.abort("bad second module")
    );
}

test "strings, nulls, lists, maps, and foreign arguments" {
    var vm = try bindingVm();
    defer vm.deinit(std.testing.allocator);

    try vm.interpret("values.wren",
        \\import "bindings.wren" for Bridge, Point
        \\if (Bridge.echo("alpha") != "alpha") Fiber.abort("bad string")
        \\if (Bridge.byteLength("a\u0000b") != 3) Fiber.abort("bad byte string")
        \\if (Bridge.allocatedGreeting("Wren") != "Hello, Wren!") Fiber.abort("bad owned string")
        \\if (Bridge.optionalNumber(null) != null) Fiber.abort("bad null")
        \\if (Bridge.optionalNumber(12) != 12) Fiber.abort("bad optional")
        \\if (Bridge.inspectList([1, 2]) != 7) Fiber.abort("bad list")
        \\if (Bridge.inspectMap({}) != 42) Fiber.abort("bad map")
        \\if (Bridge.pointX(Point.new(9)) != 9) Fiber.abort("bad foreign")
    );
}

test "Zig errors abort the Wren fiber" {
    expected_error_seen = false;
    var vm = try bindingVm();
    defer vm.deinit(std.testing.allocator);

    try std.testing.expectError(error.RuntimeError, vm.interpret("error.wren",
        \\import "bindings.wren" for Bridge
        \\Bridge.fail()
    ));
    try std.testing.expect(expected_error_seen);
}

test "collection errors preserve their Wren message" {
    binding_abort_seen = false;
    var vm = try bindingVm();
    defer vm.deinit(std.testing.allocator);

    try std.testing.expectError(error.RuntimeError, vm.interpret("bounds.wren",
        \\import "bindings.wren" for Bridge
        \\Bridge.inspectList([])
    ));
    try std.testing.expect(binding_abort_seen);
}

test "foreign arguments are type checked" {
    var vm = try bindingVm();
    defer vm.deinit(std.testing.allocator);

    try std.testing.expectError(error.RuntimeError, vm.interpret("wrong-foreign.wren",
        \\import "bindings.wren" for Bridge, Other
        \\Bridge.pointX(Other.new())
    ));
}

test "foreign finalizer runs once" {
    finalized = 0;
    var vm = try bindingVm();
    defer vm.deinit(std.testing.allocator);

    try vm.interpret("finalizer.wren",
        \\import "bindings.wren" for Point
        \\class Scope {
        \\  static make() { Point.new(1) }
        \\}
        \\Scope.make()
    );
    vm.collectGarbage();
    try std.testing.expectEqual(@as(usize, 1), finalized);
}
