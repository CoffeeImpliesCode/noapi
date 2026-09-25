const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const release_safe = std.builtin.OptimizeMode.ReleaseSafe;
    const sdl3 = b.dependency("sdl3", .{ .target = target, .optimize = release_safe });
    const tracy = b.dependency("tracy", .{ .target = target, .optimize = release_safe });
    const enable_tracy = b.option(bool, "enable-tracy", "Enable Tracy profiler") orelse true;
    const tracy_impl = if (enable_tracy) tracy.module("tracy_impl_enabled") else tracy.module("tracy_impl_disabled");

    // zig-cov coverage (see zig-cov README): zig-gate --cov passes these
    const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
    const cov_rt = b.option([]const u8, "coverage-rt", "zig-cov-rt path") orelse null;
    // Focused unit verification: `zig build test -Dtest-filter=<name>`.
    const test_filter = b.option([]const u8, "test-filter", "Only run tests matching this substring") orelse null;

    // ── noapi module ───────────────────────────────
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

    // ── common module (shared example helpers) ───────────
    const common_mod = b.createModule(.{
        .root_source_file = b.path("examples/common.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "noapi", .module = mod },
            .{ .name = "sdl3", .module = sdl3.module("sdl3") },
            .{ .name = "tracy", .module = tracy.module("tracy") },
            .{ .name = "tracy_impl", .module = tracy_impl },
        },
    });

    // ── noapi-test executable ────────────────────────────
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
                .{ .name = "tracy_impl", .module = tracy_impl },
            },
        }),
        .use_llvm = true,
    });
    exe.root_module.linkLibrary(lib);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run noapi-test app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const submission_lifecycle_step = b.step(
        "submission-lifecycle",
        "Run the real offscreen submission lifecycle check",
    );
    const submission_lifecycle_cmd = b.addRunArtifact(exe);
    submission_lifecycle_cmd.addArgs(&.{ "--submission-lifecycle-test", "8" });
    submission_lifecycle_step.dependOn(&submission_lifecycle_cmd.step);
    const presentation_feedback_mode = b.option(
        []const u8,
        "presentation-mode",
        "Presentation timing backend: selected or google",
    ) orelse "selected";
    const presentation_feedback_step = b.step(
        "presentation-feedback",
        "Run the real compositor presentation feedback check",
    );
    const presentation_feedback_cmd = b.addRunArtifact(exe);
    presentation_feedback_cmd.addArgs(&.{
        "--presentation-feedback-test",
        presentation_feedback_mode,
    });
    presentation_feedback_step.dependOn(&presentation_feedback_cmd.step);

    const native_triangle_vert_cmd = b.addSystemCommand(&.{"slangc"});
    native_triangle_vert_cmd.addArgs(&.{
        "-target", "spirv", "-DNOAPI_WEB=0", "-entry", "vertexMain", "-o",
    });
    const native_triangle_vert_spv = native_triangle_vert_cmd.addOutputFileArg(
        "triangle_slang_vert.spv",
    );
    native_triangle_vert_cmd.addFileArg(b.path("shaders/triangle.slang"));

    const native_triangle_frag_cmd = b.addSystemCommand(&.{"slangc"});
    native_triangle_frag_cmd.addArgs(&.{
        "-target", "spirv", "-DNOAPI_WEB=0", "-entry", "fragmentMain", "-o",
    });
    const native_triangle_frag_spv = native_triangle_frag_cmd.addOutputFileArg(
        "triangle_slang_frag.spv",
    );
    native_triangle_frag_cmd.addFileArg(b.path("shaders/triangle.slang"));

    const install_native_triangle_vert = b.addInstallFile(
        native_triangle_vert_spv,
        "shaders/triangle_slang_vert.spv",
    );
    const install_native_triangle_frag = b.addInstallFile(
        native_triangle_frag_spv,
        "shaders/triangle_slang_frag.spv",
    );
    b.getInstallStep().dependOn(&install_native_triangle_vert.step);
    b.getInstallStep().dependOn(&install_native_triangle_frag.step);

    // ── 1_triangle example executable ─────────────────────
    const exe_1_triangle = b.addExecutable(.{
        .name = "1_triangle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/1_triangle/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy_impl },
                .{ .name = "common", .module = common_mod },
            },
        }),
        .use_llvm = true,
    });
    exe_1_triangle.root_module.linkLibrary(lib);

    b.installArtifact(exe_1_triangle);

    const run_1_triangle_step = b.step("1_triangle", "Run 1_triangle example");
    const run_1_triangle_cmd = b.addRunArtifact(exe_1_triangle);
    run_1_triangle_step.dependOn(&run_1_triangle_cmd.step);
    run_1_triangle_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_1_triangle_cmd.addArgs(args);

    // ── 2_textures example ─────────────────────────────
    const tex_exe = b.addExecutable(.{
        .name = "2_textures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/2_textures/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy_impl },
                .{ .name = "common", .module = common_mod },
            },
        }),
        .use_llvm = true,
    });
    tex_exe.root_module.linkLibrary(lib);

    b.installArtifact(tex_exe);

    const tex_run_step = b.step("2_textures", "Run 2_textures example");
    const tex_run_cmd = b.addRunArtifact(tex_exe);
    tex_run_step.dependOn(&tex_run_cmd.step);
    tex_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| tex_run_cmd.addArgs(args);

    // ── 3_3D example executable ──────────────────────────
    const exe_3d = b.addExecutable(.{
        .name = "3_3D",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/3_3D/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy_impl },
                .{ .name = "common", .module = common_mod },
            },
        }),
        .use_llvm = true,
    });
    exe_3d.root_module.linkLibrary(lib);

    b.installArtifact(exe_3d);

    const run_3d_step = b.step("3_3D", "Run 3_3D example");
    const run_3d_cmd = b.addRunArtifact(exe_3d);
    run_3d_step.dependOn(&run_3d_cmd.step);
    run_3d_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_3d_cmd.addArgs(args);

    // ── 5_indirect_triangles example ──────────────────────
    const exe_5 = b.addExecutable(.{
        .name = "5_indirect_triangles",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/5_indirect_triangles/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy_impl },
                .{ .name = "common", .module = common_mod },
            },
        }),
        .use_llvm = true,
    });
    exe_5.root_module.linkLibrary(lib);

    b.installArtifact(exe_5);

    const run_step_5 = b.step("5_indirect_triangles", "Run 5_indirect_triangles example");
    const run_cmd_5 = b.addRunArtifact(exe_5);
    run_step_5.dependOn(&run_cmd_5.step);
    run_cmd_5.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd_5.addArgs(args);

    // ── 4_textures_advanced example ────────────────────────
    const tex_adv_exe = b.addExecutable(.{
        .name = "4_textures_advanced",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/4_textures_advanced/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy_impl },
                .{ .name = "common", .module = common_mod },
            },
        }),
        .use_llvm = true,
    });
    tex_adv_exe.root_module.linkLibrary(lib);

    b.installArtifact(tex_adv_exe);

    const tex_adv_run_step = b.step("4_textures_advanced", "Run 4_textures_advanced example");
    const tex_adv_run_cmd = b.addRunArtifact(tex_adv_exe);
    tex_adv_run_step.dependOn(&tex_adv_run_cmd.step);
    tex_adv_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| tex_adv_run_cmd.addArgs(args);

    // ── 6_compute_shaders example ─────────────────────────
    const exe6 = b.addExecutable(.{
        .name = "6_compute_shaders",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/6_compute_shaders/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy_impl },
                .{ .name = "common", .module = common_mod },
            },
        }),
        .use_llvm = true,
    });
    exe6.root_module.linkLibrary(lib);

    b.installArtifact(exe6);

    const run_step6 = b.step("6_compute_shaders", "Run 6_compute_shaders example");
    const run_cmd6 = b.addRunArtifact(exe6);
    run_step6.dependOn(&run_cmd6.step);
    run_cmd6.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd6.addArgs(args);

    // ── 7_deferred_async_load example ──────────────────────
    const exe_7 = b.addExecutable(.{
        .name = "7_deferred_async_load",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/7_deferred_async_load/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noapi", .module = mod },
                .{ .name = "sdl3", .module = sdl3.module("sdl3") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
                .{ .name = "tracy_impl", .module = tracy_impl },
                .{ .name = "common", .module = common_mod },
            },
        }),
        .use_llvm = true,
    });
    exe_7.root_module.linkLibrary(lib);

    b.installArtifact(exe_7);

    const run_7_step = b.step("7_deferred_async_load", "Run 7_deferred_async_load example");
    const run_7_cmd = b.addRunArtifact(exe_7);
    run_7_step.dependOn(&run_7_cmd.step);
    run_7_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_7_cmd.addArgs(args);

    // ── Tests ─────────────────────────────────
    const mod_tests = b.addTest(.{ .root_module = mod });
    if (coverage) {
        mod_tests.use_llvm = true; // required: only the LLVM backend emits sancov counters
        mod_tests.root_module.fuzz = true; // emits __sancov_cntrs + __sancov_pcs1
        mod_tests.root_module.link_libc = true; // atexit handler writes the .zcov
        if (cov_rt) |p| mod_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }
    const run_mod_tests = b.addRunArtifact(mod_tests);
    if (test_filter) |filter| mod_tests.filters = &.{filter};

    const test_step = b.step("test", "Run noapi tests");
    test_step.dependOn(&run_mod_tests.step);
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
    // The browser build is separate from the native default. It compiles only
    // the WebGPU entry and noapi module, then links the archive with emcc.
    const web_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .emscripten,
    });
    const web_tracy = b.dependency("tracy", .{
        .target = web_target,
        .optimize = optimize,
    });
    const web_noapi = b.createModule(.{
        .root_source_file = b.path("noapi/root.zig"),
        .target = web_target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "tracy", .module = web_tracy.module("tracy") },
        },
    });
    const web_triangle_vert_cmd = b.addSystemCommand(&.{"slangc"});
    web_triangle_vert_cmd.addArgs(&.{
        "-target", "wgsl", "-DNOAPI_WEB=1", "-entry", "vertexMain", "-o",
    });
    const web_triangle_vert_wgsl = web_triangle_vert_cmd.addOutputFileArg(
        "triangle_vert.wgsl",
    );
    web_triangle_vert_cmd.addFileArg(b.path("shaders/triangle.slang"));

    const web_triangle_frag_cmd = b.addSystemCommand(&.{"slangc"});
    web_triangle_frag_cmd.addArgs(&.{
        "-target", "wgsl", "-DNOAPI_WEB=1", "-entry", "fragmentMain", "-o",
    });
    const web_triangle_frag_wgsl = web_triangle_frag_cmd.addOutputFileArg(
        "triangle_frag.wgsl",
    );
    web_triangle_frag_cmd.addFileArg(b.path("shaders/triangle.slang"));

    const web_sources = b.addWriteFiles();
    const web_main_source = web_sources.addCopyFile(b.path("web/main.zig"), "main.zig");
    _ = web_sources.addCopyFile(b.path("web/textures.wgsl"), "textures.wgsl");
    _ = web_sources.addCopyFile(web_triangle_vert_wgsl, "triangle_vert.wgsl");
    _ = web_sources.addCopyFile(web_triangle_frag_wgsl, "triangle_frag.wgsl");

    const web_module = b.createModule(.{
        .root_source_file = web_main_source,
        .target = web_target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "noapi", .module = web_noapi },
            .{ .name = "tracy", .module = web_tracy.module("tracy") },
            .{ .name = "tracy_impl", .module = web_tracy.module("tracy_impl_disabled") },
        },
    });
    const web_lib = b.addLibrary(.{
        .name = "noapi-web",
        .linkage = .static,
        .root_module = web_module,
    });
    web_lib.use_llvm = true;
    web_lib.bundle_compiler_rt = true;

    const emcc = b.addSystemCommand(&.{"emcc"});
    emcc.addArgs(&.{
        "-O2",
        "-sWASM=1",
        "--no-entry",
        "-sNO_EXIT_RUNTIME=1",
        "-sALLOW_MEMORY_GROWTH=1",
        "-sMODULARIZE=1",
        "-sEXPORT_ES6=1",
        "-sEXPORT_NAME=createNoapi",
        "-sEXPORTED_FUNCTIONS=_noapiStart,_noapiFrame,_noapiStop",
    });
    emcc.addArg("--js-library");
    emcc.addFileArg(b.path("web/noapi-webgpu.js"));
    emcc.addArtifactArg(web_lib);
    emcc.addArg("-o");
    const web_js = emcc.addOutputFileArg("noapi.js");

    const install_web_output = b.addInstallDirectory(.{
        .source_dir = web_js.dirname(),
        .install_dir = .{ .custom = "web" },
        .install_subdir = "",
    });
    install_web_output.step.dependOn(&emcc.step);
    const install_web_index = b.addInstallFile(b.path("web/index.html"), "web/index.html");
    const web_step = b.step("web", "Build the WebGPU browser examples with emcc");
    web_step.dependOn(&install_web_output.step);
    web_step.dependOn(&install_web_index.step);
}
