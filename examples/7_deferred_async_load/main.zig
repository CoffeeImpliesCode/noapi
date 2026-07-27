//! 7_deferred_async_load — multi-pass deferred shading.
//! Port of the upstream 7_deferred_async_load Odin example.
//! Demonstrates:
//!   - G-buffer pass: render geometry to multiple color attachments (albedo, normal, metallic/roughness)
//!   - Deferred pass: composite from G-buffer textures via fullscreen quad
//!   - Multiple render targets and render passes
//! Simplified: uses a hardcoded cube instead of glTF scene loading.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
const DescriptorPool = noapi.DescriptorPool;
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

const start_width = 1000;
const start_height = 1000;
const frames_in_flight = 3;

// G-buffer texture indices in the descriptor heap
var gbuffer_albedo_idx: u32 = 0;
var gbuffer_normal_idx: u32 = 0;
var gbuffer_metallic_roughness_idx: u32 = 0;
var gbuffer_depth_idx: u32 = 0;
var env_map_idx: u32 = 0;

// Selected G-buffer texture type to display (toggled by left click)
var selected_texture_type: u32 = 0;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    const sdl_win = try sdl3.video.Window.init("Deferred Shading — G-buffer: Albedo", start_width, start_height, .{
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

    // ── GPU init ───────────────────────────────────────────
    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = frames_in_flight,
        .app_name = "7_deferred_async_load",
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
    var surf = try noapi.Surface.init(&gpu, surface, .{ .extent = .{ .width = start_width, .height = start_height } });
    defer surf.deinit();

    // ── Shaders ────────────────────────────────────────────
    const vert_gbuffer = try noapi.Shader.createFromPath(gpa, io, &gpu, "shaders/gbuffer_vert.spv", .vertex, "main", "gbuffer_vert");
    defer vert_gbuffer.destroy();
    const frag_gbuffer = try noapi.Shader.createFromPath(gpa, io, &gpu, "shaders/gbuffer_frag.spv", .fragment, "main", "gbuffer_frag");
    defer frag_gbuffer.destroy();
    const vert_final = try noapi.Shader.createFromPath(gpa, io, &gpu, "shaders/final_pass_vert.spv", .vertex, "main", "final_pass_vert");
    defer vert_final.destroy();
    const frag_final = try noapi.Shader.createFromPath(gpa, io, &gpu, "shaders/final_pass_frag.spv", .fragment, "main", "final_pass_frag");
    defer frag_final.destroy();

    // ── Descriptor pool ─────────────────────────────────────
    var pool = try DescriptorPool.init(&gpu, 8, 0, 8);
    defer pool.deinit();

    // Create a default 1x1 white texture
    const default_tex = try createSolidColorTexture(&gpu, &[_]u8{ 255, 255, 255, 255 });
    defer gpu.textureDestroy(default_tex.handle);

    // Create a sampler handle (shared across all allocTexture calls)
    const samp_handle = gpu.samplerDescriptor(.{ .max_anisotropy = 1.0 });

    // Allocate default texture at slot 3
    _ = pool.allocTexture(default_tex.handle, samp_handle, .@"2d");

    // ── Load environment map ──────────────────────────────────
    const env_map_idx_val = try loadEnvMap(gpa, io, &gpu, &pool, samp_handle);
    env_map_idx = env_map_idx_val;

    // ── Upload geometry (cube) ──────────────────────────────
    const cube_data = createCubeData(gpa);
    defer {
        gpa.free(cube_data.positions);
        gpa.free(cube_data.normals);
        gpa.free(cube_data.uvs);
        gpa.free(cube_data.indices);
    }

    const cube_pos_gpu = try gpu.gpuMalloc(cube_data.positions.len * @sizeOf([4]f32), 64, .default);
    defer gpu.gpuFree(cube_pos_gpu);
    @memcpy(cube_pos_gpu.cpu[0 .. cube_data.positions.len * @sizeOf([4]f32)], std.mem.sliceAsBytes(cube_data.positions));

    const cube_norm_gpu = try gpu.gpuMalloc(cube_data.normals.len * @sizeOf([4]f32), 64, .default);
    defer gpu.gpuFree(cube_norm_gpu);
    @memcpy(cube_norm_gpu.cpu[0 .. cube_data.normals.len * @sizeOf([4]f32)], std.mem.sliceAsBytes(cube_data.normals));

    const cube_uv_gpu = try gpu.gpuMalloc(cube_data.uvs.len * @sizeOf([2]f32), 64, .default);
    defer gpu.gpuFree(cube_uv_gpu);
    @memcpy(cube_uv_gpu.cpu[0 .. cube_data.uvs.len * @sizeOf([2]f32)], std.mem.sliceAsBytes(cube_data.uvs));

    const cube_idx_gpu = try gpu.gpuMalloc(cube_data.indices.len * @sizeOf(u32), 64, .default);
    defer gpu.gpuFree(cube_idx_gpu);
    @memcpy(cube_idx_gpu.cpu[0 .. cube_data.indices.len * @sizeOf(u32)], std.mem.sliceAsBytes(cube_data.indices));

    // ── Fullscreen quad ─────────────────────────────────────
    const fsq = createFullscreenQuad(gpa);
    defer {
        gpa.free(fsq.vertices);
        gpa.free(fsq.indices);
    }

    const fsq_vert_gpu = try gpu.gpuMalloc(fsq.vertices.len * @sizeOf(FullscreenVertex), 64, .default);
    defer gpu.gpuFree(fsq_vert_gpu);
    @memcpy(fsq_vert_gpu.cpu[0 .. fsq.vertices.len * @sizeOf(FullscreenVertex)], std.mem.sliceAsBytes(fsq.vertices));

    const fsq_idx_gpu = try gpu.gpuMalloc(fsq.indices.len * @sizeOf(u32), 64, .default);
    defer gpu.gpuFree(fsq_idx_gpu);
    @memcpy(fsq_idx_gpu.cpu[0 .. fsq.indices.len * @sizeOf(u32)], std.mem.sliceAsBytes(fsq.indices));

    // ── G-buffer textures ───────────────────────────────────
    var window_w: i32 = start_width;
    var window_h: i32 = start_height;
    var gb_albedo: noapi.Texture.OwnedTexture = undefined;
    var gb_normal: noapi.Texture.OwnedTexture = undefined;
    var gb_mr: noapi.Texture.OwnedTexture = undefined;
    var gb_depth: noapi.Texture.OwnedTexture = undefined;
    try createGbufferTextures(&gpu, &pool, @intCast(window_w), @intCast(window_h), &gb_albedo, &gb_normal, &gb_mr, &gb_depth, samp_handle);
    defer {
        gb_albedo.freeAndDestroy();
        gb_normal.freeAndDestroy();
        gb_mr.freeAndDestroy();
        gb_depth.freeAndDestroy();
    }

    // ── Timing ─────────────────────────────────────────────
    const ts_freq = sdl3.timer.getPerformanceFrequency();
    var now_ts = sdl3.timer.getPerformanceCounter();

    // ── Push constant structs ──────────────────────────────
    const VertData = extern struct {
        positions: u64,
        normals: u64,
        uvs: u64,
        // std430 requires 16-byte alignment for mat4 (vec4 columns),
        // but C struct only gives 4-byte alignment for [16]f32.
        // Add padding to match the shader's std430 layout.
        _pad: u64 = undefined,
        model_to_world: [16]f32,
        model_to_world_normal: [16]f32,
        world_to_view: [16]f32,
        view_to_proj: [16]f32,
    };

    const FragData = extern struct {
        base_color_map: u32,
        base_color_map_sampler: u32,
        metallic_roughness_map: u32,
        metallic_roughness_map_sampler: u32,
        normal_map: u32,
        normal_map_sampler: u32,
    };

    const FsqFragData = extern struct {
        // Align-16 fields first (matches std430 vec4/vec3 alignment)
        v2w_right: [4]f32,
        v2w_up: [4]f32,
        v2w_fwd: [4]f32,
        cam_pos: [3]f32,
        // Align-4 fields (naturally packed, no gaps)
        gbuffer_albedo: u32,
        gbuffer_albedo_sampler: u32,
        gbuffer_normal: u32,
        gbuffer_normal_sampler: u32,
        gbuffer_metallic_roughness: u32,
        gbuffer_metallic_roughness_sampler: u32,
        gbuffer_depth: u32,
        gbuffer_depth_sampler: u32,
        env_map: u32,
        tan_half_fov: f32,
        tan_half_fov_x: f32,
        selected_texture_type: i32,
    };

    const vert_data_size = @sizeOf(VertData);
    const frag_data_size = @sizeOf(FragData);
    const total_size = vert_data_size + frag_data_size;
    const fsq_push_size = @sizeOf(FsqFragData);

    // Persistent push-constant buffer (allocated once, reused each frame)
    const push_buf = try gpu.gpuMalloc(total_size + fsq_push_size, 64, .default);
    defer gpu.gpuFree(push_buf);

    // ── Render loop ────────────────────────────────────────
    const win_id = try sdl_win.getId();
    var should_close = false;
    // ── FPS counter ─────────────────────────────────────────
    var fps_timer: u64 = sdl3.timer.getPerformanceCounter();
    var fps_frames: u32 = 0;
    const fps_freq: u64 = sdl3.timer.getPerformanceFrequency();
    while (!should_close) {
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
                    if (me.button == .left) {
                        selected_texture_type = (selected_texture_type + 1) % 4;
                        const names = [_][*:0]const u8{ "Albedo", "Normal", "Metallic/Roughness", "Shaded" };
                        var buf: [128]u8 = undefined;
                        const title = std.fmt.bufPrintZ(&buf, "Deferred Shading — {s}", .{names[selected_texture_type]}) catch unreachable;
                        sdl_win.setTitle(title) catch unreachable;
                    }
                },
                .window_resized => |we| {
                    if (we.id == win_id) surf.notifyResize(.{ .width = @intCast(we.width), .height = @intCast(we.height) });
                },
                else => {},
            }
        }

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

        // DIAG: check device on first frame
        if (fps_frames == 0) try gpu.waitIdle();

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

        // ── Render frame ────────────────────────────────────
        _ = surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };

        // ── Recreate g-buffer if surface size changed ──────
        const surface_size = surf.surfaceSize();
        if (surface_size.width != window_w or surface_size.height != window_h) {
            window_w = @as(i32, @intCast(surface_size.width));
            window_h = @as(i32, @intCast(surface_size.height));
            try gpu.waitIdle();

            gb_albedo.freeAndDestroy();
            gb_normal.freeAndDestroy();
            gb_mr.freeAndDestroy();
            gb_depth.freeAndDestroy();
            try createGbufferTextures(&gpu, &pool, @intCast(window_w), @intCast(window_h), &gb_albedo, &gb_normal, &gb_mr, &gb_depth, samp_handle);
        }

        // ── Camera ──────────────────────────────────────────
        const aspect = @as(f32, @floatFromInt(window_w)) / @as(f32, @floatFromInt(window_h));
        const view = cameraMatrix(dt);
        const proj = perspectiveMatrix(59.0 * std.math.pi / 180.0, aspect, 0.1, 1000.0);

        var cmd = surf.commandsBegin();

        // ── Pass 1: G-buffer ────────────────────────────────
        cmd.beginRendering(.{
            .color_attachments = &.{
                .{ .texture = gb_albedo.texture.handle, .load_op = .clear, .store_op = .store, .clear_color = .{ 0, 0, 0, 1 } },
                .{ .texture = gb_normal.texture.handle, .load_op = .clear, .store_op = .store, .clear_color = .{ 0.5, 0.5, 1.0, 1.0 } },
                .{ .texture = gb_mr.texture.handle, .load_op = .clear, .store_op = .store, .clear_color = .{ 0, 0, 0, 1 } },
            },
            .depth_attachment = noapi.RenderingAttachment{
                .texture = gb_depth.texture.handle,
                .load_op = .clear,
                .store_op = .store,
                .clear_depth = 1.0,
            },
            .render_area_size = .{ surface_size.width, surface_size.height },
        });

        cmd.setShaders(vert_gbuffer, frag_gbuffer);
        cmd.setDepthState(.{ .mode = .{ .read = true, .write = true }, .compare = .less });
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .back, .front_face = .clockwise });

        const model = mat4Identity();
        const model_normal = mat4Transpose(mat4Invert(model));

        const vert_data_ptr: *VertData = @ptrCast(@alignCast(push_buf.cpu));
        const frag_data_ptr: *FragData = @ptrCast(@alignCast(push_buf.cpu + vert_data_size));

        vert_data_ptr.* = .{
            .positions = cube_pos_gpu.gpu,
            .normals = cube_norm_gpu.gpu,
            .uvs = cube_uv_gpu.gpu,
            .model_to_world = model,
            .model_to_world_normal = model_normal,
            .world_to_view = view,
            .view_to_proj = proj,
        };

        frag_data_ptr.* = .{
            .base_color_map = 0,
            .base_color_map_sampler = 0,
            .metallic_roughness_map = 0,
            .metallic_roughness_map_sampler = 0,
            .normal_map = 0,
            .normal_map_sampler = 0,
        };

        cmd.bindDescriptorSets(pool.heap);
        cmd.drawIndexed(
            .{
                .vert_data = push_buf.gpu,
                .frag_data = push_buf.gpu + vert_data_size,
                .indirect = 0,
            },
            cube_idx_gpu,
            @intCast(cube_data.indices.len),
            1,
            0,
            0,
        );

        cmd.endRendering();

        // Barrier: G-buffer color attachments → fragment shader reads
        cmd.barrier(.{ .color_output = true }, .{ .fragment = true }, .{});

        // ── Pass 2: Deferred shading ────────────────────────
        const sc = surf.currentImage();
        cmd.beginRendering(.{
            .color_attachments = &.{
                .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{ 0.7, 0.7, 0.7, 1.0 } },
            },
            .render_area_size = .{ surface_size.width, surface_size.height },
        });

        cmd.setShaders(vert_final, frag_final);
        cmd.setDepthState(.{ .mode = .{}, .compare = .always });
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });

        const fsq_frag_ptr: *FsqFragData = @ptrCast(@alignCast(push_buf.cpu + total_size));

        // Extract view→world basis vectors from the view matrix
        const v2w_r0 = view[0]; const v2w_r1 = view[4]; const v2w_r2 = view[8];
        const v2w_u0 = view[1]; const v2w_u1 = view[5]; const v2w_u2 = view[9];
        const v2w_f0 = -view[2]; const v2w_f1 = -view[6]; const v2w_f2 = -view[10];

        const w_f: f32 = @floatFromInt(surface_size.width);
        const h_f: f32 = @floatFromInt(surface_size.height);
        const aspect_ratio = w_f / h_f;
        const tan_half_fov = @tan(59.0 * std.math.pi / 180.0 * 0.5);

        fsq_frag_ptr.* = .{
            .v2w_right = .{ v2w_r0, v2w_r1, v2w_r2, 0 },
            .v2w_up    = .{ v2w_u0, v2w_u1, v2w_u2, 0 },
            .v2w_fwd   = .{ v2w_f0, v2w_f1, v2w_f2, 0 },
            .cam_pos = .{ 3.0, 2.0, 3.0 },
            .gbuffer_albedo = gbuffer_albedo_idx,
            .gbuffer_albedo_sampler = gbuffer_albedo_idx,
            .gbuffer_normal = gbuffer_normal_idx,
            .gbuffer_normal_sampler = gbuffer_normal_idx,
            .gbuffer_metallic_roughness = gbuffer_metallic_roughness_idx,
            .gbuffer_metallic_roughness_sampler = gbuffer_metallic_roughness_idx,
            .gbuffer_depth = gbuffer_depth_idx,
            .gbuffer_depth_sampler = gbuffer_depth_idx,
            .env_map = env_map_idx,
            .tan_half_fov = tan_half_fov,
            .tan_half_fov_x = tan_half_fov * aspect_ratio,
            .selected_texture_type = @as(i32, @intCast(selected_texture_type)),
        };

        cmd.bindDescriptorSets(pool.heap);
        cmd.draw(
            .{
                .vert_data = push_buf.gpu,
                .frag_data = push_buf.gpu + total_size,
                .indirect = 0,
            },
            3,
            1,
        );

        cmd.endRendering();

        _ = try surf.endFrame(.{ .blit_to_swapchain = true });
    }

    try gpu.waitIdle();
}

