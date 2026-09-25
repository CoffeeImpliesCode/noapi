//! Browser WebGPU adapter for the noapi API.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vk = @import("vk.zig");
const Extent2D = @import("Extent2D.zig");
const DeviceLimits = @import("DeviceLimits.zig");
const Stage = @import("Barrier.zig").Stage;
const Hazard = @import("Barrier.zig").Hazard;
const DepthState = @import("DepthState.zig");
const RasterState = @import("RasterState.zig");
const BlendState = @import("BlendState.zig");
const Viewport = @import("Viewport.zig");
const Scissor = @import("Viewport.zig").Scissor;
const PushData = @import("CommandBuffer.zig").PushData;
const BufferDesc = @import("Buffer.zig").BufferDesc;
const IndexFormat = @import("CommandBuffer.zig").IndexFormat;
const Rendering = @import("Rendering.zig");
const MemoryType = @import("GpuError.zig").MemoryType;
const GpuPtr = @import("GpuPtr.zig");
const Texture = @import("Texture.zig");
const TextureHandle = @import("TextureHandle.zig");
const TextureDesc = Texture.TextureDesc;
const TextureViewDesc = Texture.TextureViewDesc;
const SamplerDesc = Texture.SamplerDesc;
const TextureRegion = Texture.TextureRegion;
const BlitRect = Texture.BlitRect;
const Filter = Texture.Filter;
const VertexBinding = @import("VertexInput.zig").VertexBinding;
const VertexAttribute = @import("VertexInput.zig").VertexAttribute;
const TimestampQuerySet = @import("TimestampQuerySet.zig");
const TimestampInfo = TimestampQuerySet.TimestampInfo;
const FrameSchedule = @import("Gpu.zig").FrameSchedule;
const FrameResult = @import("Gpu.zig").FrameResult;
const PresentInfo = @import("Gpu.zig").PresentInfo;
const PresentFeedback = @import("Gpu.zig").PresentFeedback;

pub const WebGpuBackend = @This();

pub const CommandBufferHandle = enum(u32) { null_handle = 0, _ };
pub const TimestampQueryHandle = enum(u32) { invalid = 0, _ };
pub const ShaderHandle = enum(u32) { null_handle = 0, _ };
pub const SemaphoreHandle = enum(u32) { null_handle = 0, _ };
pub const BufferHandle = enum(u32) { null_handle = 0, _ };
pub const QueueHandle = enum(u32) { null_handle = 0, _ };

pub const DeviceIdentity = struct {
    name: []const u8,
    vendor_id: u32,
    device_id: u32,
    driver: []const u8,
};

pub const Options = struct {
    allocator: Allocator = std.heap.page_allocator,
    frames_in_flight: u32 = 2,
};

const BufferRecord = struct {
    handle: BufferHandle,
    bytes: []u8,
    alignment: std.mem.Alignment,
};
const JsVertexBinding = extern struct {
    binding: u32,
    stride: u32,
    input_rate: u32,
};

const JsVertexAttribute = extern struct {
    location: u32,
    binding: u32,
    format: u32,
    offset: u32,
};

allocator: Allocator,
frames_in_flight: u32,
buffers: std.ArrayListUnmanaged(BufferRecord) = .empty,
textures: std.ArrayListUnmanaged(TextureHandle) = .empty,
surface_extent: Extent2D = .{},
surface_ready: bool = false,

