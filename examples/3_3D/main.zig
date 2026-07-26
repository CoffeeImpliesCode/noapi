//! 3D cube demo — first-person camera with WASD + mouse look.
//! Port of the upstream 3_3D example, simplified from Sponza glTF to a colored cube.

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

const WIDTH: u32 = 1000;
const HEIGHT: u32 = 1000;
const FRAMES_IN_FLIGHT: u5 = 3;

// Cube geometry: 6 faces × 4 verts = 24 verts, 6 faces × 6 indices = 36 indices.
const CUBE_VERTS: u32 = 24;
const CUBE_INDICES: u32 = 36;

// Per-frame data buffer layout (matches shader struct).
// std430 alignment: vec4 = 16, mat4 = 16 (column-major).
const PerFrameData = extern struct {
    positions: [CUBE_VERTS][4]f32 align(16),
    colors: [CUBE_VERTS][4]f32 align(16),
    model_to_world: [16]f32 align(16),
    world_to_view: [16]f32 align(16),
    view_to_proj: [16]f32 align(16),
};

// Cube vertex positions (centered at origin, side length 1).
const CUBE_POSITIONS: [CUBE_VERTS][4]f32 = .{
    // Front (z = +0.5)
    .{ -0.5, -0.5, 0.5, 1.0 },
    .{ 0.5, -0.5, 0.5, 1.0 },
    .{ 0.5, 0.5, 0.5, 1.0 },
    .{ -0.5, 0.5, 0.5, 1.0 },
    // Back (z = -0.5)
    .{ 0.5, -0.5, -0.5, 1.0 },
    .{ -0.5, -0.5, -0.5, 1.0 },
    .{ -0.5, 0.5, -0.5, 1.0 },
    .{ 0.5, 0.5, -0.5, 1.0 },
    // Top (y = +0.5)
    .{ -0.5, 0.5, 0.5, 1.0 },
    .{ 0.5, 0.5, 0.5, 1.0 },
    .{ 0.5, 0.5, -0.5, 1.0 },
    .{ -0.5, 0.5, -0.5, 1.0 },
    // Bottom (y = -0.5)
    .{ -0.5, -0.5, -0.5, 1.0 },
    .{ 0.5, -0.5, -0.5, 1.0 },
    .{ 0.5, -0.5, 0.5, 1.0 },
    .{ -0.5, -0.5, 0.5, 1.0 },
    // Right (x = +0.5)
    .{ 0.5, -0.5, 0.5, 1.0 },
    .{ 0.5, -0.5, -0.5, 1.0 },
    .{ 0.5, 0.5, -0.5, 1.0 },
    .{ 0.5, 0.5, 0.5, 1.0 },
    // Left (x = -0.5)
    .{ -0.5, -0.5, -0.5, 1.0 },
    .{ -0.5, -0.5, 0.5, 1.0 },
    .{ -0.5, 0.5, 0.5, 1.0 },
    .{ -0.5, 0.5, -0.5, 1.0 },
};

// Cube vertex colors (one per face, repeated 4×).
const CUBE_COLORS: [CUBE_VERTS][4]f32 = .{
    // Front: red
    .{ 1.0, 0.0, 0.0, 1.0 }, .{ 1.0, 0.0, 0.0, 1.0 }, .{ 1.0, 0.0, 0.0, 1.0 }, .{ 1.0, 0.0, 0.0, 1.0 },
    // Back: green
    .{ 0.0, 1.0, 0.0, 1.0 }, .{ 0.0, 1.0, 0.0, 1.0 }, .{ 0.0, 1.0, 0.0, 1.0 }, .{ 0.0, 1.0, 0.0, 1.0 },
    // Top: blue
    .{ 0.0, 0.0, 1.0, 1.0 }, .{ 0.0, 0.0, 1.0, 1.0 }, .{ 0.0, 0.0, 1.0, 1.0 }, .{ 0.0, 0.0, 1.0, 1.0 },
    // Bottom: yellow
    .{ 1.0, 1.0, 0.0, 1.0 }, .{ 1.0, 1.0, 0.0, 1.0 }, .{ 1.0, 1.0, 0.0, 1.0 }, .{ 1.0, 1.0, 0.0, 1.0 },
    // Right: magenta
    .{ 1.0, 0.0, 1.0, 1.0 }, .{ 1.0, 0.0, 1.0, 1.0 }, .{ 1.0, 0.0, 1.0, 1.0 }, .{ 1.0, 0.0, 1.0, 1.0 },
    // Left: cyan
    .{ 0.0, 1.0, 1.0, 1.0 }, .{ 0.0, 1.0, 1.0, 1.0 }, .{ 0.0, 1.0, 1.0, 1.0 }, .{ 0.0, 1.0, 1.0, 1.0 },
};

