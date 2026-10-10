const std = @import("std");
const wren = @import("wren");

const Helpers = struct {
    fn report(_: ?*void, kind: wren.ErrorType, module: ?[]const u8, line: i32, message: []const u8) void {
        std.debug.print("{s} {s}:{d}: {s}\n", .{ @tagName(kind), module orelse "", line, message });
    }

    fn kinds(ctx: *wren.Context, value: wren.Value) !wren.String {
        const original_type = value.typeOf();
        const kind: wren.ValueKind = value.kind();
        try std.testing.expectEqual(original_type, value.typeOf());
        return ctx.string(@tagName(kind));
    }

    fn many(ctx: *wren.Context) !wren.List {
        const result = ctx.list();
        const before = ctx.string("before").value.slot;
        const writer: wren.List.Writer = result.writer();
        for (0..10000) |i| try writer.append(i);
        try writer.append(true);
        try writer.append(@as([]const u8, "\x00\xff"));
        try writer.append(null);
        // Only the writer's slot should have been allocated between these strings.
        try std.testing.expectEqual(before + 2, ctx.string("after").value.slot);
        return result;
    }

    fn copy(ctx: *wren.Context, value: wren.Value) !wren.List {
        const result = ctx.list();
        const writer = result.writer();
        const second_writer = result.writer();
        try writer.append(value);
        try second_writer.append(value);
        try writer.append(ctx.string("owned"));
        try writer.append(ctx.list());
        try writer.append(ctx.map());
        const optional: ?u32 = 42;
        try writer.append(optional);
        try writer.append(@as(?u32, null));
        return result;
    }

    fn fail(ctx: *wren.Context) error{BindingAborted}!void {
        var message = [_]u8{ 'o', 'o', 'p', 's', 0, 255 };
        const err = ctx.abort(&message);
        @memset(&message, '?');
        return err;
    }

    fn fieldError(ctx: *wren.Context, value: wren.Value) !void {
        if (value.kind() != .number) {
            var buffer: [128]u8 = undefined;
            const message = try std.fmt.bufPrint(&buffer, "bytes: field {d}: expected a Number", .{@as(usize, 3)});
            return ctx.abort(message);
        }
    }

    fn wrongVm(ctx: *wren.Context) !wren.List {
        const result = ctx.list();
        const writer = result.writer();
        try writer.append(ctx.userData(wren.Value).?.*);
        return result;
    }
};

const HelpersApi = wren.module(.{
    .module = "helpers",
    .classes = .{wren.Class(.{
        .name = "Helpers",
        .methods = .{
            wren.Static("kinds", Helpers.kinds),
            wren.Static("many", Helpers.many),
            wren.Static("copy", Helpers.copy),
            wren.Static("fail", Helpers.fail),
            wren.Static("fieldError", Helpers.fieldError),
            wren.Static("wrongVm", Helpers.wrongVm),
        },
    })},
});

test "public value inspection, list writer, and fiber diagnostics" {
    var vm = try wren.Vm(void).init(std.testing.allocator, null, .{ .modules = .{ HelpersApi, Bindings }, .errorFn = Helpers.report });
    defer vm.deinitOwned();

    try vm.interpret("helpers-test",
        \\import "helpers" for Helpers
        \\import "bindings.wren" for Point
        \\var input = [true, 1, "", Point.new(5), [], {}, null, Fn.new {}, Point, Point.type]
        \\var expected = ["boolean", "number", "string", "foreign", "list", "map", "null", "unknown", "unknown", "unknown"]
        \\for (i in 0...(expected.count)) {
        \\  if (Helpers.kinds(input[i]) != expected[i]) Fiber.abort("value kind")
        \\}
        \\var values = Helpers.many()
        \\if (values.count != 10003) Fiber.abort("list length")
        \\for (i in 0...10000) {
        \\  if (values[i] != i) Fiber.abort("list value")
        \\}
        \\if (values[10000] != true) Fiber.abort("Boolean value")
        \\if (values[10001] != "\x00\xff") Fiber.abort("binary value")
        \\if (values[10002] != null) Fiber.abort("null value")
        \\var copied = []
        \\for (i in 0...(input.count)) {
        \\  var result = Helpers.copy(input[i])
        \\  if (result[0] != input[i] || result[1] != input[i]) Fiber.abort("wrapper value")
        \\  if (result[2] != "owned" || result[3].count != 0 || result[4].count != 0 || result[5] != 42 || result[6] != null) Fiber.abort("writer codecs")
        \\  copied.add(result)
        \\}
        \\var error = Fiber.new { Helpers.fail() }.try()
        \\if (error != "oops\x00\xff") Fiber.abort("diagnostic")
        \\var fieldError = Fiber.new { Helpers.fieldError("bad") }.try()
        \\if (fieldError != "bytes: field 3: expected a Number") Fiber.abort("field diagnostic")
        \\Helpers.fieldError(42)
        \\if (Helpers.many()[9999] != 9999) Fiber.abort("recovery")
    );

    vm.collectGarbage();

    try vm.interpret("helpers-test",
        \\if (values[10001] != "\x00\xff") Fiber.abort("list ownership")
        \\if (error != "oops\x00\xff") Fiber.abort("diagnostic ownership")
        \\if (copied[3][0].x != 5 || copied[3][2] != "owned") Fiber.abort("wrapper ownership")
    );
}

