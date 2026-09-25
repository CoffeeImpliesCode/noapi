const std = @import("std");
const noapi = @import("noapi");

pub const tracy = @import("tracy");
pub const tracy_impl = @import("tracy_impl");

pub const panic = std.debug.FullPanic(browserPanic);

extern "env" fn noapi_webgpu_panic(message: [*]const u8, length: usize) callconv(.c) void;

fn browserPanic(message: []const u8, _: ?usize) noreturn {
    noapi_webgpu_panic(message.ptr, message.len);
    @trap();
}

const Example = enum(u32) {
    triangle = 1,
    textures = 2,
};

const QuadVertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
};

const TriangleVertex = extern struct {
    position: [4]f32,
    color: [4]f32,
};

comptime {
    std.debug.assert(@sizeOf(TriangleVertex) == 32);
}

const float32x2_format = @intFromEnum(noapi.vk.Format.r32g32_sfloat);
const vertex_bindings = [_]noapi.VertexBinding{
    .{ .binding = 0, .stride = @sizeOf(QuadVertex), .input_rate = 0 },
};
const vertex_attributes = [_]noapi.VertexAttribute{
    .{
        .location = 0,
        .binding = 0,
        .format = float32x2_format,
        .offset = @offsetOf(QuadVertex, "pos"),
    },
    .{
        .location = 1,
        .binding = 0,
        .format = float32x2_format,
        .offset = @offsetOf(QuadVertex, "uv"),
    },
};

const triangle_vertex_source = @embedFile("triangle_vert.wgsl");
const triangle_fragment_source = @embedFile("triangle_frag.wgsl");
const textures_shader_source = @embedFile("textures.wgsl");

const StartError = error{
    OutOfMemory,
    GpuInitialization,
    SurfaceInitialization,
    ShaderInitialization,
    BufferInitialization,
    TextureInitialization,
};

const Result = enum(c_int) {
    ok = 0,
    invalid_example = 1,
    already_started = 2,
    out_of_memory = 3,
    gpu_initialization = 4,
    surface_initialization = 5,
    shader_initialization = 6,
    buffer_initialization = 7,
    texture_initialization = 8,
    frame_begin = 20,
    frame_end = 21,
    not_started = 23,
};

const Runtime = struct {
    allocator: std.mem.Allocator,
    example: Example,
    gpu: ?*noapi.Gpu = null,
    gpu_initialized: bool = false,
    surface: ?noapi.Surface = null,
    vertex_shader: ?noapi.Shader = null,
    fragment_shader: ?noapi.Shader = null,
    vertex_buffer: ?noapi.GpuPtr = null,
    index_buffer: ?noapi.GpuPtr = null,
    staging_a: ?noapi.GpuPtr = null,
    staging_b: ?noapi.GpuPtr = null,
    texture_a: ?noapi.Texture = null,
    texture_b: ?noapi.Texture = null,
    textures_uploaded: bool = false,
    width: u32 = initial_width,
    height: u32 = initial_height,

    fn deinit(self: *Runtime) void {
        if (self.gpu) |gpu| {
            if (self.surface) |*surface| surface.deinit();
            if (self.vertex_shader) |*shader| shader.destroy();
            if (self.fragment_shader) |*shader| shader.destroy();
            if (self.texture_a) |*texture| texture.destroy();
            if (self.texture_b) |*texture| texture.destroy();
            if (self.vertex_buffer) |buffer| gpu.gpuFree(buffer);
            if (self.index_buffer) |buffer| gpu.gpuFree(buffer);
            if (self.staging_a) |buffer| gpu.gpuFree(buffer);
            if (self.staging_b) |buffer| gpu.gpuFree(buffer);
            if (self.gpu_initialized) gpu.deinit();
            self.allocator.destroy(gpu);
        }
        self.* = undefined;
    }
};

const initial_width: u32 = 960;
const initial_height: u32 = 640;
const texture_width: u32 = 256;
const texture_height: u32 = 256;
const texture_bytes: usize = @as(usize, texture_width) * @as(usize, texture_height) * 4;

var runtime: ?Runtime = null;

export fn noapiStart(example_id: u32) c_int {
    if (runtime != null) return @intFromEnum(Result.already_started);
    const example: Example = switch (example_id) {
        @intFromEnum(Example.triangle) => .triangle,
        @intFromEnum(Example.textures) => .textures,
        else => return @intFromEnum(Result.invalid_example),
    };

    runtime = initialize(example) catch |err| return @intFromEnum(resultForStartError(err));
    return @intFromEnum(Result.ok);
}