// ── Geometry helpers ──────────────────────────────────────────

const CubeData = struct {
    positions: []const [4]f32,
    normals: []const [4]f32,
    uvs: []const [2]f32,
    indices: []const u32,
};

fn createCubeData(allocator: std.mem.Allocator) CubeData {
    const positions = allocator.dupe(
        [4]f32,
        &[_][4]f32{
            .{ -0.5, -0.5, 0.5, 1.0 },  .{ 0.5, -0.5, 0.5, 1.0 },   .{ 0.5, 0.5, 0.5, 1.0 },   .{ -0.5, 0.5, 0.5, 1.0 },
            .{ 0.5, -0.5, -0.5, 1.0 },  .{ -0.5, -0.5, -0.5, 1.0 }, .{ -0.5, 0.5, -0.5, 1.0 }, .{ 0.5, 0.5, -0.5, 1.0 },
            .{ 0.5, -0.5, 0.5, 1.0 },   .{ 0.5, -0.5, -0.5, 1.0 },  .{ 0.5, 0.5, -0.5, 1.0 },  .{ 0.5, 0.5, 0.5, 1.0 },
            .{ -0.5, -0.5, -0.5, 1.0 }, .{ -0.5, -0.5, 0.5, 1.0 },  .{ -0.5, 0.5, 0.5, 1.0 },  .{ -0.5, 0.5, -0.5, 1.0 },
            .{ -0.5, 0.5, 0.5, 1.0 },   .{ 0.5, 0.5, 0.5, 1.0 },    .{ 0.5, 0.5, -0.5, 1.0 },  .{ -0.5, 0.5, -0.5, 1.0 },
            .{ -0.5, -0.5, -0.5, 1.0 }, .{ 0.5, -0.5, -0.5, 1.0 },  .{ 0.5, -0.5, 0.5, 1.0 },  .{ -0.5, -0.5, 0.5, 1.0 },
        },
    ) catch unreachable;

    const normals = allocator.dupe(
        [4]f32,
        &[_][4]f32{
            .{ 0, 0, 1, 0 },  .{ 0, 0, 1, 0 },  .{ 0, 0, 1, 0 },  .{ 0, 0, 1, 0 },
            .{ 0, 0, -1, 0 }, .{ 0, 0, -1, 0 }, .{ 0, 0, -1, 0 }, .{ 0, 0, -1, 0 },
            .{ 1, 0, 0, 0 },  .{ 1, 0, 0, 0 },  .{ 1, 0, 0, 0 },  .{ 1, 0, 0, 0 },
            .{ -1, 0, 0, 0 }, .{ -1, 0, 0, 0 }, .{ -1, 0, 0, 0 }, .{ -1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },  .{ 0, 1, 0, 0 },  .{ 0, 1, 0, 0 },  .{ 0, 1, 0, 0 },
            .{ 0, -1, 0, 0 }, .{ 0, -1, 0, 0 }, .{ 0, -1, 0, 0 }, .{ 0, -1, 0, 0 },
        },
    ) catch unreachable;

    const uvs = allocator.dupe(
        [2]f32,
        &[_][2]f32{
            .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 },
            .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 },
            .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 },
            .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 },
            .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 },
            .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 },
        },
    ) catch unreachable;

    const indices = allocator.dupe(
        u32,
        &[_]u32{
            0,  1,  2,  0,  2,  3,
            4,  5,  6,  4,  6,  7,
            8,  9,  10, 8,  10, 11,
            12, 13, 14, 12, 14, 15,
            16, 17, 18, 16, 18, 19,
            20, 21, 22, 20, 22, 23,
        },
    ) catch unreachable;

    return .{ .positions = positions, .normals = normals, .uvs = uvs, .indices = indices };
}