extern "env" fn noapi_webgpu_init(frames_in_flight: u32) callconv(.c) u32;
extern "env" fn noapi_webgpu_surface_init(
    selector: [*]const u8,
    selector_len: usize,
    width: u32,
    height: u32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_surface_resize(width: u32, height: u32) callconv(.c) u32;
extern "env" fn noapi_webgpu_begin_frame() callconv(.c) u32;
extern "env" fn noapi_webgpu_commands_begin() callconv(.c) u32;
extern "env" fn noapi_webgpu_commands_current() callconv(.c) u32;
extern "env" fn noapi_webgpu_end_frame(command: u32) callconv(.c) u32;
extern "env" fn noapi_webgpu_abort_frame(command: u32) callconv(.c) u32;
extern "env" fn noapi_webgpu_take_error() callconv(.c) u32;
extern "env" fn noapi_webgpu_fail(code: u32) callconv(.c) void;
extern "env" fn noapi_webgpu_get_limit(key: u32) callconv(.c) u32;
extern "env" fn noapi_webgpu_shader_create(
    source: [*]const u8,
    source_len: usize,
    stage: u32,
    entry: [*:0]const u8,
    name: [*:0]const u8,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_shader_destroy(shader: u32) callconv(.c) void;
extern "env" fn noapi_webgpu_set_shaders(
    command: u32,
    vertex: u32,
    fragment: u32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_buffer_create(size: u32) callconv(.c) u32;
extern "env" fn noapi_webgpu_buffer_destroy(buffer: u32) callconv(.c) void;
extern "env" fn noapi_webgpu_buffer_write(
    buffer: u32,
    source: [*]const u8,
    size: u32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_texture_create(
    width: u32,
    height: u32,
    depth: u32,
    mip_count: u32,
    layer_count: u32,
    format: u32,
    usage: u32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_texture_destroy(texture: u32) callconv(.c) void;
extern "env" fn noapi_webgpu_copy_to_texture(
    command: u32,
    texture: u32,
    source: [*]const u8,
    source_len: u32,
    x: i32,
    y: i32,
    z: i32,
    width: u32,
    height: u32,
    depth: u32,
    mip_level: u32,
    base_layer: u32,
    layer_count: u32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_begin_rendering(
    command: u32,
    is_swapchain: u32,
    texture: u32,
    load_op: u32,
    store_op: u32,
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    clear_a: f32,
    offset_x: i32,
    offset_y: i32,
    width: u32,
    height: u32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_end_rendering(command: u32) callconv(.c) u32;
extern "env" fn noapi_webgpu_push_graphics(
    command: u32,
    buffer_id: u32,
    byte_offset: u32,
    fade: f32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_set_raster(
    command: u32,
    topology: u32,
    cull_mode: u32,
    front_face: u32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_set_vertex_input(
    command: u32,
    bindings: [*]const u8,
    binding_count: usize,
    attributes: [*]const u8,
    attribute_count: usize,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_bind_vertex_buffer(
    command: u32,
    binding: u32,
    buffer: u32,
    offset: u32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_bind_index_buffer(
    command: u32,
    buffer: u32,
    offset: u32,
    format: u32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_bind_texture(
    command: u32,
    slot: u32,
    texture: u32,
    min_filter: u32,
    mag_filter: u32,
    mip_filter: u32,
    address_u: u32,
    address_v: u32,
    address_w: u32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_set_viewport(
    command: u32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    depth_min: f32,
    depth_max: f32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_set_scissor(
    command: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_set_blend(command: u32, enabled: u32) callconv(.c) u32;
extern "env" fn noapi_webgpu_draw(
    command: u32,
    vertex_count: u32,
    instance_count: u32,
) callconv(.c) u32;
extern "env" fn noapi_webgpu_draw_indexed(
    command: u32,
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
) callconv(.c) u32;

pub fn init(options: Options) !*WebGpuBackend {
    if (options.frames_in_flight == 0) return error.InvalidFramesInFlight;
    if (noapi_webgpu_init(options.frames_in_flight) == 0) return error.WebGpuUnavailable;

    const backend = try options.allocator.create(WebGpuBackend);
    backend.* = .{
        .allocator = options.allocator,
        .frames_in_flight = options.frames_in_flight,
    };
    return backend;
}

pub fn deinit(self: *WebGpuBackend) void {
    for (self.buffers.items) |buffer| {
        noapi_webgpu_buffer_destroy(@intFromEnum(buffer.handle));
        self.allocator.rawFree(buffer.bytes, buffer.alignment, @returnAddress());
    }
    for (self.textures.items) |texture| {
        if (!texture.isSwapchain()) noapi_webgpu_texture_destroy(texture.texture.id);
    }
    self.buffers.deinit(self.allocator);
    self.textures.deinit(self.allocator);
    self.* = undefined;
}

pub fn flushPendingFrees(_: *WebGpuBackend) !void {}

pub fn waitIdle(_: *WebGpuBackend) !void {
    // WebGPU exposes asynchronous completion, so this synchronous API cannot wait safely.
    return error.SynchronousWaitUnsupported;
}

pub fn commandsBegin(_: *WebGpuBackend) !CommandBufferHandle {
    const handle = noapi_webgpu_commands_begin();
    if (handle == 0) return error.WebGpuCommandFailed;
    return @enumFromInt(handle);
}

pub fn numWindows(self: *const WebGpuBackend) u32 {
    return @intFromBool(self.surface_ready);
}

pub fn deviceLimits(_: *const WebGpuBackend) DeviceLimits {
    return .{
        .max_anisotropy = 1,
        .max_texture_dimension_2d = noapi_webgpu_get_limit(0),
        .max_texture_dimension_3d = noapi_webgpu_get_limit(1),
        .max_texture_array_layers = noapi_webgpu_get_limit(2),
        .max_push_constants_size = 0,
        .max_viewports = 1,
        .max_color_attachments = noapi_webgpu_get_limit(3),
        .max_framebuffer_width = noapi_webgpu_get_limit(0),
        .max_framebuffer_height = noapi_webgpu_get_limit(0),
        .max_framebuffer_layers = noapi_webgpu_get_limit(2),
        .max_compute_work_group_invocations = noapi_webgpu_get_limit(4),
        .max_compute_shared_memory_size = noapi_webgpu_get_limit(5),
        .min_uniform_buffer_offset_alignment = 256,
        .min_storage_buffer_offset_alignment = 256,
        .shader_object = false,
        .descriptor_buffer = false,
        .buffer_device_address = false,
        .dynamic_rendering = true,
        .timeline_semaphore = false,
        .descriptor_indexing = false,
    };
}

pub fn timestampInfo(_: *const WebGpuBackend) ?TimestampInfo {
    return null;
}

pub fn timestampQuerySetCreate(_: *WebGpuBackend, _: u32) !TimestampQueryHandle {
    return error.TimestampQueriesUnsupported;
}

pub fn timestampQuerySetDestroy(self: *WebGpuBackend, _: TimestampQueryHandle) void {
    self.markUnsupported(20);
}

pub fn timestampQuerySetRead(
    self: *WebGpuBackend,
    _: TimestampQueryHandle,
    _: u32,
    _: []u64,
) !void {
    _ = self;
    return error.TimestampQueriesUnsupported;
}

pub fn cmdTimestampReset(
    self: *WebGpuBackend,
    _: CommandBufferHandle,
    _: TimestampQueryHandle,
    _: u32,
    _: u32,
) !void {
    _ = self;
    return error.TimestampQueriesUnsupported;
}

pub fn cmdTimestampWrite(
    self: *WebGpuBackend,
    _: CommandBufferHandle,
    _: TimestampQueryHandle,
    _: u32,
    _: TimestampQuerySet.TimestampStage,
) !void {
    _ = self;
    return error.TimestampQueriesUnsupported;
}

pub fn shaderCreate(self: *WebGpuBackend, _: []const u32, _: u2, _: [:0]const u8) !ShaderHandle {
    _ = self;
    return error.UnsupportedShaderFormat;
}

pub fn shaderCreateWgsl(
    _: *WebGpuBackend,
    source: []const u8,
    stage: u2,
    entry: [:0]const u8,
    name: [:0]const u8,
) !ShaderHandle {
    const stage_id: u32 = switch (stage) {
        0 => 0,
        1 => 1,
        2 => 2,
        else => return error.InvalidShaderStage,
    };
    const id = noapi_webgpu_shader_create(source.ptr, source.len, stage_id, entry, name);
    if (id == 0) return error.ShaderCompileFailed;
    return @enumFromInt(id);
}

pub fn shaderDestroy(_: *WebGpuBackend, shader: ShaderHandle) void {
    noapi_webgpu_shader_destroy(@intFromEnum(shader));
}

pub fn semaphoreCreate(_: *WebGpuBackend, _: u64) !SemaphoreHandle {
    return error.TimelineSemaphoresUnsupported;
}

pub fn semaphoreDestroy(self: *WebGpuBackend, _: SemaphoreHandle) void {
    self.markUnsupported(21);
}

pub fn semaphoreWait(_: *WebGpuBackend, _: SemaphoreHandle, _: u64) !void {
    return error.TimelineSemaphoresUnsupported;
}

pub fn bufferCreate(self: *WebGpuBackend, desc: BufferDesc) !GpuPtr {
    return self.gpuMalloc(desc.size, 64, .default);
}

pub fn bufferDestroy(self: *WebGpuBackend, ptr: GpuPtr) void {
    self.gpuFree(ptr);
}

pub fn textureSizeAndAlign(_: *WebGpuBackend, desc: TextureDesc) struct { size: u64, alignment: u64 } {
    if (desc.format != .rgba8_unorm) return .{ .size = 0, .alignment = 0 };
    const size = @as(u64, desc.dimensions[0]) * desc.dimensions[1] * desc.dimensions[2] * 4;
    return .{ .size = size, .alignment = 256 };
}

pub fn textureCreate(
    self: *WebGpuBackend,
    desc: TextureDesc,
    _: GpuPtr,
    _: u32,
) !TextureHandle {
    if (desc.dimensions[0] == 0 or desc.dimensions[1] == 0 or desc.dimensions[2] == 0) {
        return error.InvalidTextureExtent;
    }
    if (desc.type != .@"2d" or desc.sample_count != 1) return error.UnsupportedTextureType;
    if (desc.format != .rgba8_unorm) return error.UnsupportedTextureFormat;
    const usage: u32 = @as(u32, @intFromBool(desc.usage.sampled)) |
        (@as(u32, @intFromBool(desc.usage.storage)) << 1) |
        (@as(u32, @intFromBool(desc.usage.transfer_src)) << 2) |
        (@as(u32, @intFromBool(desc.usage.color_attachment)) << 3) |
        (@as(u32, @intFromBool(desc.usage.depth_stencil_attachment)) << 4);
    const id = noapi_webgpu_texture_create(
        desc.dimensions[0],
        desc.dimensions[1],
        desc.dimensions[2],
        desc.mip_count,
        desc.layer_count,
        @intFromEnum(desc.format),
        usage,
    );
    if (id == 0) return error.WebGpuResourceCreationFailed;
    const texture: TextureHandle = .{ .texture = .{ .id = id, .birth_frame = 0 } };
    self.textures.append(self.allocator, texture) catch |err| {
        noapi_webgpu_texture_destroy(id);
        return err;
    };
    return texture;
}

pub fn textureDestroy(self: *WebGpuBackend, texture: TextureHandle) void {
    if (texture.isSwapchain()) return;
    noapi_webgpu_texture_destroy(texture.texture.id);
    for (self.textures.items, 0..) |stored, index| {
        if (stored.texture.id == texture.texture.id) {
            _ = self.textures.swapRemove(index);
            return;
        }
    }
    self.markUnsupported(22);
}

pub fn textureViewDescriptor(self: *WebGpuBackend, _: TextureHandle, _: TextureViewDesc) u64 {
    self.markUnsupported(23);
    return 0;
}

pub fn textureRwViewDescriptor(self: *WebGpuBackend, _: TextureHandle, _: TextureViewDesc) u64 {
    self.markUnsupported(24);
    return 0;
}

pub fn samplerDescriptor(self: *WebGpuBackend, _: SamplerDesc) u64 {
    self.markUnsupported(25);
    return 0;
}

pub fn descHeapCreate(_: *WebGpuBackend, _: u32, _: u32, _: u32) !u32 {
    return error.DescriptorHeapsUnsupported;
}

pub fn descHeapDestroy(self: *WebGpuBackend, _: u32) void {
    self.markUnsupported(26);
}

pub fn descHeapSetTextures(self: *WebGpuBackend, _: u32, _: u32, _: []const u64) void {
    self.markUnsupported(27);
}

pub fn descHeapSetTexturesRw(self: *WebGpuBackend, _: u32, _: u32, _: []const u64) void {
    self.markUnsupported(28);
}

pub fn descHeapSetSamplers(self: *WebGpuBackend, _: u32, _: u32, _: []const u64) void {
    self.markUnsupported(29);
}

pub fn queueSubmit(_: *WebGpuBackend, _: []const CommandBufferHandle) !void {
    return error.SurfaceSubmissionRequired;
}

pub fn queueSubmitSignal(
    _: *WebGpuBackend,
    _: []const CommandBufferHandle,
    _: SemaphoreHandle,
    _: u64,
) !void {
    return error.TimelineSemaphoresUnsupported;
}

pub fn queueSubmitWaitSignal(
    _: *WebGpuBackend,
    _: []const CommandBufferHandle,
    _: SemaphoreHandle,
    _: u64,
    _: SemaphoreHandle,
    _: u64,
) !void {
    return error.TimelineSemaphoresUnsupported;
}

pub fn queueWaitIdle(_: *WebGpuBackend) !void {
    return error.SynchronousWaitUnsupported;
}

pub fn deviceIdentity(_: *const WebGpuBackend) DeviceIdentity {
    return .{ .name = "Browser WebGPU device", .vendor_id = 0, .device_id = 0, .driver = "WebGPU" };
}

pub fn gpuMalloc(self: *WebGpuBackend, size: u64, alignment: u29, mem_type: MemoryType) !GpuPtr {
    if (size == 0) return .{};
    if (mem_type == .readback) return error.ReadbackUnsupported;
    if (size > std.math.maxInt(u32) or size > std.math.maxInt(usize)) return error.OutOfMemory;
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.UnsupportedAlignment;

    const requested_alignment = std.mem.Alignment.fromByteUnits(alignment);
    const bytes = (self.allocator.rawAlloc(@intCast(size), requested_alignment, @returnAddress()) orelse
        return error.OutOfMemory)[0..@intCast(size)];
    errdefer self.allocator.rawFree(bytes, requested_alignment, @returnAddress());
    const id = noapi_webgpu_buffer_create(@intCast(size));
    if (id == 0) return error.OutOfMemory;
    errdefer noapi_webgpu_buffer_destroy(id);
    if (id == std.math.maxInt(u32)) return error.WebGpuResourceCreationFailed;
    const handle: BufferHandle = @enumFromInt(id);
    try self.buffers.append(self.allocator, .{
        .handle = handle,
        .bytes = bytes,
        .alignment = requested_alignment,
    });
    return .{ .cpu = bytes.ptr, .gpu = @as(u64, id) << 32, .vk_buffer = id };
}

pub fn gpuFree(self: *WebGpuBackend, ptr: GpuPtr) void {
    const handle: BufferHandle = @enumFromInt(ptr.vk_buffer);
    for (self.buffers.items, 0..) |buffer, index| {
        if (buffer.handle == handle) {
            noapi_webgpu_buffer_destroy(@intFromEnum(handle));
            self.allocator.rawFree(buffer.bytes, buffer.alignment, @returnAddress());
            _ = self.buffers.swapRemove(index);
            return;
        }
    }
    if (ptr.vk_buffer != 0) self.markUnsupported(30);
}

pub fn gpuHostToDevicePointer(self: *WebGpuBackend, cpu_ptr: [*]u8) GpuPtr {
    const address = @intFromPtr(cpu_ptr);
    for (self.buffers.items) |buffer| {
        const base = @intFromPtr(buffer.bytes.ptr);
        if (address >= base and address - base < buffer.bytes.len) {
            const id = @intFromEnum(buffer.handle);
            const offset: u32 = @intCast(address - base);
            return .{ .cpu = cpu_ptr, .gpu = (@as(u64, id) << 32) | offset, .vk_buffer = id };
        }
    }
    self.markUnsupported(31);
    return .{ .cpu = cpu_ptr };
}

fn bufferRecord(self: *WebGpuBackend, handle: BufferHandle) ?BufferRecord {
    for (self.buffers.items) |buffer| {
        if (buffer.handle == handle) return buffer;
    }
    return null;
}

fn syncBuffer(self: *WebGpuBackend, handle: BufferHandle) bool {
    const buffer = self.bufferRecord(handle) orelse {
        self.markUnsupported(32);
        return false;
    };
    return noapi_webgpu_buffer_write(
        @intFromEnum(handle),
        buffer.bytes.ptr,
        @intCast(buffer.bytes.len),
    ) != 0;
}

pub fn cmdBarrier(_: *WebGpuBackend, _: CommandBufferHandle, _: Stage, _: Stage, _: Hazard) void {
    // WebGPU tracks resource hazards and orders queue writes before submitted commands.
}

pub fn cmdBufBeginZone(self: *WebGpuBackend, _: CommandBufferHandle, _: anytype) void {
    self.markUnsupported(33);
}

pub fn cmdBufEndZone(self: *WebGpuBackend, _: CommandBufferHandle) void {
    self.markUnsupported(34);
}

pub fn cmdPushConstantsGraphics(self: *WebGpuBackend, command: CommandBufferHandle, data: PushData) void {
    const texture_slots: u64 = @as(u64, 1) << 32;
    if (data.scene_bda != 0 or data.perm_bda != 0) {
        self.markUnsupported(35);
        return;
    }
    if (data.frag_data != 0 and data.frag_data != texture_slots) {
        self.markUnsupported(36);
        return;
    }
    if (@as(u32, @truncate(data.indirect)) != 0) {
        self.markUnsupported(37);
        return;
    }
    var buffer_id: u32 = 0;
    var byte_offset: u32 = 0;
    if (data.vert_data != 0) {
        buffer_id = @truncate(data.vert_data >> 32);
        byte_offset = @truncate(data.vert_data);
        const buffer = self.bufferRecord(@enumFromInt(buffer_id)) orelse {
            self.markUnsupported(35);
            return;
        };
        if (buffer_id == 0 or byte_offset & 3 != 0 or byte_offset >= buffer.bytes.len) {
            self.markUnsupported(35);
            return;
        }
        if (!self.syncBuffer(buffer.handle)) return;
    }
    const fade_bits: u32 = @truncate(data.indirect >> 32);
    if (noapi_webgpu_push_graphics(@intFromEnum(command), buffer_id, byte_offset, @bitCast(fade_bits)) == 0) {
        self.markUnsupported(38);
    }
}

pub fn cmdPushConstantsCompute(self: *WebGpuBackend, _: CommandBufferHandle, _: u64) void {
    self.markUnsupported(39);
}

pub fn cmdSetShaders(
    self: *WebGpuBackend,
    command: CommandBufferHandle,
    vertex: ShaderHandle,
    fragment: ShaderHandle,
) void {
    if (noapi_webgpu_set_shaders(@intFromEnum(command), @intFromEnum(vertex), @intFromEnum(fragment)) == 0) {
        self.markUnsupported(40);
    }
}

pub fn cmdSetComputeShader(self: *WebGpuBackend, _: CommandBufferHandle, _: ShaderHandle) void {
    self.markUnsupported(41);
}

pub fn cmdSetDepthState(self: *WebGpuBackend, _: CommandBufferHandle, _: DepthState) void {
    self.markUnsupported(42);
}

pub fn cmdSetRasterState(self: *WebGpuBackend, command: CommandBufferHandle, state: RasterState) void {
    if (state.alpha_to_coverage or state.cull_mode == .all or state.topology == .triangle_fan or
        state.topology == .patch_list or state.topology == .line_list_with_adjacency or
        state.topology == .line_strip_with_adjacency or state.topology == .triangle_list_with_adjacency or
        state.topology == .triangle_strip_with_adjacency)
    {
        self.markUnsupported(43);
        return;
    }
    if (noapi_webgpu_set_raster(
        @intFromEnum(command),
        @intFromEnum(state.topology),
        @intFromEnum(state.cull_mode),
        @intFromEnum(state.front_face),
    ) == 0) {
        self.markUnsupported(44);
    }
}

pub fn cmdSetBlendState(self: *WebGpuBackend, command: CommandBufferHandle, state: BlendState) void {
    if (state.enable or state.color_write_mask != .{}) {
        self.markUnsupported(45);
        return;
    }
    self.cmdSetBlendEnable(command, false);
}

pub fn cmdSetBlendEnable(self: *WebGpuBackend, command: CommandBufferHandle, enable: bool) void {
    if (enable) {
        self.markUnsupported(46);
        return;
    }
    if (noapi_webgpu_set_blend(@intFromEnum(command), 0) == 0) self.markUnsupported(47);
}

pub fn cmdSetViewport(self: *WebGpuBackend, command: CommandBufferHandle, viewport: Viewport) void {
    if (noapi_webgpu_set_viewport(
        @intFromEnum(command),
        viewport.x,
        viewport.y,
        viewport.width,
        viewport.height,
        viewport.depth_min,
        viewport.depth_max,
    ) == 0) {
        self.markUnsupported(47);
    }
}

pub fn cmdSetScissor(self: *WebGpuBackend, command: CommandBufferHandle, scissor: Scissor) void {
    if (noapi_webgpu_set_scissor(
        @intFromEnum(command),
        scissor.x,
        scissor.y,
        scissor.width,
        scissor.height,
    ) == 0) {
        self.markUnsupported(48);
    }
}

pub fn cmdBindDescriptorSets(self: *WebGpuBackend, _: CommandBufferHandle, _: u32) void {
    self.markUnsupported(49);
}

pub fn cmdBindTexture(
    self: *WebGpuBackend,
    command: CommandBufferHandle,
    slot: u32,
    texture: TextureHandle,
    sampler: ?SamplerDesc,
) void {
    if (slot > 1 or texture.isSwapchain()) {
        self.markUnsupported(50);
        return;
    }
    const sampled = sampler orelse {
        self.markUnsupported(51);
        return;
    };
    if (sampled.mip_lod_bias != 0 or sampled.min_lod != 0 or sampled.max_lod != 32 or sampled.max_anisotropy != 1) {
        self.markUnsupported(52);
        return;
    }
    if (noapi_webgpu_bind_texture(
        @intFromEnum(command),
        slot,
        texture.texture.id,
        @intFromEnum(sampled.min_filter),
        @intFromEnum(sampled.mag_filter),
        @intFromEnum(sampled.mip_filter),
        @intFromEnum(sampled.address_mode_u),
        @intFromEnum(sampled.address_mode_v),
        @intFromEnum(sampled.address_mode_w),
    ) == 0) {
        self.markUnsupported(52);
    }
}

pub fn cmdBeginRendering(self: *WebGpuBackend, command: CommandBufferHandle, desc: Rendering) void {
    if (desc.color_attachments.len != 1 or desc.depth_attachment != null or
        desc.stencil_attachment != null or desc.color_attachments[0].resolve_texture != null)
    {
        self.markUnsupported(53);
        return;
    }
    const attachment = desc.color_attachments[0];
    if (noapi_webgpu_begin_rendering(
        @intFromEnum(command),
        @intFromBool(attachment.texture.isSwapchain()),
        if (attachment.texture.isSwapchain()) 0 else attachment.texture.texture.id,
        @intFromEnum(attachment.load_op),
        @intFromEnum(attachment.store_op),
        attachment.clear_color[0],
        attachment.clear_color[1],
        attachment.clear_color[2],
        attachment.clear_color[3],
        desc.render_area_offset[0],
        desc.render_area_offset[1],
        desc.render_area_size[0],
        desc.render_area_size[1],
    ) == 0) {
        self.markUnsupported(54);
    }
}

pub fn cmdEndRendering(self: *WebGpuBackend, command: CommandBufferHandle) void {
    if (noapi_webgpu_end_rendering(@intFromEnum(command)) == 0) self.markUnsupported(55);
}

pub fn cmdDraw(self: *WebGpuBackend, command: CommandBufferHandle, vertex_count: u32, instance_count: u32) void {
    if (noapi_webgpu_draw(@intFromEnum(command), vertex_count, instance_count) == 0) {
        self.markUnsupported(56);
    }
}

pub fn cmdBindVertexBuffer(
    self: *WebGpuBackend,
    command: CommandBufferHandle,
    binding: u32,
    buffer: BufferHandle,
    offset: u64,
) void {
    if (offset > std.math.maxInt(u32) or !self.syncBuffer(buffer)) {
        self.markUnsupported(57);
        return;
    }
    if (noapi_webgpu_bind_vertex_buffer(
        @intFromEnum(command),
        binding,
        @intFromEnum(buffer),
        @intCast(offset),
    ) == 0) {
        self.markUnsupported(58);
    }
}

pub fn cmdSetVertexInput(
    self: *WebGpuBackend,
    command: CommandBufferHandle,
    bindings: []const VertexBinding,
    attributes: []const VertexAttribute,
) void {
    if (bindings.len > 8 or attributes.len > 16) {
        self.markUnsupported(59);
        return;
    }
    var js_bindings: [8]JsVertexBinding = undefined;
    var js_attributes: [16]JsVertexAttribute = undefined;
    for (bindings, 0..) |binding, index| {
        js_bindings[index] = .{
            .binding = binding.binding,
            .stride = binding.stride,
            .input_rate = binding.input_rate,
        };
    }
    for (attributes, 0..) |attribute, index| {
        js_attributes[index] = .{
            .location = attribute.location,
            .binding = attribute.binding,
            .format = attribute.format,
            .offset = attribute.offset,
        };
    }
    if (noapi_webgpu_set_vertex_input(
        @intFromEnum(command),
        @ptrCast(&js_bindings),
        bindings.len,
        @ptrCast(&js_attributes),
        attributes.len,
    ) == 0) {
        self.markUnsupported(59);
    }
}

pub fn cmdBindIndexBuffer(
    self: *WebGpuBackend,
    command: CommandBufferHandle,
    buffer: BufferHandle,
    offset: u64,
    format: IndexFormat,
) void {
    if ((format != .u16 and format != .u32) or offset > std.math.maxInt(u32)) {
        self.markUnsupported(60);
        return;
    }
    if (!self.syncBuffer(buffer)) return;
    if (noapi_webgpu_bind_index_buffer(
        @intFromEnum(command),
        @intFromEnum(buffer),
        @intCast(offset),
        @intFromEnum(format),
    ) == 0) {
        self.markUnsupported(61);
    }
}

pub fn cmdDrawIndexed(
    self: *WebGpuBackend,
    command: CommandBufferHandle,
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
) void {
    if (noapi_webgpu_draw_indexed(
        @intFromEnum(command),
        index_count,
        instance_count,
        first_index,
        vertex_offset,
    ) == 0) {
        self.markUnsupported(62);
    }
}

pub fn cmdDrawIndexedIndirect(
    self: *WebGpuBackend,
    _: CommandBufferHandle,
    _: BufferHandle,
    _: u64,
    _: u32,
    _: u32,
) void {
    self.markUnsupported(63);
}

pub fn cmdDrawIndexedIndirectMulti(
    self: *WebGpuBackend,
    _: CommandBufferHandle,
    _: BufferHandle,
    _: u64,
    _: u32,
    _: BufferHandle,
    _: u64,
    _: u32,
) void {
    self.markUnsupported(64);
}

pub fn cmdDispatch(self: *WebGpuBackend, _: CommandBufferHandle, _: u32, _: u32, _: u32) void {
    self.markUnsupported(65);
}

pub fn cmdDispatchIndirect(self: *WebGpuBackend, _: CommandBufferHandle, _: BufferHandle, _: u64) void {
    self.markUnsupported(66);
}

pub fn cmdMemCopy(self: *WebGpuBackend, _: CommandBufferHandle, _: BufferHandle, _: BufferHandle, _: u64) void {
    self.markUnsupported(67);
}

pub fn cmdCopyToTexture(
    self: *WebGpuBackend,
    command: CommandBufferHandle,
    texture: TextureHandle,
    source: BufferHandle,
    region: TextureRegion,
) void {
    const buffer = self.bufferRecord(source) orelse {
        self.markUnsupported(68);
        return;
    };
    const needed = @as(u64, region.size[0]) * region.size[1] * region.size[2] * 4;
    if (needed > buffer.bytes.len or !textureExists(self.textures.items, texture)) {
        self.markUnsupported(69);
        return;
    }
    if (noapi_webgpu_copy_to_texture(
        @intFromEnum(command),
        texture.texture.id,
        buffer.bytes.ptr,
        @intCast(needed),
        region.rect[0],
        region.rect[1],
        region.rect[2],
        region.size[0],
        region.size[1],
        region.size[2],
        region.mip_level,
        region.base_layer,
        region.layer_count,
    ) == 0) {
        self.markUnsupported(70);
    }
}

pub fn cmdCopyFromTexture(
    self: *WebGpuBackend,
    _: CommandBufferHandle,
    _: TextureHandle,
    _: BufferHandle,
    _: TextureRegion,
) void {
    self.markUnsupported(71);
}

pub fn cmdBlitTexture(
    self: *WebGpuBackend,
    _: CommandBufferHandle,
    _: TextureHandle,
    _: BlitRect,
    _: TextureHandle,
    _: BlitRect,
    _: Filter,
) void {
    self.markUnsupported(72);
}

pub fn cmdAddWaitSemaphore(
    self: *WebGpuBackend,
    _: u32,
    _: SemaphoreHandle,
    _: u64,
) void {
    self.markUnsupported(73);
}

pub fn cmdAddSignalSemaphore(
    self: *WebGpuBackend,
    _: u32,
    _: SemaphoreHandle,
    _: u64,
) void {
    self.markUnsupported(74);
}

pub fn cmdBeginDebugLabel(self: *WebGpuBackend, _: CommandBufferHandle, _: [:0]const u8, _: [4]f32) void {
    self.markUnsupported(75);
}

pub fn cmdEndDebugLabel(self: *WebGpuBackend, _: CommandBufferHandle) void {
    self.markUnsupported(76);
}

pub fn cmdInsertDebugLabel(self: *WebGpuBackend, _: CommandBufferHandle, _: [:0]const u8, _: [4]f32) void {
    self.markUnsupported(77);
}

pub fn addWindow(
    self: *WebGpuBackend,
    _: vk.SurfaceKHR,
    _: Extent2D,
    _: vk.PresentModeKHR,
) !u32 {
    _ = self;
    return error.WebGpuRequiresCanvasSurface;
}

pub fn addWebSurface(self: *WebGpuBackend, selector: []const u8, extent: Extent2D) !u32 {
    if (self.surface_ready) return error.MultipleWebSurfacesUnsupported;
    if (selector.len == 0 or extent.width == 0 or extent.height == 0) return error.InvalidSurface;
    if (noapi_webgpu_surface_init(selector.ptr, selector.len, extent.width, extent.height) == 0) {
        return error.WebGpuSurfaceUnavailable;
    }
    self.surface_extent = extent;
    self.surface_ready = true;
    return 0;
}

pub fn removeWindow(self: *WebGpuBackend, index: u32) void {
    if (index != 0 or !self.surface_ready) {
        self.markUnsupported(78);
        return;
    }
    self.surface_ready = false;
}

pub fn beginFrame(self: *WebGpuBackend, index: u32) !FrameSchedule {
    if (index != 0 or !self.surface_ready) return error.InvalidSurface;
    if (noapi_webgpu_take_error() != 0) return error.WebGpuCommandFailed;
    if (noapi_webgpu_begin_frame() == 0) return error.WebGpuCommandFailed;
    return .{ .next_vblank_us = 0, .swapchain_recreated = false };
}

pub fn currentSwapchainImage(_: *const WebGpuBackend, index: u32) TextureHandle {
    return .{ .tag = .swapchain, .swapchain = .{ .window_index = index, .image_index = 0 } };
}

pub fn endFrame(
    self: *WebGpuBackend,
    index: u32,
    present: ?PresentInfo,
) !FrameResult {
    if (index != 0 or !self.surface_ready) return error.InvalidSurface;
    const command = noapi_webgpu_commands_current();
    if (command == 0) return error.WebGpuCommandFailed;
    if (present) |info| {
        if (!info.blit_to_swapchain) {
            if (noapi_webgpu_abort_frame(command) == 0) return error.WebGpuCommandFailed;
            return error.UnsupportedPresentOperation;
        }
        if (info.timing_id != null) {
            if (noapi_webgpu_abort_frame(command) == 0) return error.WebGpuCommandFailed;
            return error.PresentTimingUnsupported;
        }
    }
    const result = noapi_webgpu_end_frame(command);
    const bridge_error = noapi_webgpu_take_error();
    if (result == 0) return error.WebGpuCommandFailed;
    if (bridge_error != 0) return error.WebGpuCommandFailed;
    return .{ .gpu_blocked_ns = 0 };
}

pub fn getCurrentCmdBuf(_: *WebGpuBackend, index: u32) CommandBufferHandle {
    if (index != 0) {
        noapi_webgpu_fail(79);
        return .null_handle;
    }
    const command = noapi_webgpu_commands_begin();
    return if (command == 0) .null_handle else @enumFromInt(command);
}

pub fn surfaceSize(self: *const WebGpuBackend, index: u32) Extent2D {
    if (index != 0 or !self.surface_ready) return .{};
    return self.surface_extent;
}

pub fn notifyResize(self: *WebGpuBackend, index: u32, extent: Extent2D) void {
    if (index != 0 or !self.surface_ready or extent.width == 0 or extent.height == 0) {
        self.markUnsupported(80);
        return;
    }
    if (noapi_webgpu_surface_resize(extent.width, extent.height) == 0) {
        self.markUnsupported(81);
        return;
    }
    self.surface_extent = extent;
}

pub fn presentTimingSupported(_: *const WebGpuBackend, _: u32) bool {
    return false;
}

pub fn pollPresentFeedback(_: *WebGpuBackend, _: u32, _: []PresentFeedback) !usize {
    return error.PresentTimingUnsupported;
}

pub fn instanceHandle(_: *const WebGpuBackend) vk.Instance {
    return .null_handle;
}

pub fn markUnsupported(_: *WebGpuBackend, code: u32) void {
    noapi_webgpu_fail(code);
}

fn textureExists(textures: []const TextureHandle, target: TextureHandle) bool {
    for (textures) |texture| {
        if (!texture.isSwapchain() and texture.texture.id == target.texture.id) return true;
    }
    return false;
}
