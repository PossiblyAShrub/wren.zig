# wren.zig

Zig bindings for [wren](https://wren.io).

## Usage

Add to your project with:

```sh
zig fetch --save=wren git+https://github.com/PossiblyAShrub/wren.zig.git
```

wren.zig exposes a zig-ified wren API. Bindings can be automatically generated
from functions.

```zig
const std = @import("std");
const wren = @import("wren");
const gpa = std.heap.smp_allocator;

fn writeFn(_: *void, text: []const u8) void {
    std.debug.print("{s}", .{text});
}

fn say_hi(ctx: *wren.Context, name: []const u8) !wren.String {
    var buffer: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "Hi {s}!", .{name});
    return ctx.string(text);
}

const DemoModule = wren.module(.{
    .module = "demo.wren",
    .classes = .{
        wren.Class(.{
            .name = "Greeter",
            .methods = .{
                wren.Static("hello", say_hi),
            },
        }),
    },
});

pub fn main() !void {
    var vm: wren.Vm(void) = try .init(gpa, null, .{
        .writeFn = writeFn,
        .modules = .{ DemoModule },
    });
    defer vm.deinit(gpa);

    try vm.interpret("main.wren",
        \\import "demo.wren" for Greeter
        \\System.print(Greeter.hello("Alice"))
    );
}
```

Foreign classes feel like zig classes.

```zig
const Point = struct {
    x: f64,
    y: f64,

    pub fn init(x: f64, y: f64) Point {
        return .{ .x = x, .y = y };
    }

    pub fn translate(self: *Point, dx: f64, dy: f64) void {
        self.x += dx;
        self.y += dy;
    }

    pub fn length(self: *const Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn getX(self: *const Point) f64 {
        return self.x;
    }

    pub fn setX(self: *Point, value: f64) void {
        self.x = value;
    }

    pub fn getY(self: *const Point) f64 {
        return self.y;
    }

    pub fn setY(self: *Point, value: f64) void {
        self.y = value;
    }
};

const MathModule = wren.module(.{
    .module = "math.wren",
    .classes = .{
        wren.ForeignClass(Point, .{
            .name = "Point",
            .constructor = wren.Constructor("new", Point.init),
            .methods = .{
                wren.Method("translate", Point.translate),
                wren.Getter("length", Point.length),
                wren.Property("x", "x", .read_write),
                wren.Property("y", "y", .read_write),
            },
            .finalizer = null,
        }),
    },
});
```

Functions that need VM-owned values can opt into a context. Values created by
the context are owned by Wren and are valid for the duration of the callback.
Registered foreign Zig values are automatically materialized into Wren foreign
objects when returned.

```zig
fn makePoint(_: *wren.Context, x: f64) Point {
    return .{ .x = x, .y = 0 };
}

fn makeList(ctx: *wren.Context) wren.List {
    return ctx.list();
}
```

Use `ctx.retain(value)` when a Wren value must be kept beyond the callback;
release the returned handle when it is no longer needed. Ordinary functions
without a context parameter continue to bind directly from their Zig
signature.

## Testing

Tests can be run with `zig build test`.

A demo can be run with `zig build demo`.

## License

The bindings have been released under the [MIT license](./LICENSE). Wren itself
has licensing details in [wren/LICENSE](./wren/LICENSE).