test "list writer rejects values from another VM" {
    var owner = try wren.Vm(void).init(std.testing.allocator, null, .{});
    defer owner.deinitOwned();
    var handle = try owner.string("other VM");
    defer handle.release();
    var value = try handle.as(wren.Value);
    var vm = try wren.Vm(wren.Value).init(std.testing.allocator, &value, .{ .modules = .{HelpersApi} });
    defer vm.deinitOwned();
    try vm.interpret("wrong-vm",
        \\import "helpers" for Helpers
        \\var error = Fiber.new { Helpers.wrongVm() }.try()
        \\if (error != "Cannot return a value from another Wren VM") Fiber.abort("ownership check")
        \\if (Helpers.many()[9999] != 9999) Fiber.abort("recovery")
    );
}

const Point = struct {
    x: f64,

    fn init(x: f64) Point {
        return .{ .x = x };
    }

    fn getX(self: *const Point) f64 {
        return self.x;
    }
};

const State = struct {
    value: f64,
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

const Resource = struct {
    bytes: []u8,
};

var finalized: usize = 0;
var expected_error_seen = false;
var binding_abort_seen = false;
var binding_state = State{ .value = 73 };
var resource_finalized: usize = 0;

fn finalizePoint(_: *Point) void {
    finalized += 1;
}

fn echo(value: []const u8) []const u8 {
    return value;
}

fn byteLength(value: []const u8) f64 {
    return @floatFromInt(value.len);
}

fn greeting(ctx: *wren.Context, name: []const u8) !wren.String {
    var buffer: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "Hello, {s}!", .{name});
    return ctx.string(text);
}

fn optionalNumber(value: ?f64) ?f64 {
    return value;
}

fn inspectList(list: wren.List) !f64 {
    try list.append(3);
    try list.set(0, 4);
    return (try (try list.get(0)).asNum()) + (try (try list.get(2)).asNum());
}

fn sumList(list: wren.List) !f64 {
    var iterator = list.iterator();
    var sum: f64 = 0;
    while (iterator.next()) |value| {
        try std.testing.expectEqual(iterator.scratch, value.slot);
        sum += try value.asNum();
    }
    try std.testing.expect(iterator.next() == null);
    return sum;
}

fn inspectMap(map: wren.Map) !f64 {
    try map.put("answer", 42);
    return try (try map.get("answer")).asNum();
}

fn inspectDynamicValues(list: wren.List) !f64 {
    const number = try (try list.get(0)).asNum();
    const text = try (try list.get(1)).asString();
    const point = try (try list.get(2)).asObject();
    const foreign = try wren.Foreign(Point).fromObject(point);
    return number + @as(f64, @floatFromInt((try text.bytes()).len)) + foreign.get().x;
}

fn makeMixedList(ctx: *wren.Context, point: wren.Foreign(Point)) !wren.List {
    var list = ctx.list();
    try list.append(1.5);
    try list.append(ctx.string("two"));
    try list.append(point);
    try list.append(null);
    return list;
}

fn inspectDynamicMap(map: wren.Map) !f64 {
    const number = try (try map.get("number")).asNum();
    const text = try (try map.get("text")).asString();
    return number + @as(f64, @floatFromInt((try text.bytes()).len));
}

fn pointX(point: wren.Foreign(Point)) !f64 {
    return point.get().x;
}

fn movePoint(point: wren.Foreign(Point), dx: f64) !void {
    point.get().x += dx;
}

fn distanceBetween(first: wren.Foreign(Point), second: wren.Foreign(Point)) !f64 {
    return @abs(first.get().x - second.get().x);
}

fn clonePoint(point: wren.Foreign(Point)) !Point {
    return point.get().*;
}

