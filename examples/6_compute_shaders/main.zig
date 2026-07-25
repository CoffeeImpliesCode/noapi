//! 6_compute_shaders — compute shader + indirect dispatch demo.
//! Port of the upstream 6_compute_shaders Odin example.
//! Demonstrates compute shaders writing to a texture, then rendering it
//! as a fullscreen quad (shadertoy-style). Supports both direct dispatch
//! and indirect dispatch via GPU buffer.

const std = @import("std");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const vk = noapi.vk;
const DescriptorPool = noapi.DescriptorPool;
const Io = std.Io;

const start_width = 1000;
const start_height = 1000;
const frames_in_flight = 3;
const use_indirect = true;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    const sdl_win = try sdl3.video.Window.init("Compute Shader", start_width, start_height, .{
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
    const comp_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/compute_comp.spv", gpa, .unlimited);
    defer gpa.free(comp_bytes);
    const vert_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/fullscreen_quad_vert.spv", gpa, .unlimited);
    defer gpa.free(vert_bytes);
    const frag_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/tex_sample_frag.spv", gpa, .unlimited);
    defer gpa.free(frag_bytes);
    const comp_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, comp_bytes));
    const vert_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, vert_bytes));
    const frag_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, frag_bytes));

    // ── GPU init ───────────────────────────────────────────
    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = frames_in_flight,
        .app_name = "6_compute_shaders",
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
    const comp_shader = try gpu.shaderCreate(comp_spirv, .compute, "main", "compute");
    defer gpu.shaderDestroy(comp_shader);
    const vert_shader = try gpu.shaderCreate(vert_spirv, .vertex, "main", "fullscreen_quad");
    defer gpu.shaderDestroy(vert_shader);
    const frag_shader = try gpu.shaderCreate(frag_spirv, .fragment, "main", "tex_sample");
    defer gpu.shaderDestroy(frag_shader);

    // ── Descriptor pool ────────────────────────────────────
    var pool = try DescriptorPool.init(&gpu, 1, 1, 1);
    defer pool.deinit();

    // ── Compute output texture (storage + sampled) ─────────
    var surface_size = surf.surfaceSize();
    var output_tex = try gpu.textureCreate(.{
        .dimensions = .{ surface_size.width, surface_size.height, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .storage = true, .sampled = true },
    });
    defer gpu.textureDestroy(output_tex);

    // ── Allocate descriptor slots ──────────────────────────
    var tex_idx = pool.allocTexture(output_tex, gpu.samplerDescriptor(.{}), .@"2d");
    var tex_rw_idx = pool.allocTextureRw(output_tex, .@"2d");

    // ── Indirect dispatch buffer ───────────────────────────
    const indirect_buf = try gpu.gpuMalloc(@sizeOf(noapi.DispatchIndirectCommand), 4, .default);
    defer gpu.gpuFree(indirect_buf);

    // ── Timing ─────────────────────────────────────────────
    const ts_freq = sdl3.timer.getPerformanceFrequency();
    var now_ts = sdl3.timer.getPerformanceCounter();
    var total_time: f32 = 0;

    // ── Frame pacing semaphore ─────────────────────────────
    const frame_sem = try gpu.semaphoreCreate(0);
    defer gpu.semaphoreDestroy(frame_sem);
    var next_frame: u64 = 1;

    // ── Main loop ──────────────────────────────────────────
    const win_id = try sdl_win.getId();
    var should_close = false;
    // ── FPS counter ─────────────────────────────────────────
    var fps_timer: u64 = sdl3.timer.getPerformanceCounter();
    var fps_frames: u32 = 0;
    const fps_freq: u64 = sdl3.timer.getPerformanceFrequency();
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

        // Frame pacing
        if (next_frame > frames_in_flight) {
            gpu.semaphoreWait(frame_sem, next_frame - frames_in_flight);
        }

        // Begin frame (triggers swapchain recreation if resized)
        _ = surf.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };

        // Handle resize
        const new_size = surf.surfaceSize();
        if (new_size.width != surface_size.width or new_size.height != surface_size.height) {
            surface_size = new_size;
            gpu.waitIdle();
            pool.freeTexture(tex_idx);
            pool.freeTextureRw(tex_rw_idx);
            gpu.textureDestroy(output_tex);
            output_tex = try gpu.textureCreate(.{
                .dimensions = .{ surface_size.width, surface_size.height, 1 },
                .format = .rgba8_unorm,
                .usage = .{ .storage = true, .sampled = true },
            });
            tex_idx = pool.allocTexture(output_tex, gpu.samplerDescriptor(.{}), .@"2d");
            tex_rw_idx = pool.allocTextureRw(output_tex, .@"2d");
        }

        // Delta time
        const last_ts = now_ts;
        now_ts = sdl3.timer.getPerformanceCounter();
        const delta = @as(f32, @floatCast(@as(f64, @floatFromInt(now_ts -| last_ts)) / @as(f64, @floatFromInt(ts_freq))));
        const max_dt: f32 = 1.0 / 10.0;
        total_time += @min(max_dt, delta);

        // ── Compute dispatch ────────────────────────────────
        const group_size_x: u32 = 8;
        const group_size_y: u32 = 8;
        const num_groups_x = (surface_size.width + group_size_x - 1) / group_size_x;
        const num_groups_y = (surface_size.height + group_size_y - 1) / group_size_y;

        var cmd = surf.commandsBegin();
        cmd.bindDescriptorSets(pool.heap);
        cmd.setComputeShader(comp_shader);

        // Push constant: the compute shader expects float time at offset 0.
        // The noapi API pushes a u64; the shader reads the first 4 bytes as float.
        const push_data = @as(u64, @as(u32, @bitCast(total_time)));

        if (use_indirect) {
            // Write indirect dispatch command to GPU-visible buffer
            const indirect_cmd = @as(*noapi.DispatchIndirectCommand, @ptrCast(@alignCast(indirect_buf.cpu)));
            indirect_cmd.* = .{
                .num_groups_x = num_groups_x,
                .num_groups_y = num_groups_y,
                .num_groups_z = 1,
            };
            cmd.dispatchIndirect(push_data, indirect_buf);
        } else {
            cmd.dispatch(push_data, num_groups_x, num_groups_y, 1);
        }

        // Barrier: ensure compute shader finishes before fragment shader reads
        cmd.barrier(.{ .compute = true }, .{ .fragment = true }, .{});

        // ── Render compute output as fullscreen quad ────────
        const sc = surf.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{ 0, 0, 0, 1 } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setShaders(vert_shader, frag_shader);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.draw(noapi.PushData{}, 6, 1);

        cmd.endRendering();

        // Signal semaphore and present
        cmd.addSignalSemaphore(0, frame_sem, next_frame);
        _ = surf.endFrame(.{ .blit_to_swapchain = true });
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

    gpu.waitIdle();
}

var exts_copy_global: []const [*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_copy_global;
}
