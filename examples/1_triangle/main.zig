//! 1_triangle — minimal triangle demo.
//! Port of the upstream 1_triangle Odin example.
//! Uses hardcoded vertex shader (triangle_vert.spv) — no vertex buffers needed.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
const Io = std.Io;

const start_width = 1000;
const start_height = 1000;
const frames_in_flight = 3;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    const sdl_win = try sdl3.video.Window.init("Triangle", start_width, start_height, .{
        .resizable = true,
        .high_pixel_density = true,
    });
    try sdl_win.show();

    // ── Vulkan loader via SDL3 ───────────────────────────
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();

    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    const exts_copy = try init.arena.allocator().dupe([*:0]const u8, sdl_exts);
    exts_copy_global = exts_copy;

    // ── Load shader SPIR-V ────────────────────────────────
    const vert_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/triangle_vert.spv", gpa, .unlimited);
    defer gpa.free(vert_bytes);
    const frag_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/triangle_frag.spv", gpa, .unlimited);
    defer gpa.free(frag_bytes);
    const vert_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, vert_bytes));
    const frag_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, frag_bytes));

    // ── GPU init ───────────────────────────────────────────
    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = frames_in_flight,
        .app_name = "1_triangle",
        .validation = true,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &getExts,
        },
        .io = io,
        .allocator = gpa,
    });
    defer gpu.deinit();

    // ── Surface ────────────────────────────────────────────
    const sdl_surface = try sdl3.vulkan.Surface.init(sdl_win, @ptrFromInt(@intFromEnum(gpu.instanceHandle())), null);
    const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
    var surf = try noapi.Surface.init(&gpu, surface, .{ .width = start_width, .height = start_height });
    defer surf.deinit();

    // ── Shaders ────────────────────────────────────────────
    const vert_shader = try gpu.shaderCreate(vert_spirv, .vertex, "main", "triangle_vert");
    defer gpu.shaderDestroy(vert_shader);
    const frag_shader = try gpu.shaderCreate(frag_spirv, .fragment, "main", "triangle_frag");
    defer gpu.shaderDestroy(frag_shader);

    // ── Timing ─────────────────────────────────────────────
    const ts_freq = sdl3.timer.getPerformanceFrequency();
    var now_ts = sdl3.timer.getPerformanceCounter();
    var t: f32 = 0;

    // ── FPS counter ─────────────────────────────────────────
    var fps_timer: u64 = sdl3.timer.getPerformanceCounter();
    var fps_frames: u32 = 0;
    const fps_freq: u64 = sdl3.timer.getPerformanceFrequency();

    // ── Render loop ────────────────────────────────────────
    const win_id = try sdl_win.getId();
    var should_close = false;
    while (!should_close) {
        // Event handling
        while (sdl3.events.poll()) |ev| {
            switch (ev) {
                .quit => should_close = true,
                .window_close_requested => |we| {
                    if (we.id == win_id) should_close = true;
                },
                .key_down => |ke| {
                    if (ke.key == .escape) should_close = true;
                },
                .window_resized => |we| {
                    if (we.id == win_id) surf.notifyResize(.{ .width = @intCast(we.width), .height = @intCast(we.height) });
                },
                else => {},
            }
        }

        // Skip if minimized
        const flags = sdl_win.getFlags();
        if (flags.minimized) {
            sdl3.timer.delayMilliseconds(16);
            continue;
        }

        // ── Delta time ─────────────────────────────────────
        const last_ts = now_ts;
        now_ts = sdl3.timer.getPerformanceCounter();
        const delta = @as(f32, @floatCast(@as(f64, @floatFromInt(now_ts - last_ts)) / @as(f64, @floatFromInt(ts_freq))));
        const max_dt: f32 = 1.0 / 10.0;
        const dt = @min(max_dt, delta);

        // ── Animated clear color ────────────────────────────
        t = @mod(t + dt * 1.7, std.math.pi * 2);
        const sin_t = @sin(t) * 0.5 + 0.5;
        const clear_color: [4]f32 = .{
            0.2 + sin_t * 0.2,
            0.2 + sin_t * 0.2,
            0.2 + sin_t * 0.2,
            1.0,
        };

        // ── Render frame ────────────────────────────────────
        _ = surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };

        const surface_size = surf.surfaceSize();
        var cmd = surf.commandsBegin();

        const sc = surf.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = clear_color },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setShaders(vert_shader, frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.draw(noapi.PushData{}, 3, 1);

        cmd.endRendering();

        _ = surf.endFrame(.{ .blit_to_swapchain = true });

        // ── FPS output ──────────────────────────────────────
        fps_frames += 1;
        if (fps_frames == 60) {
            const now = sdl3.timer.getPerformanceCounter();
            const elapsed_ns = now - fps_timer;
            const fps = @as(f64, @floatFromInt(fps_freq * fps_frames)) / @as(f64, @floatFromInt(elapsed_ns));
            const ms = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(fps_freq * fps_frames)) * 1000.0;
            std.debug.print("FPS: {d:.1}  frame: {d:.2}ms\n", .{ fps, ms });
            fps_timer = now;
            fps_frames = 0;
        }
    }

    gpu.waitIdle();
}

var exts_copy_global: []const [*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_copy_global;
}