fn makePoint(x: f64) Point {
    return .{ .x = x };
}

fn makeOther() Other {
    return .{};
}

fn resourceInit() !Resource {
    return .{ .bytes = try std.testing.allocator.dupe(u8, "resource") };
}

fn resourceLength(resource: wren.Foreign(Resource)) !f64 {
    return @floatFromInt(resource.get().bytes.len);
}

fn makeResource() !Resource {
    return resourceInit();
}

fn finalizeResource(resource: *Resource) void {
    std.testing.allocator.free(resource.bytes);
    resource_finalized += 1;
}

fn emptyList(ctx: *wren.Context) wren.List {
    return ctx.list();
}

fn populatedList(ctx: *wren.Context) !wren.List {
    var list = ctx.list();
    try list.append(42);
    return list;
}

fn retainedString(ctx: *wren.Context) !wren.Handle {
    return ctx.retain(ctx.string("retained"));
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
                wren.Static("greeting", greeting),
                wren.Static("optionalNumber", optionalNumber),
                wren.Static("inspectList", inspectList),
                wren.Static("sumList", sumList),
                wren.Static("inspectMap", inspectMap),
                wren.Static("inspectDynamicValues", inspectDynamicValues),
                wren.Static("makeMixedList", makeMixedList),
                wren.Static("inspectDynamicMap", inspectDynamicMap),
                wren.Static("pointX", pointX),
                wren.Static("movePoint", movePoint),
                wren.Static("distanceBetween", distanceBetween),
                wren.Static("makePoint", makePoint),
                wren.Static("makeOther", makeOther),
                wren.Static("resourceLength", resourceLength),
                wren.Static("makeResource", makeResource),
                wren.Static("emptyList", emptyList),
                wren.Static("populatedList", populatedList),
                wren.Static("retainedString", retainedString),
                wren.Static("fail", expectedFailure),
            },
        }),
        wren.ForeignClass(Point, .{
            .name = "Point",
            .constructor = wren.Constructor("new", Point.init),
            .methods = .{
                wren.Method("move", movePoint),
                wren.Method("clone", clonePoint),
                wren.Property("x", "x", .read_write),
            },
            .finalizer = finalizePoint,
        }),
        wren.ForeignClass(Other, .{
            .name = "Other",
            .constructor = wren.Constructor("new", Other.init),
            .methods = .{},
            .finalizer = null,
        }),
        wren.ForeignClass(Resource, .{
            .name = "Resource",
            .constructor = wren.Constructor("new", resourceInit),
            .methods = .{},
            .finalizer = finalizeResource,
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

fn captureError(_: ?*State, kind: wren.ErrorType, _: ?[]const u8, _: i32, message: []const u8) void {
    if (kind == .Runtime and std.mem.eql(u8, message, "ExpectedFailure")) {
        expected_error_seen = true;
    }
    if (kind == .Runtime and std.mem.eql(u8, message, "List index out of bounds")) {
        binding_abort_seen = true;
    }
}

fn bindingVm() !wren.Vm(State) {
    return wren.Vm(State).init(std.testing.allocator, &binding_state, .{
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

test "host values and typed call results" {
    var vm = try bindingVm();
    defer vm.deinit(std.testing.allocator);

    var bridge = try vm.variable("bindings.wren", "Bridge");
    defer bridge.release();
    var input = try vm.string("from host");
    defer input.release();
    var output = try vm.callValue(wren.String, bridge, "echo(_)", &.{input});
    try std.testing.expectEqualStrings("from host", try output.bytes());
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
        \\  foreign static greeting(arg0)
        \\  foreign static optionalNumber(arg0)
        \\  foreign static inspectList(arg0)
        \\  foreign static sumList(arg0)
        \\  foreign static inspectMap(arg0)
        \\  foreign static inspectDynamicValues(arg0)
        \\  foreign static makeMixedList(arg0)
        \\  foreign static inspectDynamicMap(arg0)
        \\  foreign static pointX(arg0)
        \\  foreign static movePoint(arg0, arg1)
        \\  foreign static distanceBetween(arg0, arg1)
        \\  foreign static makePoint(arg0)
        \\  foreign static makeOther()
        \\  foreign static resourceLength(arg0)
        \\  foreign static makeResource()
        \\  foreign static emptyList()
        \\  foreign static populatedList()
        \\  foreign static retainedString()
        \\  foreign static fail()
        \\}
        \\
        \\foreign class Point {
        \\  construct new(arg0) {}
        \\  foreign move(arg0)
        \\  foreign clone()
        \\  foreign x
        \\  foreign x=(arg0)
        \\}
        \\
        \\foreign class Other {
        \\  construct new() {}
        \\}
        \\
        \\foreign class Resource {
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

test "list iterator reuses a slot across a long list" {
    var vm = try bindingVm();
    defer vm.deinit(std.testing.allocator);

    try vm.interpret("long-list.wren",
        \\import "bindings.wren" for Bridge
        \\if (Bridge.sumList([]) != 0) Fiber.abort("bad empty list")
        \\var numbers = []
        \\var i = 0
        \\while (i < 10000) {
        \\  numbers.add(i)
        \\  i = i + 1
        \\}
        \\if (Bridge.sumList(numbers) != 49995000) Fiber.abort("bad list sum")
    );
}

test "strings, nulls, lists, maps, and foreign arguments" {
    var vm = try bindingVm();
    defer vm.deinit(std.testing.allocator);

    try vm.interpret("values.wren",
        \\import "bindings.wren" for Bridge, Point, Other, Resource
        \\if (Bridge.echo("alpha") != "alpha") Fiber.abort("bad string")
        \\if (Bridge.byteLength("a\u0000b") != 3) Fiber.abort("bad byte string")
        \\if (Bridge.greeting("Wren") != "Hello, Wren!") Fiber.abort("bad VM string")
        \\if (Bridge.optionalNumber(null) != null) Fiber.abort("bad null")
        \\if (Bridge.optionalNumber(12) != 12) Fiber.abort("bad optional")
        \\if (Bridge.inspectList([1, 2]) != 7) Fiber.abort("bad list")
        \\if (Bridge.inspectMap({}) != 42) Fiber.abort("bad map")
        \\if (Bridge.inspectDynamicValues([2, "abc", Point.new(4)]) != 9) Fiber.abort("bad dynamic values")
        \\var mixed = Bridge.makeMixedList(Point.new(8))
        \\if (mixed[0] != 1.5) Fiber.abort("bad mixed number")
        \\if (mixed[1] != "two") Fiber.abort("bad mixed string")
        \\if (mixed[2].x != 8) Fiber.abort("bad mixed foreign")
        \\if (mixed[3] != null) Fiber.abort("bad mixed null")
        \\if (Bridge.inspectDynamicMap({"number": 4, "text": "abc"}) != 7) Fiber.abort("bad dynamic map")
        \\if (Bridge.pointX(Point.new(9)) != 9) Fiber.abort("bad foreign")
        \\var first = Point.new(2)
        \\var second = Point.new(9)
        \\Bridge.movePoint(first, 3)
        \\first.move(4)
        \\if (first.x != 9) Fiber.abort("bad mutable foreign consumption")
        \\if (Bridge.distanceBetween(first, second) != 0) Fiber.abort("bad multiple foreign arguments")
        \\if (first.clone().x != 9) Fiber.abort("bad instance foreign return")
        \\var generated = Bridge.makePoint(12)
        \\generated.x = 14
        \\if (generated.x != 14) Fiber.abort("bad generated property")
        \\if (Bridge.emptyList().count != 0) Fiber.abort("bad returned list")
        \\if (Bridge.populatedList()[0] != 42) Fiber.abort("bad populated list")
        \\if (Bridge.retainedString() != "retained") Fiber.abort("bad retained value")
        \\if (!(Bridge.makeOther() is Other)) Fiber.abort("bad other foreign return")
        \\if (Bridge.resourceLength(Resource.new()) != 8) Fiber.abort("bad resource constructor")
        \\if (Bridge.resourceLength(Bridge.makeResource()) != 8) Fiber.abort("bad resource return")
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

    try std.testing.expectError(error.RuntimeError, vm.interpret("wrong-consumed-foreign.wren",
        \\import "bindings.wren" for Bridge, Point, Other
        \\Bridge.distanceBetween(Point.new(1), Other.new())
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

test "foreign storage owns Zig resources for constructors and returns" {
    resource_finalized = 0;
    var vm = try bindingVm();
    defer vm.deinit(std.testing.allocator);

    try vm.interpret("resource-finalizer.wren",
        \\import "bindings.wren" for Bridge, Resource
        \\class Scope {
        \\  static make() {
        \\    Resource.new()
        \\    Bridge.makeResource()
        \\  }
        \\}
        \\Scope.make()
    );
    vm.collectGarbage();
    try std.testing.expectEqual(@as(usize, 2), resource_finalized);
}
