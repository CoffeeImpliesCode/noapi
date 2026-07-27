//! 1_triangle — minimal triangle demo.
//! Port of the upstream 1_triangle Odin example.
//! Uses hardcoded vertex shader (triangle_vert.spv) — no vertex buffers needed.

const std = @import("std");
const common = @import("common");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
const Io = std.Io;
pub const tracy_impl = common.tracy_impl;
pub const tracy = common.tracy;
pub const tracy_options = common.tracy_options;

const start_width = 1000;
const start_height = 1000;
const frames_in_flight = 3;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var app = try common.platformInit("1_triangle", start_width, start_height, frames_in_flight, io, gpa);
    defer app.deinit();
    try app.sdl_win.show();
    const win_id = try app.sdl_win.getId();

    // ── Shaders ────────────────────────────────────────────
    const vert_shader = try noapi.Shader.createFromPath(gpa, io, &app.gpu, "shaders/triangle_vert.spv", .vertex, "main", "triangle_vert");
    defer vert_shader.destroy();
    const frag_shader = try noapi.Shader.createFromPath(gpa, io, &app.gpu, "shaders/triangle_frag.spv", .fragment, "main", "triangle_frag");
    defer frag_shader.destroy();

    // ── Timing ─────────────────────────────────────────────
    const ts_freq = sdl3.timer.getPerformanceFrequency();
    var now_ts = sdl3.timer.getPerformanceCounter();
    var t: f32 = 0;

    // ── FPS counter ─────────────────────────────────────────
    var fps_timer: u64 = sdl3.timer.getPerformanceCounter();
    var fps_frames: u32 = 0;
    const fps_freq: u64 = sdl3.timer.getPerformanceFrequency();

    // ── Render loop ────────────────────────────────────────
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
                    if (we.id == win_id) app.surf.notifyResize(.{ .width = @intCast(we.width), .height = @intCast(we.height) });
                },
                else => {},
            }
        }

        // Skip if minimized
        const flags = app.sdl_win.getFlags();
        if (flags.minimized) {
            sdl3.timer.delayMilliseconds(16);
            continue;
        }

        // ── Delta time ─────────────────────────────────────
        const last_ts = now_ts;
        now_ts = sdl3.timer.getPerformanceCounter();
        const dt_numer: f64 = @floatFromInt(now_ts - last_ts);
        const dt_denom: f64 = @floatFromInt(ts_freq);
        const delta: f32 = @floatCast(dt_numer / dt_denom);
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
        _ = app.surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };

        const surface_size = app.surf.surfaceSize();
        var cmd = app.surf.commandsBegin();

        const sc = app.surf.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = clear_color },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setShaders(vert_shader, frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.draw(.{}, 3, 1);

        cmd.endRendering();

        _ = try app.surf.endFrame(.{ .blit_to_swapchain = true });

        // ── FPS output ──────────────────────────────────────
        fps_frames += 1;
        if (fps_frames == 60) {
            const now = sdl3.timer.getPerformanceCounter();
            const elapsed_ns = now - fps_timer;
            const fps_numer: f64 = @floatFromInt(fps_freq * fps_frames);
            const fps_denom: f64 = @floatFromInt(elapsed_ns);
            const fps = fps_numer / fps_denom;
            const ms = fps_denom / fps_numer * 1000.0;
            std.debug.print("FPS: {d:.1}  frame: {d:.2}ms\n", .{ fps, ms });
            fps_timer = now;
            fps_frames = 0;
        }
    }

    try app.gpu.waitIdle();
}
