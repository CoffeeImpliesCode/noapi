const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const release_safe = std.builtin.OptimizeMode.ReleaseSafe;
    const sdl3 = b.dependency("sdl3", .{ .target = target, .optimize = release_safe });
    const tracy = b.dependency("tracy", .{ .target = target, .optimize = release_safe });

    // ── noapi module ──────────────────────────────────────
    const mod = b.addModule("noapi", .{
        .root_source_file = b.path("noapi/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            .{ .name = "tracy", .module = tracy.module("tracy") },
        },
    });

    // Library artifact for C dep propagation (matches rendering project pattern)
    const lib = b.addLibrary(.{
        .name = "noapi",
        .root_module = mod,
    });

    // ── noapi-test executable ─────────────────────────────
    const exe = b.addExecutable(.{
        .name = "noapi-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
            },
        }),
    });
    exe.root_module.linkLibrary(lib);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run noapi-test app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // ── Tests ─────────────────────────────────────────────
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run noapi tests");
    test_step.dependOn(&run_mod_tests.step);
}
