//! noapi test application — animated grid + triangle demo.
//! Spawns each window's render loop in its own thread.

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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    try sdl3.hints.set(.video_driver, "wayland");
    try sdl3.hints.set(.render_driver, "vulkan");
    try sdl3.init(.{ .video = true, .events = true });
    defer sdl3.quit(.{ .video = true, .events = true });

    const sdl_win = try sdl3.video.Window.init("noapi", 800, 600, .{ .resizable = true });
    try sdl_win.show();

    // ── Vulkan loader via SDL3 ───────────────────────────
    try sdl3.vulkan.loadLibrary(null);
    const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();

    const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
    const exts_copy = try init.arena.allocator().dupe([*:0]const u8, sdl_exts);
    exts_copy_global = exts_copy;

    // ── Load shader SPIR-V
    const grid_vert_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/grid_vert.spv", gpa, .unlimited);
    defer gpa.free(grid_vert_bytes);
    const grid_frag_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/grid_frag.spv", gpa, .unlimited);
    defer gpa.free(grid_frag_bytes);
    const grid_vert_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, grid_vert_bytes));
    const grid_frag_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, grid_frag_bytes));

    // ── GPU init
    var gpu = try noapi.Gpu.init(.{
        .frames_in_flight = 2,
        .app_name = "noapi test",
        .validation = true,
        .loader = .{
            .get_instance_proc_addr = @ptrCast(get_proc_addr),
            .get_instance_extensions = &getExts,
        },
        .io = io,
        .allocator = gpa,
    });
    defer gpu.deinit();

    // ── Windows + surfaces
    const sdl_surface = try sdl3.vulkan.Surface.init(sdl_win, @ptrFromInt(@intFromEnum(gpu.instanceHandle())), null);
    const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface.surface));
    var surf1 = try noapi.Surface.init(&gpu, surface, .{ .extent = .{ .width = 800, .height = 600 } });

    const sdl_win2 = try sdl3.video.Window.init("noapi-2", 400, 300, .{ .resizable = true });
    try sdl_win2.show();
    const sdl_surface2 = try sdl3.vulkan.Surface.init(sdl_win2, @ptrFromInt(@intFromEnum(gpu.instanceHandle())), null);
    const surface2: vk.SurfaceKHR = @enumFromInt(@intFromPtr(sdl_surface2.surface));
    var surf2 = try noapi.Surface.init(&gpu, surface2, .{ .extent = .{ .width = 400, .height = 300 } });

    const win1_id = try sdl_win.getId();
    const win2_id = try sdl_win2.getId();

    // ── Compute shader + texture ──────────────────────────
    const comp_spv_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/compute_comp.spv", gpa, .unlimited);
    defer gpa.free(comp_spv_bytes);
    const comp_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, comp_spv_bytes));
    const comp_shader = try gpu.shaderCreate(comp_spirv, .compute, "main", "compute");
    defer gpu.shaderDestroy(comp_shader);

    const compute_tex = try gpu.textureCreate(.{
        .dimensions = .{ 256, 256, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .storage = true, .transfer_src = true, .sampled = true },
    });
    defer gpu.textureDestroy(compute_tex);

    // ── Graphics shaders
    const grid_vert = try gpu.shaderCreate(grid_vert_spirv, .vertex, "main", "grid_vert");
    defer gpu.shaderDestroy(grid_vert);
    const grid_frag = try gpu.shaderCreate(grid_frag_spirv, .fragment, "main", "grid_frag");
    defer gpu.shaderDestroy(grid_frag);

    // ── Buffer-based indexed triangle shaders ──────────────
    const btri_vert_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/buf_tri_vert.spv", gpa, .unlimited);
    defer gpa.free(btri_vert_bytes);
    const btri_frag_bytes = try Io.Dir.cwd().readFileAlloc(io, "shaders/buf_tri_frag.spv", gpa, .unlimited);
    defer gpa.free(btri_frag_bytes);
    const btri_vert_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, btri_vert_bytes));
    const btri_frag_spirv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, btri_frag_bytes));

    const btri_vert = try gpu.shaderCreate(btri_vert_spirv, .vertex, "main", "btri_vert");
    defer gpu.shaderDestroy(btri_vert);
    const btri_frag = try gpu.shaderCreate(btri_frag_spirv, .fragment, "main", "btri_frag");
    defer gpu.shaderDestroy(btri_frag);

    // ── Vertex + index buffers
    const vertex_size = 20;
    const vert_buf = try gpu.gpuMalloc(vertex_size * 6, 64, .default);

    const vert_data: [*]f32 = @ptrCast(@alignCast(vert_buf.cpu));
    vert_data[0] = 0.0;
    vert_data[1] = -0.5;
    vert_data[2] = 1.0;
    vert_data[3] = 0.0;
    vert_data[4] = 0.0;
    vert_data[5] = 0.5;
    vert_data[6] = 0.5;
    vert_data[7] = 0.0;
    vert_data[8] = 1.0;
    vert_data[9] = 0.0;
    vert_data[10] = -0.5;
    vert_data[11] = 0.5;
    vert_data[12] = 0.0;
    vert_data[13] = 0.0;
    vert_data[14] = 1.0;
    vert_data[15] = -0.5;
    vert_data[16] = -0.7;
    vert_data[17] = 0.0;
    vert_data[18] = 1.0;
    vert_data[19] = 1.0;
    vert_data[20] = 0.5;
    vert_data[21] = -0.7;
    vert_data[22] = 1.0;
    vert_data[23] = 0.0;
    vert_data[24] = 1.0;
    vert_data[25] = 0.0;
    vert_data[26] = 0.1;
    vert_data[27] = 1.0;
    vert_data[28] = 1.0;
    vert_data[29] = 0.0;

    const idx_buf = try gpu.gpuMalloc(@sizeOf(u32) * 6, 16, .default);
    const idx_data: [*]u32 = @ptrCast(@alignCast(idx_buf.cpu));
    idx_data[0] = 0;
    idx_data[1] = 1;
    idx_data[2] = 2;
    idx_data[3] = 3;
    idx_data[4] = 4;
    idx_data[5] = 5;

    const scratch_buf = try gpu.gpuMalloc(64, 16, .default);

    const test_sem = try gpu.semaphoreCreate(0);
    defer gpu.semaphoreDestroy(test_sem);

    const test_heap = try gpu.descHeapCreate(65536, 65536, 256);
    defer gpu.descHeapDestroy(test_heap);

    // Bind compute texture as storage image at slot 0 in the RW descriptor set
    {
        const comp_desc = gpu.textureRwViewDescriptor(compute_tex, .{ .format = .default });
        gpu.descHeapSetTexturesRw(test_heap, 0, &.{comp_desc});
    }

    const rt_tex = try gpu.textureCreate(.{
        .dimensions = .{ 256, 256, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .color_attachment = true, .transfer_src = true },
    });
    defer gpu.textureDestroy(rt_tex);

    // ── Shared state for window threads ───────────────────
    var w1: SharedW1 = .{
        .sdl = &sdl_win,
        .grid_vert = grid_vert,
        .grid_frag = grid_frag,
        .btri_vert = btri_vert,
        .btri_frag = btri_frag,
        .vert_buf = vert_buf,
        .idx_buf = idx_buf,
        .vertex_size = vertex_size,
        .rt_tex = rt_tex,
        .compute_tex = compute_tex,
        .comp_shader = comp_shader,
        .test_heap = test_heap,
        .scratch_buf = scratch_buf,
        .test_sem = test_sem,
    };
    var w2: SharedW2 = .{
        .sdl = &sdl_win2,
        .grid_vert = grid_vert,
        .grid_frag = grid_frag,
        .compute_tex = compute_tex,
    };

    // ── Spawn window render threads ───────────────────────
    const thread1 = try std.Thread.spawn(.{}, window1, .{ &surf1, &w1 });
    const thread2 = try std.Thread.spawn(.{}, window2, .{ &surf2, &w2 });

    // ── Main thread: event loop only ─────────────────────
    while (!w1.should_close or !w2.should_close) {
        while (sdl3.events.poll()) |ev| {
            switch (ev) {
                .quit => {
                    w1.should_close = true;
                    w2.should_close = true;
                },
                .window_close_requested => |we| {
                    const wid = we.id;
                    if (wid == win1_id) w1.should_close = true else if (wid == win2_id) w2.should_close = true;
                },
                .key_down => |ke| {
                    if (ke.key == .escape) {
                        w1.should_close = true;
                        w2.should_close = true;
                    }
                    if (ke.key == .space) w1.time_sec = 0;
                },
                .window_resized => |we| {
                    const wid = we.id;
                    if (wid == win1_id) {
                        surf1.notifyResize(.{ .width = @intCast(we.width), .height = @intCast(we.height) });
                    } else if (wid == win2_id) {
                        surf2.notifyResize(.{ .width = @intCast(we.width), .height = @intCast(we.height) });
                    }
                },
                else => {},
            }
        }
    }

    w1.should_close = true;
    w2.should_close = true;

    thread1.join();
    thread2.join();

    try gpu.waitIdle();
}