export fn noapiFrame(time_ms: f64, width: u32, height: u32) c_int {
    const app = if (runtime) |*active| active else return @intFromEnum(Result.not_started);
    const surface = if (app.surface) |*active| active else {
        return @intFromEnum(Result.frame_begin);
    };

    const frame_width = @max(width, 1);
    const frame_height = @max(height, 1);
    if (app.width != frame_width or app.height != frame_height) {
        surface.notifyResize(.{ .width = frame_width, .height = frame_height });
        app.width = frame_width;
        app.height = frame_height;
    }

    _ = surface.beginFrame() catch return @intFromEnum(Result.frame_begin);
    const size = surface.surfaceSize();
    if (size.width == 0 or size.height == 0) {
        _ = surface.endFrame(.{ .blit_to_swapchain = true }) catch {
            return @intFromEnum(Result.frame_end);
        };
        return @intFromEnum(Result.frame_begin);
    }

    var commands = surface.commandsBegin();
    if (app.example == .textures and !app.textures_uploaded) {
        const staging_a = app.staging_a.?;
        const staging_b = app.staging_b.?;
        const region: noapi.TextureRegion = .{
            .size = .{ texture_width, texture_height, 1 },
        };
        commands.copyToTexture(app.texture_a.?, staging_a, region);
        commands.copyToTexture(app.texture_b.?, staging_b, region);
        commands.barrier(.{ .transfer = true }, .{ .fragment = true }, .{});
        app.textures_uploaded = true;
    }

    const clear_color = switch (app.example) {
        .triangle => triangleClearColor(time_ms),
        .textures => .{ 0.3, 0.3, 0.3, 1.0 },
    };
    commands.beginRendering(.{
        .color_attachments = &.{.{
            .texture = surface.currentImage(),
            .load_op = .clear,
            .store_op = .store,
            .clear_color = clear_color,
        }},
        .render_area_size = .{ size.width, size.height },
    });
    commands.setShaders(app.vertex_shader.?, app.fragment_shader.?);
    commands.setRasterState(.{ .topology = .triangle_list, .cull_mode = .none });

    switch (app.example) {
        .triangle => commands.draw(.{
            .vert_data = app.vertex_buffer.?.offset(@sizeOf(TriangleVertex)).gpu,
        }, 3, 1),
        .textures => drawTextures(app, &commands, time_ms),
    }

    commands.endRendering();
    commands.deinitTexHeap();
    _ = surface.endFrame(.{ .blit_to_swapchain = true }) catch {
        return @intFromEnum(Result.frame_end);
    };
    return @intFromEnum(Result.ok);
}

export fn noapiStop() c_int {
    if (runtime) |*app| {
        app.deinit();
        runtime = null;
    }
    return @intFromEnum(Result.ok);
}

fn initialize(example: Example) StartError!Runtime {
    var app: Runtime = .{
        .allocator = std.heap.c_allocator,
        .example = example,
    };
    errdefer app.deinit();

    const gpu = app.allocator.create(noapi.Gpu) catch return error.OutOfMemory;
    app.gpu = gpu;
    gpu.* = noapi.Gpu.init(.{
        .io = undefined, // The browser backend uses the host's WebGPU device, not std.Io.
        .allocator = app.allocator,
        .frames_in_flight = 2,
        .app_name = "noapi-web",
    }) catch return error.GpuInitialization;
    app.gpu_initialized = true;

    app.surface = noapi.Surface.initWeb(gpu, "#canvas", .{
        .extent = .{ .width = initial_width, .height = initial_height },
    }) catch return error.SurfaceInitialization;

    switch (example) {
        .triangle => try initializeTriangle(&app, gpu),
        .textures => try initializeTextures(&app, gpu),
    }
    return app;
}

fn initializeTriangle(app: *Runtime, gpu: *noapi.Gpu) StartError!void {
    app.vertex_shader = noapi.Shader.createWgsl(
        gpu,
        triangle_vertex_source,
        .vertex,
        "vertexMain",
        "triangle-vertex",
    ) catch return error.ShaderInitialization;
    app.fragment_shader = noapi.Shader.createWgsl(
        gpu,
        triangle_fragment_source,
        .fragment,
        "fragmentMain",
        "triangle-fragment",
    ) catch return error.ShaderInitialization;

    const buffer = gpu.gpuMalloc(@sizeOf(TriangleVertex) * 4, 16, .default) catch {
        return error.BufferInitialization;
    };
    app.vertex_buffer = buffer;
    const vertices: [*]TriangleVertex = @ptrCast(@alignCast(buffer.cpu));
    vertices[0] = .{ .position = .{ -2, -2, 0, 1 }, .color = .{ 1, 0, 1, 1 } };
    vertices[1] = .{ .position = .{ -0.5, -0.5, 0, 1 }, .color = .{ 1, 0.5, 0, 1 } };
    vertices[2] = .{ .position = .{ 0.5, -0.5, 0, 1 }, .color = .{ 0, 1, 0.5, 1 } };
    vertices[3] = .{ .position = .{ 0, 0.5, 0, 1 }, .color = .{ 0.25, 0, 1, 1 } };
}