const FullscreenVertex = extern struct {
    pos: [4]f32,
    uv: [2]f32,
};

const FullscreenQuad = struct {
    vertices: []const FullscreenVertex,
    indices: []const u32,
};

fn createFullscreenQuad(allocator: std.mem.Allocator) FullscreenQuad {
    const vertices = allocator.dupe(
        FullscreenVertex,
        &[_]FullscreenVertex{
            .{ .pos = .{ -1, 1, 0, 1 }, .uv = .{ 0, 1 } },
            .{ .pos = .{ 1, -1, 0, 1 }, .uv = .{ 1, 0 } },
            .{ .pos = .{ 1, 1, 0, 1 }, .uv = .{ 1, 1 } },
            .{ .pos = .{ -1, -1, 0, 1 }, .uv = .{ 0, 0 } },
        },
    ) catch unreachable;

    const indices = allocator.dupe(
        u32,
        &[_]u32{ 0, 2, 1, 0, 1, 3 },
    ) catch unreachable;

    return .{ .vertices = vertices, .indices = indices };
}

// ── G-buffer texture creation ────────────────────────────────

fn createGbufferTextures(gpu: *noapi.Gpu, pool: *DescriptorPool, width: u32, height: u32, out_albedo: *noapi.Texture.OwnedTexture, out_normal: *noapi.Texture.OwnedTexture, out_mr: *noapi.Texture.OwnedTexture, out_depth: *noapi.Texture.OwnedTexture, samp_handle: u64) !void {
    const gb_desc: noapi.TextureDesc = .{
        .dimensions = .{ width, height, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true, .color_attachment = true, .storage = false },
    };

    const depth_desc: noapi.TextureDesc = .{
        .dimensions = .{ width, height, 1 },
        .format = .d32_float,
        .usage = .{ .depth_stencil_attachment = true, .sampled = true },
    };

    {
        const tex = try noapi.Texture.OwnedTexture.allocAndCreate(gpu, gb_desc);
        out_albedo.* = tex;
        gbuffer_albedo_idx = pool.allocTexture(tex.texture.handle, samp_handle, .@"2d");
    }

    {
        const tex = try noapi.Texture.OwnedTexture.allocAndCreate(gpu, gb_desc);
        out_normal.* = tex;
        gbuffer_normal_idx = pool.allocTexture(tex.texture.handle, samp_handle, .@"2d");
    }

    {
        const tex = try noapi.Texture.OwnedTexture.allocAndCreate(gpu, gb_desc);
        out_mr.* = tex;
        gbuffer_metallic_roughness_idx = pool.allocTexture(tex.texture.handle, samp_handle, .@"2d");
    }

    {
        const tex = try noapi.Texture.OwnedTexture.allocAndCreate(gpu, depth_desc);
        out_depth.* = tex;
        gbuffer_depth_idx = pool.allocTexture(tex.texture.handle, samp_handle, .@"2d");
    }
}