// Cube index buffer (2 triangles per face, 6 faces).
const CUBE_INDEX_DATA: [CUBE_INDICES]u32 = .{
    0, 1, 2, 0, 2, 3, // front
    4, 5, 6, 4, 6, 7, // back
    8, 9, 10, 8, 10, 11, // top
    12, 13, 14, 12, 14, 15, // bottom
    16, 17, 18, 16, 18, 19, // right
    20, 21, 22, 20, 22, 23, // left
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    const sdl_win = try sdl3.video.Window.init("3D Cube", @intCast(WIDTH), @intCast(HEIGHT), .{ .resizable = true });
    try sdl_win.show();
    defer sdl_win.deinit();

    // ── Vulkan loader via SDL3 ───────────────────────────
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();

    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    const exts_copy = try init.arena.allocator().dupe([*:0]const u8, sdl_exts);
    exts_copy_global = exts_copy;

    // ── Load shader SPIR-V ────────────────────────────────
    const vert_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/cube_vert.spv", gpa, .unlimited);
    defer gpa.free(vert_bytes);
    const frag_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/cube_frag.spv", gpa, .unlimited);
    defer gpa.free(frag_bytes);
    const vert_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, vert_bytes));
    const frag_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, frag_bytes));

    // ── GPU init ───────────────────────────────────────────
    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = FRAMES_IN_FLIGHT,
        .app_name = "3D Cube",
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
    var surf = try noapi.Surface.init(&gpu, surface, .{ .width = WIDTH, .height = HEIGHT });
    defer surf.deinit();

    const win_id = try sdl_win.getId();

    // ── Shaders ────────────────────────────────────────────
    const vert_shader = try gpu.shaderCreate(vert_spirv, .vertex, "main", "cube_vert");
    defer gpu.shaderDestroy(vert_shader);
    const frag_shader = try gpu.shaderCreate(frag_spirv, .fragment, "main", "cube_frag");
    defer gpu.shaderDestroy(frag_shader);

    // ── Depth texture ──────────────────────────────────────
    var depth_handle = try gpu.textureCreate(.{
        .dimensions = .{ WIDTH, HEIGHT, 1 },
        .format = .d32_float,
        .usage = .{ .sampled = false, .depth_stencil_attachment = true },
    });
    defer gpu.textureDestroy(depth_handle);
    var depth_size = [2]u32{ WIDTH, HEIGHT };

    // ── GPU buffers ────────────────────────────────────────
    // Per-frame data buffer (positions + colors + matrices).
    const frame_data_size = @sizeOf(PerFrameData);
    const frame_data_buf = try gpu.gpuMalloc(frame_data_size, 64, .default);
    defer gpu.gpuFree(frame_data_buf);

    // Index buffer.
    const idx_buf_size = @sizeOf(u32) * CUBE_INDICES;
    const idx_buf = try gpu.gpuMalloc(idx_buf_size, 64, .default);
    defer gpu.gpuFree(idx_buf);

    // Fill index buffer.
    @memcpy(idx_buf.cpu[0..idx_buf_size], std.mem.sliceAsBytes(&CUBE_INDEX_DATA));

    // ── Semaphore for frame pacing ─────────────────────────
    const frame_sem = try gpu.semaphoreCreate(0);
    defer gpu.semaphoreDestroy(frame_sem);

    // ── Camera state ───────────────────────────────────────
    var cam_pos: [3]f32 = .{ -1, 0, 0 };
    var cam_yaw: f32 = 0;
    var cam_pitch: f32 = 0;
    var mouse_dx: f32 = 0;
    var mouse_dy: f32 = 0;
    var right_click_pressed = false;

    // ── Frame pacing ───────────────────────────────────────
    var frame_counter: u64 = 0;
    var prev_ts: u64 = sdl3.timer.getPerformanceCounter();
    const ts_freq: u64 = sdl3.timer.getPerformanceFrequency();
    const max_dt: f32 = 1.0 / 10.0;

    // ── FPS counter ─────────────────────────────────────────
    var fps_timer: u64 = sdl3.timer.getPerformanceCounter();
    var fps_frames: u32 = 0;
    const fps_freq: u64 = sdl3.timer.getPerformanceFrequency();

    // ── Main loop ──────────────────────────────────────────
    var should_close = false;
    while (!should_close) {
        // ── Events ─────────────────────────────────────────
        while (sdl3.events.poll()) |ev| {
            switch (ev) {
                .quit => should_close = true,
                .window_close_requested => |we| {
                    if (we.id == win_id) should_close = true;
                },
                .key_down => |ke| {
                    if (ke.key == .escape) should_close = true;
                },
                .mouse_button_down => |me| {
                    if (me.button == .right) {
                        right_click_pressed = true;
                        try sdl3.mouse.setWindowRelativeMode(sdl_win, true);
                    }
                },
                .mouse_button_up => |me| {
                    if (me.button == .right) {
                        right_click_pressed = false;
                        try sdl3.mouse.setWindowRelativeMode(sdl_win, false);
                    }
                },
                .mouse_motion => |mm| {
                    if (right_click_pressed) {
                        mouse_dx += mm.x_rel;
                        mouse_dy -= mm.y_rel;
                    }
                },
                .window_resized => |we| {
                    if (we.id == win_id) {
                        surf.notifyResize(.{ .width = @intCast(we.width), .height = @intCast(we.height) });
                    }
                },
                else => {},
            }
        }

        // ── Begin frame ────────────────────────────────────
        _ = surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };

        const size = try sdl_win.getSizeInPixels();
        if (size.@"0" == 0 or size.@"1" == 0) {
            _ = surf.endFrame(.{ .blit_to_swapchain = true });
            continue;
        }
        const surf_w: u32 = @intCast(size.@"0");
        const surf_h: u32 = @intCast(size.@"1");

        // ── Resize depth texture if needed ─────────────────
        if (depth_size[0] != surf_w or depth_size[1] != surf_h) {
            gpu.waitIdle();
            gpu.textureDestroy(depth_handle);
            depth_handle = try gpu.textureCreate(.{
                .dimensions = .{ surf_w, surf_h, 1 },
                .format = .d32_float,
                .usage = .{ .sampled = false, .depth_stencil_attachment = true },
            });
            depth_size = .{ surf_w, surf_h };
        }

        // ── Delta time ─────────────────────────────────────
        const now_ts = sdl3.timer.getPerformanceCounter();
        const dt = @min(max_dt, @as(f32, @floatFromInt(now_ts -| prev_ts)) / @as(f32, @floatFromInt(ts_freq)));

        prev_ts = now_ts;

        // _ = dt;
        // ── Camera update ──────────────────────────────────
        const mouse_sens: f32 = 0.002;
        if (right_click_pressed) {
            cam_yaw += mouse_dx * mouse_sens;
            cam_pitch += mouse_dy * mouse_sens;
            cam_pitch = std.math.clamp(cam_pitch, -std.math.pi / 2.0 + 0.01, std.math.pi / 2.0 - 0.01);
        }
        mouse_dx = 0;
        mouse_dy = 0;

        // Keyboard movement: X=forward, Y=left, Z=up.
        const key_state = sdl3.keyboard.getState();
        var move_dir: [3]f32 = .{ 0, 0, 0 };
        if (right_click_pressed) {
            if (key_state[@intFromEnum(sdl3.Scancode.w)]) move_dir[0] += 1; // forward  +X
            if (key_state[@intFromEnum(sdl3.Scancode.s)]) move_dir[0] -= 1; // backward -X
            if (key_state[@intFromEnum(sdl3.Scancode.a)]) move_dir[1] += 1; // left     +Y
            if (key_state[@intFromEnum(sdl3.Scancode.d)]) move_dir[1] -= 1; // right    -Y
            if (key_state[@intFromEnum(sdl3.Scancode.e)]) move_dir[2] += 1; // up       +Z
            if (key_state[@intFromEnum(sdl3.Scancode.q)]) move_dir[2] -= 1; // down     -Z
        }

        // Normalize horizontal movement (XY plane).
        const horiz_len = @sqrt(move_dir[0] * move_dir[0] + move_dir[1] * move_dir[1]);
        if (horiz_len > 1.0) {
            move_dir[0] /= horiz_len;
            move_dir[1] /= horiz_len;
        }
        if (@abs(move_dir[2]) > 1.0) move_dir[2] = std.math.sign(move_dir[2]);

        // Rotate movement by camera yaw (around Z axis).
        const yaw_cos = @cos(cam_yaw);
        const yaw_sin = @sin(cam_yaw);
        const world_move: [3]f32 = .{
            move_dir[0] * yaw_cos - move_dir[1] * yaw_sin,
            move_dir[0] * yaw_sin + move_dir[1] * yaw_cos,
            move_dir[2],
        };

        const move_speed: f32 = 4.0;
        cam_pos[0] += world_move[0] * move_speed * dt;
        cam_pos[1] += world_move[1] * move_speed * dt;
        cam_pos[2] += world_move[2] * move_speed * dt;

        // ── Build view matrix ──────────────────────────────
        // Camera forward direction from yaw/pitch.
        const fwd: [3]f32 = .{
            @cos(cam_yaw) * @cos(cam_pitch),
            @sin(cam_yaw) * @cos(cam_pitch),
            @sin(cam_pitch),
        };
        const world_up: [3]f32 = .{ 0, 0, 1 };
        const right = cross3(fwd, world_up);
        const up = cross3(right, fwd);

        // View matrix: inverse of camera transform.
        // Column-major 4x4.
        var view: [16]f32 = .{
            right[0],              up[0],              -fwd[0],            0,
            right[1],              up[1],              -fwd[1],            0,
            right[2],              up[2],              -fwd[2],            0,
            -dot3(right, cam_pos), -dot3(up, cam_pos), dot3(fwd, cam_pos), 1,
        };

        // ── Build projection matrix ────────────────────────
        const aspect = @as(f32, @floatFromInt(surf_w)) / @as(f32, @floatFromInt(surf_h));
        const fov_y: f32 = std.math.pi / 3.0; // 60°
        const near_z: f32 = 0.1;
        const far_z: f32 = 100.0;
        const f = 1.0 / @tan(fov_y / 2.0);

        var proj: [16]f32 = .{
            f / aspect, 0, 0,                                    0,
            0,          f, 0,                                    0,
            0,          0, -far_z / (far_z - near_z),            -1,
            0,          0, -(far_z * near_z) / (far_z - near_z), 0,
        };

        const s: f32 = 0.3;
        const model: [16]f32 = .{
            s, 0, 0, 0,
            0, s, 0, 0,
            0, 0, s, 0,
            0, 0, 0, 1,
        };

        // ── Fill per-frame data buffer ─────────────────────
        const pfd: *PerFrameData = @ptrCast(@alignCast(frame_data_buf.cpu));
        @memcpy(&pfd.positions, &CUBE_POSITIONS);
        @memcpy(&pfd.colors, &CUBE_COLORS);
        @memcpy(&pfd.model_to_world, &model);
        @memcpy(&pfd.world_to_view, &view);
        @memcpy(&pfd.view_to_proj, &proj);

        // ── Render ─────────────────────────────────────────
        const sc = surf.currentImage();
        var cmd = surf.commandsBegin();

        cmd.beginRendering(.{
            .color_attachments = &.{
                .{
                    .texture = sc,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_color = .{ 0.2, 0.2, 0.3, 1.0 },
                },
            },
            .render_area_size = .{ surf_w, surf_h },
            .depth_attachment = .{
                .texture = depth_handle,
                .load_op = .clear,
                .store_op = .store,
                .clear_depth = 1.0,
            },
        });

        cmd.setViewport(.{ .x = 0, .y = 0, .width = @floatFromInt(surf_w), .height = @floatFromInt(surf_h) });
        cmd.setScissor(.{ .x = 0, .y = 0, .width = surf_w, .height = surf_h });
        cmd.setShaders(vert_shader, frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.setDepthState(.{ .mode = .{ .read = true, .write = true }, .compare = .less_equal });

        // Draw indexed cube: pass buffer device address via vert_data push constant.
        cmd.drawIndexed(.{ .vert_data = frame_data_buf.gpu }, idx_buf, CUBE_INDICES, 1, 0, 0);

        cmd.endRendering();

        frame_counter += 1;
        cmd.addSignalSemaphore(surf.index, frame_sem, frame_counter);

        _ = surf.endFrame(.{ .blit_to_swapchain = true });

        // Frame pacing: wait if GPU is N frames ahead.
        if (frame_counter >= FRAMES_IN_FLIGHT) {
            gpu.semaphoreWait(frame_sem, frame_counter - FRAMES_IN_FLIGHT + 1);
        }

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

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn dot4(a: [4]f32, b: [4]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

fn neg3(a: [3]f32) [3]f32 {
    return .{ -a[0], -a[1], -a[2] };
}

fn neg4(a: [4]f32) [4]f32 {
    return .{ -a[0], -a[1], -a[2], -a[3] };
}

var exts_copy_global: []const [*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_copy_global;
}