fn initializeTextures(app: *Runtime, gpu: *noapi.Gpu) StartError!void {
    app.vertex_shader = noapi.Shader.createWgsl(
        gpu,
        textures_shader_source,
        .vertex,
        "vertex_main",
        "textures-vertex",
    ) catch return error.ShaderInitialization;
    app.fragment_shader = noapi.Shader.createWgsl(
        gpu,
        textures_shader_source,
        .fragment,
        "fragment_main",
        "textures-fragment",
    ) catch return error.ShaderInitialization;

    const vertex_buffer = gpu.gpuMalloc(@sizeOf(QuadVertex) * 4, 64, .default) catch {
        return error.BufferInitialization;
    };
    app.vertex_buffer = vertex_buffer;
    const vertices: [*]QuadVertex = @ptrCast(@alignCast(vertex_buffer.cpu));
    vertices[0] = .{ .pos = .{ -0.5, 0.5 }, .uv = .{ 0.0, 0.0 } };
    vertices[1] = .{ .pos = .{ 0.5, -0.5 }, .uv = .{ 1.0, 1.0 } };
    vertices[2] = .{ .pos = .{ 0.5, 0.5 }, .uv = .{ 1.0, 0.0 } };
    vertices[3] = .{ .pos = .{ -0.5, -0.5 }, .uv = .{ 0.0, 1.0 } };

    const index_buffer = gpu.gpuMalloc(@sizeOf(u32) * 6, 16, .default) catch {
        return error.BufferInitialization;
    };
    app.index_buffer = index_buffer;
    const indices: [*]u32 = @ptrCast(@alignCast(index_buffer.cpu));
    indices[0] = 0;
    indices[1] = 2;
    indices[2] = 1;
    indices[3] = 0;
    indices[4] = 1;
    indices[5] = 3;

    const staging_a = gpu.gpuMalloc(texture_bytes, 64, .default) catch {
        return error.BufferInitialization;
    };
    app.staging_a = staging_a;
    generateCheckerboard(
        staging_a.cpu[0..texture_bytes],
        32,
        .{ 255, 128, 0, 255 },
        .{ 0, 128, 255, 255 },
    );
    const staging_b = gpu.gpuMalloc(texture_bytes, 64, .default) catch {
        return error.BufferInitialization;
    };
    app.staging_b = staging_b;
    generateCheckerboard(
        staging_b.cpu[0..texture_bytes],
        16,
        .{ 0, 200, 100, 255 },
        .{ 200, 0, 200, 255 },
    );

    const texture_desc: noapi.TextureDesc = .{
        .dimensions = .{ texture_width, texture_height, 1 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    };
    app.texture_a = noapi.Texture.create(gpu, texture_desc) catch {
        return error.TextureInitialization;
    };
    app.texture_b = noapi.Texture.create(gpu, texture_desc) catch {
        return error.TextureInitialization;
    };
}

fn drawTextures(app: *Runtime, commands: *noapi.CommandBuffer, time_ms: f64) void {
    commands.setVertexInput(&vertex_bindings, &vertex_attributes);
    commands.bindVertexBuffer(0, app.vertex_buffer.?, 0);
    commands.bindTexture(0, app.texture_a.?.handle, .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mip_filter = .linear,
    });
    commands.bindTexture(1, app.texture_b.?.handle, .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mip_filter = .linear,
    });

    const seconds: f64 = time_ms / 1000.0;
    const fade: f32 = @floatCast(@mod(seconds * 1.2, 1.0));
    const fade_bits: u32 = @bitCast(fade);
    commands.drawIndexed(
        .{ .indirect = @as(u64, fade_bits) << 32 },
        app.index_buffer.?,
        .u32,
        6,
        1,
        0,
        0,
    );
}

fn triangleClearColor(time_ms: f64) [4]f32 {
    const angle: f32 = @floatCast((time_ms / 1000.0) * 1.7);
    const amount = @sin(angle) * 0.5 + 0.5;
    const channel = 0.2 + amount * 0.2;
    return .{ channel, channel, channel, 1.0 };
}

fn generateCheckerboard(
    pixels: []u8,
    block_size: u32,
    color_a: [4]u8,
    color_b: [4]u8,
) void {
    for (0..texture_height) |y| {
        for (0..texture_width) |x| {
            const color = if ((x / block_size + y / block_size) % 2 == 0)
                color_a
            else
                color_b;
            const pixel_offset = (y * texture_width + x) * 4;
            pixels[pixel_offset] = color[0];
            pixels[pixel_offset + 1] = color[1];
            pixels[pixel_offset + 2] = color[2];
            pixels[pixel_offset + 3] = color[3];
        }
    }
}

fn resultForStartError(err: StartError) Result {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.GpuInitialization => .gpu_initialization,
        error.SurfaceInitialization => .surface_initialization,
        error.ShaderInitialization => .shader_initialization,
        error.BufferInitialization => .buffer_initialization,
        error.TextureInitialization => .texture_initialization,
    };
}

comptime {
    asm (".no_dead_strip noapiStart");
    asm (".no_dead_strip noapiFrame");
    asm (".no_dead_strip noapiStop");
}
