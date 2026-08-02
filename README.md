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

fn writeFn(text: []const u8) void {
    std.debug.print("{s}", .{text});
}

fn say_hi(name: []const u8) !wren.OwnedString {
    const str = try std.fmt.allocPrint(gpa, "Hi {s}!", .{name});
    return .init(gpa, str);
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
    var vm = try wren.Vm.init(gpa, .{
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
                wren.Getter("x", Point.getX),
                wren.Setter("x", Point.setX),
                wren.Getter("y", Point.getY),
                wren.Setter("y", Point.setY),
            },
            .finalizer = null,
        }),
    },
});
```

## Testing

Tests can be run with `zig build test`.

A demo can be run with `zig build demo`.

## License

The bindings have been released under the [MIT license](./LICENSE). Wren itself
has licensing details in [wren/LICENSE](./wren/LICENSE).