const SharedW1 = struct {
    should_close: bool = false,
    sdl: *const sdl3.video.Window,
    time_sec: f32 = 0,
    sem_val: u64 = 0,

    grid_vert: noapi.Shader,
    grid_frag: noapi.Shader,
    btri_vert: noapi.Shader,
    btri_frag: noapi.Shader,
    vert_buf: noapi.GpuPtr,
    idx_buf: noapi.GpuPtr,
    vertex_size: u32,
    rt_tex: noapi.TextureHandle,
    compute_tex: noapi.TextureHandle,
    comp_shader: noapi.Shader,
    test_heap: noapi.DescriptorHeap,
    scratch_buf: noapi.GpuPtr,
    test_sem: noapi.Semaphore,
};

fn window1(win: *noapi.Surface, s: *SharedW1) void {
    defer {
        win.deinit();
        s.sdl.deinit();
    }
    while (!s.should_close) {
        s.time_sec += 1.0 / 60.0;
        const tu32: u32 = @bitCast(s.time_sec);
        const time_bits: u64 = tu32;

        const schedule = win.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };
        _ = schedule;

        const surface_size = win.surfaceSize();
        const push: noapi.PushData = .{ .frag_data = time_bits };
        var cmd = win.commandsBegin();

        // ── Pass 1: render grid to offscreen texture ─────────
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = s.rt_tex, .load_op = .clear, .store_op = .store, .clear_color = .{ 1.0, 0.0, 1.0, 1.0 } },
        }, .render_area_size = .{ 256, 256 } });
        cmd.setShaders(s.grid_vert, s.grid_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.draw(push, 384, 1);
        cmd.endRendering();

        // ── Pass 2: main scene to swapchain ───────────────────
        const sc = win.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{
                0.1 + @sin(s.time_sec * 0.5) * 0.05,
                0.1 + @cos(s.time_sec * 0.7) * 0.05,
                0.2 + @sin(s.time_sec * 0.3) * 0.05,
                1.0,
            } },
        }, .render_area_size = .{ surface_size.width, surface_size.height } });

        cmd.setShaders(s.grid_vert, s.grid_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.draw(push, 384, 1);

        // Draw: indexed triangle RGB (top-right)
        {
            const ox = surface_size.width / 4;
            const oy = surface_size.height / 4;
            cmd.beginDebugLabel("tri-RGB", .{ 1, 0, 0, 1 });
            cmd.setViewport(.{
                .x = @floatFromInt(surface_size.width - ox - 10),
                .y = 10,
                .width = @floatFromInt(ox),
                .height = @floatFromInt(oy),
            });
            cmd.setScissor(.{ .x = @intCast(surface_size.width - ox - 10), .y = 10, .width = ox, .height = oy });
            cmd.setShaders(s.btri_vert, s.btri_frag);
            cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
            cmd.setVertexInput(
                &.{.{ .binding = 0, .stride = s.vertex_size, .input_rate = 0 }},
                &.{
                    .{ .location = 0, .binding = 0, .format = @intFromEnum(vk.Format.r32g32_sfloat), .offset = 0 },
                    .{ .location = 1, .binding = 0, .format = @intFromEnum(vk.Format.r32g32b32_sfloat), .offset = 8 },
                },
            );
            cmd.bindVertexBuffer(0, s.vert_buf, 0);
            cmd.drawIndexed(.{}, s.idx_buf, 3, 1, 0, 0);
            cmd.endDebugLabel();
        }

        // Draw: indexed triangle CMY (bottom-right)
        {
            const ox = surface_size.width / 4;
            const oy = surface_size.height / 4;
            cmd.beginDebugLabel("tri-CMY", .{ 1, 1, 0, 1 });
            cmd.setViewport(.{
                .x = @floatFromInt(surface_size.width - ox - 10),
                .y = @floatFromInt(surface_size.height - oy - 10),
                .width = @floatFromInt(ox),
                .height = @floatFromInt(oy),
            });
            cmd.setScissor(.{
                .x = @intCast(surface_size.width - ox - 10),
                .y = @intCast(surface_size.height - oy - 10),
                .width = ox,
                .height = oy,
            });
            cmd.setShaders(s.btri_vert, s.btri_frag);
            cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
            cmd.setVertexInput(
                &.{.{ .binding = 0, .stride = s.vertex_size, .input_rate = 0 }},
                &.{
                    .{ .location = 0, .binding = 0, .format = @intFromEnum(vk.Format.r32g32_sfloat), .offset = 0 },
                    .{ .location = 1, .binding = 0, .format = @intFromEnum(vk.Format.r32g32b32_sfloat), .offset = 8 },
                },
            );
            cmd.bindVertexBuffer(0, s.vert_buf, 0);
            cmd.drawIndexed(.{}, s.idx_buf, 3, 1, 3, 0);
            cmd.endDebugLabel();
        }

        cmd.endRendering();

        // Blit rt_tex to top-left
        {
            const blit_sz: u32 = @min(256, @min(surface_size.width, surface_size.height));
            cmd.blitTextureHandle(
                sc,
                .{ .offset_a = .{ 0, 0, 0 }, .offset_b = .{ @as(i32, @intCast(blit_sz)), @as(i32, @intCast(blit_sz)), 1 } },
                s.rt_tex,
                .{ .offset_a = .{ 0, 0, 0 }, .offset_b = .{ @as(i32, @intCast(blit_sz)), @as(i32, @intCast(blit_sz)), 1 } },
                .linear,
            );
        }

        // Compute: fill compute_tex, then blit to bottom-right
        {
            cmd.beginDebugLabel("compute", .{ 0, 1, 1, 1 });
            cmd.setComputeShader(s.comp_shader);
            cmd.bindDescriptorSets(s.test_heap);
            cmd.dispatch(time_bits, 256 / 8, 256 / 8, 1);
            cmd.barrier(.{ .compute = true }, .{ .transfer = true }, .{});
            cmd.endDebugLabel();
        }
        {
            const blit_sz: u32 = @min(256, @min(surface_size.width, surface_size.height));
            const sx: i32 = @intCast(surface_size.width -| blit_sz);
            const sy: i32 = @intCast(surface_size.height -| blit_sz);
            cmd.blitTextureHandle(
                sc,
                .{ .offset_a = .{ sx, sy, 0 }, .offset_b = .{ sx + @as(i32, @intCast(blit_sz)), sy + @as(i32, @intCast(blit_sz)), 1 } },
                s.compute_tex,
                .{ .offset_a = .{ 0, 0, 0 }, .offset_b = .{ @as(i32, @intCast(blit_sz)), @as(i32, @intCast(blit_sz)), 1 } },
                .linear,
            );
        }

        // memCopy + barrier
        {
            cmd.beginDebugLabel("memcpy", .{ 0, 1, 0, 1 });
            cmd.memCopy(s.scratch_buf, s.vert_buf, 16);
            cmd.barrier(.{ .transfer = true }, .{ .compute = true }, .{});
            cmd.endDebugLabel();
        }

        s.sem_val += 1;
        cmd.addWaitSemaphore(win.index, s.test_sem, s.sem_val - 1);
        cmd.addSignalSemaphore(win.index, s.test_sem, s.sem_val);

        _ = win.endFrame(.{ .blit_to_swapchain = true }) catch {};
    }
}

