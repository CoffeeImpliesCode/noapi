//! 3D textures advanced example — procedural cloud volume with FBM noise.
//! Demonstrates 3D texture creation, upload, and volume raymarching.
//! No external assets required.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
const DescriptorPool = noapi.DescriptorPool;
const Io = std.Io;

const volume_res: u32 = 128;
const window_width: u32 = 1000;
const window_height: u32 = 1000;

var exts_copy_global: []const [*:0]const u8 = &.{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    const sdl_win = try sdl3.video.Window.init("Textures (Advanced) — 3D Volume", window_width, window_height, .{ .resizable = true });
    try sdl_win.show();

    // ── Vulkan loader via SDL3 ───────────────────────────
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();

    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    const exts_copy = try init.arena.allocator().dupe([*:0]const u8, sdl_exts);
    exts_copy_global = exts_copy;

    // ── Load shader SPIR-V ────────────────────────────────
    const cloud_vert_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/cloud_vert.spv", gpa, .unlimited);
    defer gpa.free(cloud_vert_bytes);
    const cloud_frag_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/cloud_frag.spv", gpa, .unlimited);
    defer gpa.free(cloud_frag_bytes);
    const cloud_vert_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, cloud_vert_bytes));
    const cloud_frag_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, cloud_frag_bytes));

    // ── GPU init ───────────────────────────────────────────
    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 2,
        .app_name = "noapi textures_advanced",
        .validation = true,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &struct {
                fn getExts() []const [*:0]const u8 {
                    return exts_copy_global;
                }
            }.getExts,
        },
        .io = io,
        .allocator = gpa,
    });
    defer gpu.deinit();

    // ── Window surface ────────────────────────────────────
    const sdl_surface = try sdl3.vulkan.Surface.init(sdl_win, @ptrFromInt(@intFromEnum(gpu.instanceHandle())), null);
    const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
    var surf = try noapi.Surface.init(&gpu, surface, .{ .width = window_width, .height = window_height });
    defer surf.deinit();

    // ── Shaders ────────────────────────────────────────────
    const cloud_vert = try gpu.shaderCreate(cloud_vert_spirv, .vertex, "main", "cloud_vert");
    defer gpu.shaderDestroy(cloud_vert);
    const cloud_frag = try gpu.shaderCreate(cloud_frag_spirv, .fragment, "main", "cloud_frag");
    defer gpu.shaderDestroy(cloud_frag);

    // ── 3D cloud texture ──────────────────────────────────
    // Generate procedural FBM noise volume on CPU
    const volume_bytes = volume_res * volume_res * volume_res;
    const cloud_data = try gpa.alloc(u8, volume_bytes);
    defer gpa.free(cloud_data);
    generateCloudVolume(cloud_data);

    // Create 3D texture on GPU
    var cloud_tex = try noapi.Texture.OwnedTexture.allocAndCreate(&gpu, .{
        .type = .@"3d",
        .dimensions = .{ volume_res, volume_res, volume_res },
        .format = .r8_unorm,
        .usage = .{ .sampled = true },
    });
    defer cloud_tex.freeAndDestroy();

    // Upload cloud data via staging buffer
    {
        const staging = try gpu.gpuMalloc(volume_bytes, 16, .default);
        defer gpu.gpuFree(staging);
        @memcpy(staging.cpu[0..volume_bytes], cloud_data);

        var cmd = try gpu.commandsBegin();
        cmd.copyToTexture(cloud_tex.texture, staging, .{
            .size = .{ volume_res, volume_res, volume_res },
            .layer_count = 1,
        });
        cmd.barrier(.{ .transfer = true }, .{ .fragment = true }, .{});
        // Submit and wait for upload to complete
        // queueSubmit internally ends the CB, then submits
        gpu.queueSubmit(&.{cmd});
        gpu.waitIdle();
    }

    // ── Descriptor pool ────────────────────────────────────
    var pool = try DescriptorPool.init(&gpu, 1, 0, 1);
    defer pool.deinit();

    _ = pool.allocTexture(cloud_tex.texture.handle, gpu.samplerDescriptor(.{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mip_filter = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
    }), .@"3d");

    // ── Render loop ────────────────────────────────────────
    const win_id = try sdl_win.getId();
    var should_close = false;
    var time_sec: f32 = 0;
    var sem_val: u64 = 0;
    const test_sem = try gpu.semaphoreCreate(0);
    defer gpu.semaphoreDestroy(test_sem);

    // ── FPS counter ─────────────────────────────────────────
    var fps_timer: u64 = sdl3.timer.getPerformanceCounter();
    var fps_frames: u32 = 0;
    const fps_freq: u64 = sdl3.timer.getPerformanceFrequency();

    while (!should_close) {
        // Process events
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

        time_sec += 1.0 / 60.0;
        _ = surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };

        const surface_size = surf.surfaceSize();
        var cmd = surf.commandsBegin();

        const sc = surf.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{ 0.05, 0.05, 0.1, 1.0 } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        // Orbit camera around the cloud (Z-up: XY horizontal, Z vertical)
        const radius: f32 = 2.5;
        const cam_x = @sin(time_sec * 0.3) * radius;
        const cam_y = @cos(time_sec * 0.3) * radius;
        const cam_z = @sin(time_sec * 0.15) * 0.5;

        // Pack push constant data: cloud_texture=0, cloud_sampler=0, camera_pos
        const CloudPushData = extern struct {
            cloud_texture: u32,
            cloud_sampler: u32,
            camera_x: f32,
            camera_y: f32,
            camera_z: f32,
            _pad: u32,
        };
        const push_data = CloudPushData{
            .cloud_texture = 0,
            .cloud_sampler = 0,
            .camera_x = cam_x,
            .camera_y = cam_y,
            .camera_z = cam_z,
            ._pad = 0,
        };
        const push: noapi.PushData = @bitCast(push_data);

        cmd.setViewport(.{ .x = 0, .y = 0, .width = @floatFromInt(surface_size.width), .height = @floatFromInt(surface_size.height) });
        cmd.setScissor(.{ .x = 0, .y = 0, .width = surface_size.width, .height = surface_size.height });
        cmd.setShaders(cloud_vert, cloud_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .back });
        cmd.setBlendState(.{
            .enable = true,
            .color_op = .add,
            .src_color_factor = .src_alpha,
            .dst_color_factor = .one_minus_src_alpha,
            .alpha_op = .add,
            .src_alpha_factor = .one,
            .dst_alpha_factor = .one_minus_src_alpha,
        });
        cmd.bindDescriptorSets(pool.heap);
        cmd.draw(push, 36, 1);

        cmd.endRendering();

        sem_val += 1;
        cmd.addWaitSemaphore(surf.index, test_sem, sem_val - 1);
        cmd.addSignalSemaphore(surf.index, test_sem, sem_val);

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

