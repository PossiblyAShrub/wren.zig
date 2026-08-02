const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("wren/src/include/wren.h"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("wren", .{
        .root_source_file = translate.getOutput(),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addCSourceFiles(.{
        .files = &.{
            "wren/src/vm/wren_compiler.c",
            "wren/src/vm/wren_core.c",
            "wren/src/vm/wren_debug.c",
            "wren/src/vm/wren_primitive.c",
            "wren/src/vm/wren_utils.c",
            "wren/src/vm/wren_value.c",
            "wren/src/vm/wren_vm.c",
            "wren/src/optional/wren_opt_meta.c",
            "wren/src/optional/wren_opt_random.c",
        },
    });
    mod.addIncludePath(b.path("wren/src/include/"));
    mod.addIncludePath(b.path("wren/src/vm"));
    mod.addIncludePath(b.path("wren/src/optional/"));

    const mod_tests = b.addTest(.{
        .root_module = b.addModule("wren_test", .{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wren", .module = mod },
            },
            }),
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const exe_demo = b.addExecutable(.{
        .name = "wren_demo",
        .root_module = b.addModule("wren_demo_mod", .{
            .root_source_file = b.path("src/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wren", .module = mod },
            },
        }),
    });
    const run_exe_demo = b.addRunArtifact(exe_demo);
    const demo_step = b.step("demo", "Run the wren.zig demo");
    demo_step.dependOn(&run_exe_demo.step);
}
