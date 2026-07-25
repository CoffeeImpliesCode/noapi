//! 2_textures example — procedural checkerboard textures with cross-fade.
//! Port of the upstream no_gfx_api 2_textures example.
//! Generates two procedural checkerboard textures and renders a quad
//! with a time-varying lerp between them.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
const Io = std.Io;

const TEX_SIZE: u32 = 256;
const CHECKER_SIZE: u32 = 32;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    const sdl_win = try sdl3.video.Window.init("noapi — 2_textures", 800, 600, .{ .resizable = true });
    try sdl_win.show();

    // ── Vulkan loader via SDL3 ───────────────────────────
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();

    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    const exts_copy = try init.arena.allocator().dupe([*:0]const u8, sdl_exts);
    exts_copy_global = exts_copy;

    // ── Load shader SPIR-V ────────────────────────────────
    const vert_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/tex_vert.spv", gpa, .unlimited);
    defer gpa.free(vert_bytes);
    const frag_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/tex_frag.spv", gpa, .unlimited);
    defer gpa.free(frag_bytes);
    const vert_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, vert_bytes));
    const frag_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, frag_bytes));

    // ── GPU init ───────────────────────────────────────────
    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 2,
        .app_name = "noapi 2_textures",
        .validation = true,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &getExts,
        },
        .io = io,
        .allocator = gpa,
    });
    defer gpu.deinit();

    // ── Window + surface ──────────────────────────────────
    const sdl_surface = try sdl3.vulkan.Surface.init(sdl_win, @ptrFromInt(@intFromEnum(gpu.instanceHandle())), null);
    const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
    var surf = try noapi.Surface.init(&gpu, surface, .{ .width = 800, .height = 600 });
    defer surf.deinit();

    win_id = try sdl_win.getId();

    // ── Shaders ────────────────────────────────────────────
    const vert_shader = try gpu.shaderCreate(vert_spirv, .vertex, "main", "tex_vert");
    defer gpu.shaderDestroy(vert_shader);
    const frag_shader = try gpu.shaderCreate(frag_spirv, .fragment, "main", "tex_frag");
    defer gpu.shaderDestroy(frag_shader);

    // ── Vertex + index data ────────────────────────────────
    // Quad: 4 vertices (position: vec2, uv: vec2), 6 indices
    const Vertex = extern struct { pos: [2]f32, uv: [2]f32 };
    const VERTEX_STRIDE = @sizeOf(Vertex);

    const vert_buf = try gpu.gpuMalloc(VERTEX_STRIDE * 4, 64, .default);
    defer gpu.gpuFree(vert_buf);

    const verts: [*]Vertex = @ptrCast(@alignCast(vert_buf.cpu));
    verts[0] = .{ .pos = .{ -0.5, 0.5 }, .uv = .{ 0.0, 0.0 } };
    verts[1] = .{ .pos = .{ 0.5, -0.5 }, .uv = .{ 1.0, 1.0 } };
    verts[2] = .{ .pos = .{ 0.5, 0.5 }, .uv = .{ 1.0, 0.0 } };
    verts[3] = .{ .pos = .{ -0.5, -0.5 }, .uv = .{ 0.0, 1.0 } };

    const idx_buf = try gpu.gpuMalloc(@sizeOf(u32) * 6, 16, .default);
    defer gpu.gpuFree(idx_buf);

    const indices: [*]u32 = @ptrCast(@alignCast(idx_buf.cpu));
    indices[0] = 0;
    indices[1] = 2;
    indices[2] = 1;
    indices[3] = 0;
    indices[4] = 1;
    indices[5] = 3;

    // ── Procedural textures ────────────────────────────────
    // Generate two checkerboard patterns in CPU memory
    const pixel_count = TEX_SIZE * TEX_SIZE;
    const tex_bytes = pixel_count * 4; // RGBA8

    const pixels_a = try gpa.alloc(u8, tex_bytes);
    defer gpa.free(pixels_a);
    const pixels_b = try gpa.alloc(u8, tex_bytes);
    defer gpa.free(pixels_b);

    generateCheckerboard(pixels_a, TEX_SIZE, CHECKER_SIZE,
        .{ 255, 128, 0, 255 },   // orange
        .{ 0, 128, 255, 255 }    // blue
    );
    generateCheckerboard(pixels_b, TEX_SIZE, CHECKER_SIZE / 2,
        .{ 0, 200, 100, 255 },   // green
        .{ 200, 0, 200, 255 }    // magenta
    );

    // Staging buffers for texture upload
    const staging_a = try gpu.gpuMalloc(tex_bytes, 64, .default);
    defer gpu.gpuFree(staging_a);
    @memcpy(staging_a.cpu[0..tex_bytes], pixels_a);

    const staging_b = try gpu.gpuMalloc(tex_bytes, 64, .default);
    defer gpu.gpuFree(staging_b);
    @memcpy(staging_b.cpu[0..tex_bytes], pixels_b);

    // Create GPU textures
    const tex_desc = noapi.TextureDesc{
        .dimensions = .{ TEX_SIZE, TEX_SIZE, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    };
    var tex_a = try noapi.Texture.create(&gpu, tex_desc);
    defer tex_a.destroy();
    var tex_b = try noapi.Texture.create(&gpu, tex_desc);
    defer tex_b.destroy();

    // ── Render state ───────────────────────────────────────
    const bindings = [_]noapi.VertexBinding{
        .{ .binding = 0, .stride = VERTEX_STRIDE, .input_rate = 0 },
    };
    const attribs = [_]noapi.VertexAttribute{
        .{ .location = 0, .binding = 0, .format = @intFromEnum(vk.Format.r32g32_sfloat), .offset = @offsetOf(Vertex, "pos") },
        .{ .location = 1, .binding = 0, .format = @intFromEnum(vk.Format.r32g32_sfloat), .offset = @offsetOf(Vertex, "uv") },
    };

    // ── Main loop ──────────────────────────────────────────
    var textures_uploaded = false;
    var fade: f32 = 0;
    // ── FPS counter ─────────────────────────────────────────
    var fps_timer: u64 = sdl3.timer.getPerformanceCounter();
    var fps_frames: u32 = 0;
    const fps_freq: u64 = sdl3.timer.getPerformanceFrequency();

    while (true) {
        // Event handling
        var should_close = false;
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
        if (should_close) break;

        const schedule = surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };
        _ = schedule;

        const surface_size = surf.surfaceSize();
        if (surface_size.width == 0 or surface_size.height == 0) {
            sdl3.timer.delayMilliseconds(16);
            continue;
        }

        var cmd = surf.commandsBegin();

        // Upload textures on first frame
        if (!textures_uploaded) {
            const region = noapi.TextureRegion{
                .size = .{ TEX_SIZE, TEX_SIZE, 1 },
            };
            cmd.copyToTexture(tex_a, staging_a, region);
            cmd.copyToTexture(tex_b, staging_b, region);
            cmd.barrier(.{ .transfer = true }, .{ .fragment = true }, .{});
            textures_uploaded = true;
        }

        // Animate fade
        fade += 0.02;
        if (fade > 1.0) fade = 0;

        // Render
        const sc = surf.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{ 0.3, 0.3, 0.3, 1.0 } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setShaders(vert_shader, frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.setVertexInput(&bindings, &attribs);
        cmd.bindVertexBuffer(0, vert_buf, 0);

        // Bind textures via new high-level API
        cmd.bindTexture(0, tex_a.handle, .{ .min_filter = .linear, .mag_filter = .linear, .mip_filter = .linear });
        cmd.bindTexture(1, tex_b.handle, .{ .min_filter = .linear, .mag_filter = .linear, .mip_filter = .linear });

        // Pack fragment data into push constants:
        //   frag_data: tex_a(u32) | tex_b(u32 << 32)
        //   indirect:  sampler_idx(u32) | fade(f32 bitcast << 32)
        const fade_bits: u32 = @bitCast(fade);
        const frag_data: u64 = (@as(u64, 1) << 32) | 0; // tex_b=1, tex_a=0
        const indirect: u64 = (@as(u64, fade_bits) << 32) | 0; // sampler=0
        const push = noapi.PushData{
            .vert_data = 0,
            .frag_data = frag_data,
            .indirect = indirect,
        };
        cmd.draw(push, 6, 1);

        cmd.endRendering();
        cmd.deinitTexHeap();

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

fn generateCheckerboard(pixels: []u8, tex_size: u32, checker_size: u32, color_a: [4]u8, color_b: [4]u8) void {
    for (0..tex_size) |y| {
        for (0..tex_size) |x| {
            const cx = @divTrunc(x, checker_size);
            const cy = @divTrunc(y, checker_size);
            const is_a = (cx + cy) % 2 == 0;
            const color = if (is_a) color_a else color_b;
            const idx = (y * tex_size + x) * 4;
            pixels[idx + 0] = color[0];
            pixels[idx + 1] = color[1];
            pixels[idx + 2] = color[2];
            pixels[idx + 3] = color[3];
        }
    }
}

var exts_copy_global: []const [*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_copy_global;
}

var win_id: u32 = 0;