/// Generate a 128×128×128 cloud volume using FBM value noise.
fn generateCloudVolume(data: []u8) void {
    const size: usize = @intCast(volume_res);
    const inv: f32 = 1.0 / @as(f32, @floatFromInt(size - 1));

    for (0..size) |z| {
        for (0..size) |y| {
            for (0..size) |x| {
                const nx = @as(f32, @floatFromInt(x)) * inv;
                const ny = @as(f32, @floatFromInt(y)) * inv;
                const nz = @as(f32, @floatFromInt(z)) * inv;

                // FBM noise shaped into cloud density
                const n = fbm(nx * 3.0, ny * 3.0, nz * 3.0);
                const density = @max(0.0, @min(1.0, (n - 0.35) * 1.8));

                const idx = x + y * size + z * size * size;
                data[idx] = @intFromFloat(density * 255.0);
            }
        }
    }
}

fn smooth(t: f32) f32 {
    return 3.0 * t * t - 2.0 * t * t * t;
}

fn hash3(x: i32, y: i32, z: i32) f32 {
    var h: u32 = @as(u32, @intCast(x)) *% 73856093 ^
        @as(u32, @intCast(y)) *% 19349663 ^
        @as(u32, @intCast(z)) *% 83492791;
    h ^= h >> 13;
    h *%= 0x85ebca6b;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

fn valueNoise(x: f32, y: f32, z: f32) f32 {
    const xi = @as(i32, @intFromFloat(@floor(x)));
    const yi = @as(i32, @intFromFloat(@floor(y)));
    const zi = @as(i32, @intFromFloat(@floor(z)));

    const xf = smooth(x - @as(f32, @floatFromInt(xi)));
    const yf = smooth(y - @as(f32, @floatFromInt(yi)));
    const zf = smooth(z - @as(f32, @floatFromInt(zi)));

    const c000 = hash3(xi + 0, yi + 0, zi + 0);
    const c100 = hash3(xi + 1, yi + 0, zi + 0);
    const c010 = hash3(xi + 0, yi + 1, zi + 0);
    const c110 = hash3(xi + 1, yi + 1, zi + 0);
    const c001 = hash3(xi + 0, yi + 0, zi + 1);
    const c101 = hash3(xi + 1, yi + 0, zi + 1);
    const c011 = hash3(xi + 0, yi + 1, zi + 1);
    const c111 = hash3(xi + 1, yi + 1, zi + 1);

    const x00 = lerp(c000, c100, xf);
    const x10 = lerp(c010, c110, xf);
    const x01 = lerp(c001, c101, xf);
    const x11 = lerp(c011, c111, xf);

    const y0 = lerp(x00, x10, yf);
    const y1 = lerp(x01, x11, yf);

    return lerp(y0, y1, zf);
}

fn fbm(x: f32, y: f32, z: f32) f32 {
    var v: f32 = 0.0;
    var amp: f32 = 0.5;
    var freq: f32 = 1.0;
    const damping: f32 = 0.6;
    const freq_growth: f32 = 2.3;

    comptime var i = 0;
    inline while (i < 4) : (i += 1) {
        v += amp * valueNoise(x * freq, y * freq, z * freq);
        amp *= damping;
        freq *= freq_growth;
    }

    return v;
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
