# wren.zig

Zig bindings for [Wren](https://wren.io), including declarative foreign-class
bindings and a small host-side VM API.

## Installation

```sh
zig fetch --save=wren git+https://github.com/PossiblyAShrub/wren.zig.git
```

In `build.zig`, import the fetched package into the root module:

```zig
const wren_dep = b.dependency("wren", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("wren", wren_dep.module("wren"));
```

## A minimal VM

```zig
const std = @import("std");
const wren = @import("wren");

fn writeFn(_: ?*void, text: []const u8) void {
    std.debug.print("{s}", .{text});
}

pub fn main() !void {
    var vm = try wren.Vm(void).init(std.heap.smp_allocator, null, .{
        .writeFn = writeFn,
    });
    defer vm.deinitOwned();
    try vm.interpret("main.wren", "System.print(\"hello\")");
}
```

`Vm.init` stores the allocator for `deinitOwned`; `deinit(allocator)` remains
available when the caller wants to provide it explicitly. `writeFn` and
`errorFn` receive optional user data. Wren heap allocation still uses Wren's
default allocator.

## Generated bindings

```zig
fn sayHi(ctx: *wren.Context, name: []const u8) !wren.String {
    var buffer: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "Hi {s}!", .{name});
    return ctx.string(text);
}

const Demo = wren.module(.{
    .module = "demo.wren",
    .classes = .{
        wren.Class(.{
            .name = "Greeter",
            .methods = .{ wren.Static("hello", sayHi) },
        }),
    },
});
```

Foreign classes store a Zig value in Wren-managed foreign storage:

```zig
const Point = struct {
    x: f64,
    y: f64,

    fn init(x: f64, y: f64) Point { return .{ .x = x, .y = y }; }
    fn translate(self: *Point, dx: f64, dy: f64) void {
        self.x += dx; self.y += dy;
    }
    fn length(self: *const Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }
};

const Math = wren.module(.{
    .module = "math.wren",
    .classes = .{
        wren.ForeignClass(Point, .{
            .name = "Point",
            .constructor = wren.Constructor("new", Point.init),
            .methods = .{
                wren.Method("translate", Point.translate),
                wren.Getter("length", Point.length),
                wren.Field("x", .read_write),
                wren.Field("y", .read_write),
            },
            .finalizer = null,
        }),
    },
});
```

`ForeignClass` defaults `.methods` to an empty tuple and `.finalizer` to
`null`. A finalizer must be `fn (*T) void`; it must not call the VM.

Pass generated modules in `.modules`; they are interpreted before `init`
returns. General runtime module loading is not yet exposed; applications should
preload source with `interpret` or use generated modules.

## Values and lifetimes

Foreign callback arguments are borrowed and valid only during that callback.
`Value`, `String`, `List`, `Map`, `Object`, and `Foreign(T)` are borrowed views.
Use `ctx.retain(value)` to create an owned `Handle`; release it exactly once.
Returning a `Handle` from a bound function transfers ownership to Wren and
releases the handle automatically.

`List` and `Map` operations use dynamic `Value` results:

```zig
const n = try (try list.get(0)).as(f64);
try map.put("answer", 42);
```

Rooted host values can be created with `vm.string`, `vm.number`,
`vm.boolean`, `vm.nullValue`, or `vm.foreign`. `vm.callValue(T, receiver,
signature, args)` calls Wren and decodes the rooted result as `T`; `Handle.as(T)`
does the same for an existing handle.

`Context.userData(T)` accesses the user-data pointer supplied to `Vm.init`.
`Context.allocator()` returns the allocator stored by the wrapper for use by
foreign resources.

Supported primitive codecs are Wren numbers (`f64`), booleans, strings
(`[]const u8`), null through optionals, and the borrowed/rooted wrapper types.
Foreign pointers (`*T`/`*const T`) and `Foreign(T)` are both accepted for
foreign arguments; prefer `Foreign(T)` when a value may be passed through
dynamic collections.

## Testing

```sh
zig build test
zig build demo
```

## License

The bindings are MIT licensed. Wren is distributed under its own license in
the Wren dependency.