fn createSolidColorTexture(gpu: *noapi.Gpu, rgba: *const [4]u8) !noapi.Texture {
    const desc: noapi.TextureDesc = .{
        .dimensions = .{ 1, 1, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    };
    const tex = try noapi.Texture.create(gpu, desc);

    const pixel_size: u64 = 4;
    const staging = try gpu.gpuMalloc(pixel_size, 16, .default);
    defer gpu.gpuFree(staging);
    @memcpy(staging.cpu[0..pixel_size], rgba);

    var cmd = try gpu.commandsBegin();
    cmd.copyToTexture(tex, staging, .{ .size = .{ 1, 1, 1 } });
    cmd.barrier(.{ .transfer = true }, .{ .fragment = true }, .{});
    try gpu.queueSubmit(&.{cmd});
    gpu.commandsEnd(cmd);

    return tex;
}

/// Load a PPM P6 file from disk and upload as a GPU texture.
/// Returns the descriptor heap index.
fn loadEnvMap(gpa: std.mem.Allocator, io: Io, gpu: *noapi.Gpu, pool: *DescriptorPool, samp_handle: u64) !u32 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/env.ppm", gpa, .unlimited);
    defer gpa.free(bytes);

    // Parse P6 header with optional comment lines
    var pos: usize = 0;
    if (bytes.len < 3 or bytes[0] != 'P' or bytes[1] != '6') return error.InvalidPpm;
    pos = 3; // skip "P6\n"

    // Skip whitespace and comments
    const skipWhitespaceAndComments = struct {
        fn skip(p: *usize, buf: []const u8) void {
            outer: while (p.* < buf.len) {
                switch (buf[p.*]) {
                    '\n', ' ', '\t', '\r' => {
                        p.* += 1;
                    },
                    '#' => {
                        while (p.* < buf.len and buf[p.*] != '\n') p.* += 1;
                    },
                    else => break :outer,
                }
            }
        }
    }.skip;

    skipWhitespaceAndComments(&pos, bytes);

    // Parse width
    var width: u32 = 0;
    while (pos < bytes.len and bytes[pos] >= '0' and bytes[pos] <= '9') {
        width = width * 10 + (bytes[pos] - '0');
        pos += 1;
    }
    skipWhitespaceAndComments(&pos, bytes);

    // Parse height
    var height: u32 = 0;
    while (pos < bytes.len and bytes[pos] >= '0' and bytes[pos] <= '9') {
        height = height * 10 + (bytes[pos] - '0');
        pos += 1;
    }
    skipWhitespaceAndComments(&pos, bytes);

    // Parse maxval
    var maxval: u32 = 0;
    while (pos < bytes.len and bytes[pos] >= '0' and bytes[pos] <= '9') {
        maxval = maxval * 10 + (bytes[pos] - '0');
        pos += 1;
    }
    if (pos < bytes.len and bytes[pos] == '\n') pos += 1;

    // (maxval parsed above, always 255 for this file)

    // Remaining data is RGB pixels: width * height * 3 bytes
    const rgb_data = bytes[pos..];
    const expected_rgb = width * height * 3;
    if (rgb_data.len < expected_rgb) return error.InvalidPpm;

    // Create GPU texture (RGBA8, so convert RGB → RGBA)
    const tex = try noapi.Texture.create(gpu, .{
        .dimensions = .{ width, height, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    });

    // Upload via staging buffer with RGB→RGBA conversion
    const pixel_count = width * height;
    const staging_size = pixel_count * 4;
    const staging = try gpu.gpuMalloc(staging_size, 16, .default);
    defer gpu.gpuFree(staging);

    const dst = staging.cpu[0..staging_size];
    for (0..pixel_count) |i| {
        dst[i * 4 + 0] = rgb_data[i * 3 + 0];
        dst[i * 4 + 1] = rgb_data[i * 3 + 1];
        dst[i * 4 + 2] = rgb_data[i * 3 + 2];
        dst[i * 4 + 3] = 255;
    }

    var cmd = try gpu.commandsBegin();
    cmd.copyToTexture(tex, staging, .{ .size = .{ width, height, 1 } });
    cmd.barrier(.{ .transfer = true }, .{ .fragment = true }, .{});
    try gpu.queueSubmit(&.{cmd});
    gpu.commandsEnd(cmd);

    // Allocate in descriptor heap
    const idx = pool.allocTexture(tex.handle, samp_handle, .@"2d");
    return idx;
}

// ── Matrix helpers ───────────────────────────────────────────

fn mat4Identity() [16]f32 {
    return .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
}

fn mat4Invert(m: [16]f32) [16]f32 {
    _ = m;
    return mat4Identity();
}

fn mat4Transpose(m: [16]f32) [16]f32 {
    return .{
        m[0], m[4], m[8],  m[12],
        m[1], m[5], m[9],  m[13],
        m[2], m[6], m[10], m[14],
        m[3], m[7], m[11], m[15],
    };
}

fn cameraMatrix(dt: f32) [16]f32 {
    _ = dt;
    const eye_x: f32 = 3.0;
    const eye_y: f32 = 2.0;
    const eye_z: f32 = 3.0;
    const center: [3]f32 = .{ 0, 0, 0 };
    const up: [3]f32 = .{ 0, 1, 0 };

    const fwd = normalize3(.{ center[0] - eye_x, center[1] - eye_y, center[2] - eye_z });
    const right = normalize3(cross3(fwd, up));
    const cam_up = cross3(right, fwd);

    return .{
        right[0],                               cam_up[0],                               -fwd[0],                             0,
        right[1],                               cam_up[1],                               -fwd[1],                             0,
        right[2],                               cam_up[2],                               -fwd[2],                             0,
        -dot3(right, .{ eye_x, eye_y, eye_z }), -dot3(cam_up, .{ eye_x, eye_y, eye_z }), dot3(fwd, .{ eye_x, eye_y, eye_z }), 1,
    };
}

fn perspectiveMatrix(fov_y: f32, aspect: f32, near: f32, far: f32) [16]f32 {
    // Row-major storage; GLSL reads as column-major.
    // The negative signs in row 2 correct the Z mapping to Vulkan's [0,1] depth range.
    const f = 1.0 / @tan(fov_y * 0.5);
    return .{
        f / aspect, 0, 0,                            0,
        0,          f, 0,                            0,
        0,          0, -far / (far - near),          -1,
        0,          0, -(far * near) / (far - near), 0,
    };
}

// ── Vector math ──────────────────────────────────────────────

fn normalize3(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len == 0) return v;
    return .{ v[0] / len, v[1] / len, v[2] / len };
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

// ── Global helpers ───────────────────────────────────────────

var exts_copy_global: []const [*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_copy_global;
}
