//! Indirect triangles example.
//! Demonstrates cmdDrawIndexedIndirect and cmdDrawIndexedIndirectMulti.
//! Renders 32 animated triangles arranged in a circle using indirect draw commands.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
const Io = std.Io;
pub const tracy_impl = @import("tracy_impl");
pub const tracy = @import("tracy");
pub const tracy_options: tracy.Options = .{
    .on_demand = false,
    .no_broadcast = false,
    .only_localhost = false,
    .only_ipv4 = false,
    .delayed_init = false,
    .manual_lifetime = false,
};

const num_triangles: u32 = 32;
const window_width: u32 = 1000;
const window_height: u32 = 1000;
const frames_in_flight: u5 = 3;

// Per-draw data that follows DrawIndexedIndirectCommand in the indirect buffer.
const PerDrawData = extern struct {
    color: [3]f32,
    pos: [3]f32,
    size: f32,
};

// Full indirect draw entry: command + per-draw data.
// Must match the shader's DrawCommand struct layout.
const IndirectDraw = extern struct {
    cmd: noapi.DrawIndexedIndirectCommand,
    data: PerDrawData,
};

// Vertex data struct: pointer to vertex array (matches shader's VertexData).
const VertexData = extern struct {
    verts: u64,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    const sdl_win = try sdl3.video.Window.init("Indirect Triangles", window_width, window_height, .{ .resizable = true });
    try sdl_win.show();

    // ── Vulkan loader via SDL3 ───────────────────────────
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();

    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    const exts_copy = try init.arena.allocator().dupe([*:0]const u8, sdl_exts);
    exts_copy_global = exts_copy;

    // ── GPU init ───────────────────────────────────────────
    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = frames_in_flight,
        .app_name = "Indirect Triangles",
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
    var surf = try noapi.Surface.init(&gpu, surface, .{ .extent = .{ .width = window_width, .height = window_height } });
    defer surf.deinit();

    // ── Shaders ────────────────────────────────────────────
    const vert_shader = try noapi.Shader.createFromPath(gpa, io, &gpu, "shaders/indirect_tri_vert.spv", .vertex, "main", "indirect_tri_vert");
    defer vert_shader.destroy();
    const frag_shader = try noapi.Shader.createFromPath(gpa, io, &gpu, "shaders/indirect_tri_frag.spv", .fragment, "main", "indirect_tri_frag");
    defer frag_shader.destroy();

    // ── Vertex buffer (single triangle shared by all draws) ─
    const vert_buf = try gpu.gpuMalloc(@sizeOf([3]f32) * 3, 16, .default);
    defer gpu.gpuFree(vert_buf);
    const verts: [*][3]f32 = @ptrCast(@alignCast(vert_buf.cpu));
    verts[0] = .{ -0.5, 0.5, 0.0 };
    verts[1] = .{ 0.0, -0.5, 0.0 };
    verts[2] = .{ 0.5, 0.5, 0.0 };

    // ── Vertex data struct (pointer to vertex array) ───────
    const vert_data_buf = try gpu.gpuMalloc(@sizeOf(VertexData), 8, .default);
    defer gpu.gpuFree(vert_data_buf);
    const vert_data_ptr: *VertexData = @ptrCast(@alignCast(vert_data_buf.cpu));
    vert_data_ptr.* = .{ .verts = vert_buf.gpu };

    // ── Index buffer ───────────────────────────────────────
    const idx_buf = try gpu.gpuMalloc(@sizeOf(u32) * 3, 4, .default);
    defer gpu.gpuFree(idx_buf);
    const indices: [*]u32 = @ptrCast(@alignCast(idx_buf.cpu));
    indices[0] = 0;
    indices[1] = 2;
    indices[2] = 1;

    // ── Indirect data buffer (32 draws with per-draw data) ─
    const indirect_buf = try gpu.gpuMalloc(@sizeOf(IndirectDraw) * num_triangles, 16, .default);
    defer gpu.gpuFree(indirect_buf);
    const indirect_draws: [*]IndirectDraw = @ptrCast(@alignCast(indirect_buf.cpu));

    // ── Count buffer (separate buffer for draw count) ──────
    const draw_count_buf = try gpu.gpuMalloc(4, 4, .default);
    defer gpu.gpuFree(draw_count_buf);
    @as(*u32, @ptrCast(@alignCast(draw_count_buf.cpu))).* = num_triangles;

    const circle_radius: f32 = 0.6;
    for (0..num_triangles) |i| {
        const angle = @as(f32, @floatFromInt(i)) / @as(f32, num_triangles) * std.math.pi * 2.0;
        const x = @cos(angle) * circle_radius;
        const y = @sin(angle) * circle_radius;

        // HSL → RGB
        const hue = angle / (std.math.pi * 2.0);
        const rgb = hslToRgb(hue, 1.0, 0.5);

        indirect_draws[i] = .{
            .cmd = .{
                .index_count = 3,
                .instance_count = 1,
                .first_index = 0,
                .vertex_offset = 0,
                .first_instance = 0,
            },
            .data = .{
                .color = rgb,
                .pos = .{ x, y, 0.0 },
                .size = 0.1,
            },
        };
    }

    // ── Count buffer (for multi-draw) ──────────────────────
    const count_buf = try gpu.gpuMalloc(@sizeOf(u32), 4, .default);
    defer gpu.gpuFree(count_buf);
    const count_ptr: *u32 = @ptrCast(@alignCast(count_buf.cpu));
    count_ptr.* = num_triangles;

    // ── Semaphore for frame pacing ─────────────────────────
    const frame_sem = try gpu.semaphoreCreate(0);
    defer gpu.semaphoreDestroy(frame_sem);

    // ── Main loop ──────────────────────────────────────────
    // ── FPS counter ─────────────────────────────────────────
    var fps_timer: u64 = sdl3.timer.getPerformanceCounter();
    var fps_frames: u32 = 0;
    const fps_freq: u64 = sdl3.timer.getPerformanceFrequency();
    var next_frame: u64 = 1;
    var time_sec: f32 = 0;
    var should_close = false;

    while (!should_close) {
        // Handle events
        while (sdl3.events.poll()) |ev| {
            switch (ev) {
                .quit => should_close = true,
                .window_close_requested => |we| {
                    if (we.id == try sdl_win.getId()) should_close = true;
                },
                .key_down => |ke| {
                    if (ke.key == .escape) should_close = true;
                },
                .window_resized => |we| {
                    surf.notifyResize(.{ .width = @intCast(we.width), .height = @intCast(we.height) });
                },
                else => {},
            }
        }
        if (should_close) break;

        // Frame pacing
        if (next_frame > frames_in_flight) {
            try gpu.semaphoreWait(frame_sem, next_frame - frames_in_flight);
        }

        // Begin frame
        const schedule = surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };
        _ = schedule;

        time_sec += 1.0 / 60.0;
        const surface_size = surf.surfaceSize();

        // Animate: rotate triangles around the circle
        const rotation = time_sec * 0.5;
        for (0..num_triangles) |i| {
            const angle = @as(f32, @floatFromInt(i)) / @as(f32, num_triangles) * std.math.pi * 2.0 + rotation;
            const x = @cos(angle) * circle_radius;
            const y = @sin(angle) * circle_radius;
            indirect_draws[i].data.pos = .{ x, y, 0.0 };
        }

        // Record commands
        var cmd = surf.commandsBegin();
        const sc = surf.currentImage();

        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{
                0.1 + @sin(time_sec * 0.5) * 0.05,
                0.1 + @cos(time_sec * 0.7) * 0.05,
                0.2 + @sin(time_sec * 0.3) * 0.05,
                1.0,
            } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setShaders(vert_shader, frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });

        // Set vertex input: one binding with position (vec3)
        cmd.setVertexInput(&.{.{ .binding = 0, .stride = @sizeOf([3]f32), .input_rate = 0 }}, &.{
            .{ .location = 0, .binding = 0, .format = @intFromEnum(vk.Format.r32g32b32_sfloat), .offset = 0 },
        });
        cmd.bindVertexBuffer(0, vert_buf, 0);

        // Push constants: vert_data = pointer to VertexData, indirect = pointer to indirect buffer
        const push: noapi.PushData = .{
            .vert_data = vert_data_buf.gpu,
            .indirect = indirect_buf.gpu,
        };

        // Draw 32 triangles using indirect multi-draw
        // stride = @sizeOf(IndirectDraw) so the GPU skips per-draw data between commands
        cmd.drawIndexedIndirectMulti(push, idx_buf, indirect_buf, @sizeOf(IndirectDraw), draw_count_buf, 0, num_triangles);

        cmd.endRendering();

        // Signal semaphore and present
        cmd.addSignalSemaphore(surf.index, frame_sem, next_frame);
        _ = try surf.endFrame(.{ .blit_to_swapchain = true });
        next_frame += 1;

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

    try gpu.waitIdle();
}

// Convert HSL to RGB (hue: 0-1, saturation: 0-1, lightness: 0-1)
fn hslToRgb(h: f32, s: f32, l: f32) [3]f32 {
    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const x = c * (1.0 - @abs(@mod(h * 6.0, 2.0) - 1.0));
    const m = l - c / 2.0;

    const rgb = if (h < 1.0 / 6.0)
        .{ c, x, 0.0 }
    else if (h < 2.0 / 6.0)
        .{ x, c, 0.0 }
    else if (h < 3.0 / 6.0)
        .{ 0.0, c, x }
    else if (h < 4.0 / 6.0)
        .{ 0.0, x, c }
    else if (h < 5.0 / 6.0)
        .{ x, 0.0, c }
    else
        .{ c, 0.0, x };

    return .{ rgb[0] + m, rgb[1] + m, rgb[2] + m };
}

var exts_copy_global: []const [*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_copy_global;
}
