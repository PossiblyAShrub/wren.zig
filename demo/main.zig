const std = @import("std");
const wren = @import("wren");

fn wrenWriteFn(_: ?*void, text: []const u8) void {
    std.debug.print("{s}", .{text});
}

fn wrenErrorFn(_: ?*void, errorType: wren.ErrorType, module: ?[]const u8, line: i32, message: []const u8) void {
    var errorTypeStr: []const u8 = "COMPILE ERROR";
    switch (errorType) {
        .Compile => {},
        .Runtime => {
            errorTypeStr = "RUNTIME ERROR";
        },
        .StackTrace => {
            errorTypeStr = "STACK TRACE";
        },
    }

    if (module != null) {
        std.debug.print("{s}:{} [{s}] {s}\n", .{ module.?, line, errorTypeStr, message });
    } else {
        std.debug.print("[{s}] {s}\n", .{ errorTypeStr, message });
    }
}

fn demo_add(x: f64) f64 {
    return x + 1;
}

const Point2 = struct {
    x: f64,
    y: f64,

    pub fn init(x: f64, y: f64) Point2 {
        return .{ .x = x, .y = y };
    }
};

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

    pub fn translateNew(self: *Point, dx: f64, dy: f64) Point2 {
        return .{
            .x = self.x + dx,
            .y = self.y + dy,
        };
    }

    pub fn length(self: *const Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }
};

fn say_hi(ctx: *wren.Context, name: []const u8) !wren.String {
    var buffer: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "Hi {s}!", .{name});
    return ctx.string(text);
}

const DemoModule = wren.module(.{
    .module = "demo.wren",
    .classes = .{
        wren.Class(.{
            .name = "Test",
            .methods = .{
                wren.Static("add1", demo_add),
            },
        }),

        wren.ForeignClass(Point, .{
            .name = "Point",
            .constructor = wren.Constructor("new", Point.init),
            .methods = .{
                wren.Method("translate", Point.translate),
                wren.Method("translateNew", Point.translateNew),
                wren.Getter("length", Point.length),
                wren.Property("x", "x", .read_write),
                wren.Property("y", "y", .read_write),
            },
            .finalizer = null,
        }),
    },
});

const OtherModule = wren.module(.{
    .module = "other.wren",
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
    const gpa = std.heap.smp_allocator;
    var vm: wren.Vm(void) = try .init(gpa, null, .{
        .writeFn = wrenWriteFn,
        .errorFn = wrenErrorFn,
        .modules = .{ DemoModule, OtherModule },
    });
    defer vm.deinit(gpa);

    try vm.interpret("main.wren",
        \\import "demo.wren" for Test, Point
        \\import "other.wren" for Greeter
        \\
        \\System.print(Test.add1(41)) // 42
        \\
        \\var p = Point.new(6, 7)
        \\System.print(p.length) // 9.219
        \\
        \\p.x = 0
        \\System.print(p.length) // 7
        \\
        \\p.y = 2
        \\System.print(p.length) // 2
        \\
        \\p.translate(1, 1)
        \\System.print("Updated! %(p.x) %(p.y)") // 1, 3
        \\
        \\System.print(Greeter.hello("Alice"))
    );
}