const SharedW2 = struct {
    should_close: bool = false,
    sdl: *const sdl3.video.Window,
    time_sec: f32 = 0,

    grid_vert: noapi.Shader,
    grid_frag: noapi.Shader,
    compute_tex: noapi.TextureHandle,
};

fn window2(win: *noapi.Surface, s: *SharedW2) void {
    defer {
        win.deinit();
        s.sdl.deinit();
    }
    while (!s.should_close) {
        s.time_sec += 1.0 / 60.0;
        const tu32: u32 = @bitCast(s.time_sec);
        const time_bits: u64 = tu32;

        _ = win.beginFrame() catch |e| {
            if (e == error.OutOfDateKHR) continue;
            @panic("beginFrame");
        };
        const sz2 = win.surfaceSize();
        var cmd = win.commandsBegin();

        const sc = win.currentImage();
        cmd.beginRendering(.{ .color_attachments = &.{
            .{ .texture = sc, .load_op = .clear, .store_op = .store, .clear_color = .{ 0.1, 0.2, 0.3, 1.0 } },
        }, .render_area_size = .{ sz2.width, sz2.height } });
        cmd.setShaders(s.grid_vert, s.grid_frag);
        cmd.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });
        cmd.draw(.{ .frag_data = time_bits }, 384, 1);
        cmd.endRendering();

        // Blit compute texture to bottom-right
        {
            const blit_sz: u32 = @min(256, @min(sz2.width, sz2.height));
            const sx: i32 = @intCast(sz2.width -| blit_sz);
            const sy: i32 = @intCast(sz2.height -| blit_sz);
            cmd.blitTextureHandle(sc, .{
                .offset_a = .{ sx, sy, 0 },
                .offset_b = .{
                    sx + @as(i32, @intCast(blit_sz)),
                    sy + @as(i32, @intCast(blit_sz)),
                    1,
                },
            }, s.compute_tex, .{
                .offset_a = .{ 0, 0, 0 },
                .offset_b = .{
                    @as(i32, @intCast(blit_sz)),
                    @as(i32, @intCast(blit_sz)),
                    1,
                },
            }, .linear);
        }

        _ = win.endFrame(.{ .blit_to_swapchain = true }) catch {};
    }
}

var exts_copy_global: []const [*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_copy_global;
}
