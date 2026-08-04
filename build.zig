const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_wren = b.dependency("wren-c", .{});

    const translate = b.addTranslateC(.{
        .root_source_file = dep_wren.path("src/include/wren.h"),
        .target = target,
        .optimize = optimize,
    });

    const mod_wren_raw = b.addModule("wren_raw", .{
        .root_source_file = translate.getOutput(),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod_wren_raw.addCSourceFile(.{ .file = dep_wren.path("src/vm/wren_compiler.c") });
    mod_wren_raw.addCSourceFile(.{ .file = dep_wren.path("src/vm/wren_core.c") });
    mod_wren_raw.addCSourceFile(.{ .file = dep_wren.path("src/vm/wren_debug.c") });
    mod_wren_raw.addCSourceFile(.{ .file = dep_wren.path("src/vm/wren_primitive.c") });
    mod_wren_raw.addCSourceFile(.{ .file = dep_wren.path("src/vm/wren_utils.c") });
    mod_wren_raw.addCSourceFile(.{ .file = dep_wren.path("src/vm/wren_value.c") });
    mod_wren_raw.addCSourceFile(.{ .file = dep_wren.path("src/vm/wren_vm.c") });
    mod_wren_raw.addCSourceFile(.{ .file = dep_wren.path("src/optional/wren_opt_meta.c") });
    mod_wren_raw.addCSourceFile(.{ .file = dep_wren.path("src/optional/wren_opt_random.c") });
    mod_wren_raw.addIncludePath(dep_wren.path("src/include/"));
    mod_wren_raw.addIncludePath(dep_wren.path("src/vm"));
    mod_wren_raw.addIncludePath(dep_wren.path("src/optional/"));

    const mod_wren = b.addModule("wren", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wren_raw", .module = mod_wren_raw },
        },
    });

    const mod_tests = b.addTest(.{
        .root_module = b.addModule("wren_test", .{
            .root_source_file = b.path("test/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wren", .module = mod_wren },
            },
            }),
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const exe_demo = b.addExecutable(.{
        .name = "wren_demo",
        .root_module = b.addModule("wren_demo_mod", .{
            .root_source_file = b.path("demo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wren", .module = mod_wren },
            },
        }),
    });
    const run_exe_demo = b.addRunArtifact(exe_demo);
    const demo_step = b.step("demo", "Run the wren.zig demo");
    demo_step.dependOn(&run_exe_demo.step);
}
