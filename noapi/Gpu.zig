//! Gpu — the "no graphics API" graphics context.
//! Follows mr_gpu's pattern: plain struct, opaque-handle resource types,
//! all resource methods take *Gpu.

const std = @import("std");
const vk = @import("vk.zig");
const VkBackend = @import("VkBackend.zig").VkBackend;

const Shader = @import("Shader.zig");
const Semaphore = @import("Semaphore.zig");
const Buffer = @import("Buffer.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const Texture = @import("Texture.zig");
const DescriptorHeap = @import("DescriptorHeap.zig");

// Imports for types used internally (no longer re-exported — root.zig handles that)
const TextureHandle = @import("TextureHandle.zig");
const DeviceLimits = @import("DeviceLimits.zig");
const GpuPtr = @import("GpuPtr.zig");
const GpuError = @import("GpuError.zig").GpuError;
const MemoryType = @import("GpuError.zig").MemoryType;
const ShaderStage = @import("Shader.zig").ShaderStage;
const BufferDesc = @import("Buffer.zig").BufferDesc;
const TextureDesc = @import("Texture.zig").TextureDesc;
const TextureViewDesc = @import("Texture.zig").TextureViewDesc;
const SamplerDesc = @import("Texture.zig").SamplerDesc;
const Vertex = @import("Vertex.zig");
const Rect = @import("Rect.zig");
const VertexBinding = @import("VertexInput.zig").VertexBinding;
const VertexAttribute = @import("VertexInput.zig").VertexAttribute;

pub const Gpu = @This();

pub const Backend = VkBackend;
pub const CommandBufferHandle = VkBackend.CommandBufferHandle;
pub const ShaderHandle = VkBackend.ShaderHandle;
pub const SemaphoreHandle = VkBackend.SemaphoreHandle;
pub const BufferHandle = VkBackend.BufferHandle;
pub const QueueHandle = VkBackend.QueueHandle;

backend: VkBackend,
frames_in_flight: u5,
frame_index: u5 = 0,

pub const Options = struct {
    frames_in_flight: u5 = 2,
    validation: bool = false,
    app_name: [:0]const u8 = "noapi",
    loader: VkBackend.Options.Loader = .{},
    io: std.Io,
    allocator: std.mem.Allocator = std.heap.page_allocator,
};

pub fn init(options: Options) !Gpu {
    return .{
        .backend = try VkBackend.init(.{
            .app_name = options.app_name,
            .validation = options.validation,
            .frames_in_flight = options.frames_in_flight,
            .loader = options.loader,
            .io = options.io,
            .allocator = options.allocator,
        }),
        .frames_in_flight = options.frames_in_flight,
    };
}

pub fn deinit(self: *Gpu) void {
    self.backend.deinit();
}

pub fn waitIdle(self: *Gpu) void {
    self.backend.waitIdle();
}

pub fn commandsBegin(self: *Gpu) !CommandBuffer {
    const handle = try self.backend.commandsBegin();
    return CommandBuffer{ .gpu = self, .handle = handle };
}

pub fn commandsEnd(self: *Gpu, cmd: CommandBuffer) void {
    self.backend.commandsEnd(cmd.handle);
}

pub fn numSurfaces(self: *const Gpu) u32 {
    return self.backend.numWindows();
}
pub fn deviceLimits(self: *const Gpu) DeviceLimits {
    return self.backend.deviceLimits();
}

// ── Handle types (opaque, mr_gpu style) ─────────────────────
// Handles are defined in their respective file-struct files.
// Gpu re-exports them via root.zig.

// ── Handle-based resource methods ────────────────────────────

pub fn shaderCreate(self: *Gpu, spv: []const u32, stage: ShaderStage, entry: [:0]const u8, name: [:0]const u8) !Shader {
    _ = name;
    const handle = try self.backend.shaderCreate(spv, @intFromEnum(stage), entry);
    return Shader{ .gpu = self, .handle = handle, .stage = stage };
}

pub fn shaderDestroy(self: *Gpu, shader: Shader) void {
    self.backend.shaderDestroy(shader.handle);
}

pub fn semaphoreCreate(self: *Gpu, initial: u64) !Semaphore {
    return Semaphore{ .gpu = self, .handle = try self.backend.semaphoreCreate(initial) };
}
pub fn semaphoreDestroy(self: *Gpu, sem: Semaphore) void {
    self.backend.semaphoreDestroy(sem.handle);
}

pub fn bufferCreate(self: *Gpu, desc: BufferDesc) !Buffer {
    const ptr = try self.gpuMalloc(desc.size, 64, .gpu);
    return Buffer{ .gpu = self, .handle = @enumFromInt(ptr.vk_buffer), .gpu_ptr = ptr };
}
pub fn bufferDestroy(self: *Gpu, buf: Buffer) void {
    self.gpuFree(buf.gpu_ptr);
}

pub fn textureSizeAndAlign(self: *Gpu, desc: TextureDesc) @TypeOf(self.backend.textureSizeAndAlign(desc)) {
    return self.backend.textureSizeAndAlign(desc);
}
pub fn textureCreate(self: *Gpu, desc: TextureDesc) !TextureHandle {
    return self.backend.textureCreate(desc, .{}, 0);
}
pub fn textureDestroy(self: *Gpu, tex: TextureHandle) void {
    self.backend.textureDestroy(tex);
}

pub fn textureViewDescriptor(self: *Gpu, tex: TextureHandle, view_desc: TextureViewDesc) u64 {
    return self.backend.textureViewDescriptor(tex, view_desc);
}
pub fn descHeapSetTexturesRw(self: *Gpu, heap: DescriptorHeap, start_idx: u32, descriptors: []const u64) void {
    self.backend.descHeapSetTexturesRw(heap.index, start_idx, descriptors);
}
pub fn textureRwViewDescriptor(self: *Gpu, tex: TextureHandle, view_desc: TextureViewDesc) u64 {
    return self.backend.textureRwViewDescriptor(tex, view_desc);
}
pub fn samplerDescriptor(self: *Gpu, desc: SamplerDesc) u64 {
    return self.backend.samplerDescriptor(desc);
}
pub fn semaphoreWait(self: *Gpu, sem: Semaphore, value: u64) void {
    self.backend.semaphoreWait(sem.handle, value);
}

pub fn descHeapCreate(self: *Gpu, texture_count: u32, texture_rw_count: u32, sampler_count: u32) !DescriptorHeap {
    const idx = try self.backend.descHeapCreate(texture_count, texture_rw_count, sampler_count);
    return .{ .index = idx };
}
pub fn descHeapDestroy(self: *Gpu, heap: DescriptorHeap) void {
    self.backend.descHeapDestroy(heap.index);
}

pub fn drawTriangles(self: *Gpu, cmd: CommandBuffer, texture: ?TextureHandle, vertices: []const Vertex, indices: []const u32, clip_rect: ?Rect) void {
    if (vertices.len == 0 or indices.len == 0) return;
    const vert_bytes = @sizeOf(Vertex) * vertices.len;
    const idx_bytes = @sizeOf(u32) * indices.len;
    const buf = self.gpuMalloc(@intCast(vert_bytes + idx_bytes), 64, .default) catch return;
    defer self.gpuFree(buf);

    @memcpy(buf.cpu[0..vert_bytes], @as([*]const u8, @ptrCast(vertices.ptr))[0..vert_bytes]);
    @memcpy(buf.cpu[vert_bytes..][0..idx_bytes], @as([*]const u8, @ptrCast(indices.ptr))[0..idx_bytes]);

    const vk_buf: vk.Buffer = @enumFromInt(buf.vk_buffer);
    const vert_off: u64 = 0;
    const idx_off: u64 = vert_bytes;

    const bindings = [_]VertexBinding{.{ .binding = 0, .stride = @sizeOf(Vertex), .input_rate = 0 }};
    const attribs = [_]VertexAttribute{
        .{ .location = 0, .binding = 0, .format = @intFromEnum(vk.Format.r32g32_sfloat), .offset = @offsetOf(Vertex, "position") },
        .{ .location = 1, .binding = 0, .format = @intFromEnum(vk.Format.r32g32_sfloat), .offset = @offsetOf(Vertex, "uv") },
        .{ .location = 2, .binding = 0, .format = @intFromEnum(vk.Format.r8g8b8a8_unorm), .offset = @offsetOf(Vertex, "color") },
    };
    self.backend.cmdSetVertexInput(cmd.handle, &bindings, &attribs);
    self.backend.cmdBindVertexBuffer(cmd.handle, 0, vk_buf, vert_off);
    self.backend.cmdBindIndexBuffer(cmd.handle, vk_buf, idx_off, .u32);
    if (clip_rect) |cr| {
        self.backend.cmdSetScissor(cmd.handle, .{ .x = cr.x, .y = cr.y, .width = cr.w, .height = cr.h });
    }
    if (texture) |tex| {
        _ = tex;
    }
    self.backend.cmdDrawIndexed(cmd.handle, @intCast(indices.len), 1, 0, 0);
}

pub fn generateMipmaps(self: *Gpu, cmd: CommandBuffer, texture: Texture) void {
    var mip: u32 = 1;
    while (mip < texture.mip_count) : (mip += 1) {
        if (mip > 1) {
            self.backend.cmdBarrier(cmd.handle, .{ .transfer = true }, .{ .transfer = true }, .{});
        }
        const src_rect = Texture.BlitRect{ .mip_level = mip - 1 };
        const dst_rect = Texture.BlitRect{ .mip_level = mip };
        self.backend.cmdBlitTexture(cmd.handle, texture.handle, dst_rect, texture.handle, src_rect, .linear);
    }
}

pub fn gpuMalloc(self: *Gpu, size: u64, alignment: u29, mem_type: MemoryType) GpuError!GpuPtr {
    if (self.backend.gpuMalloc(size, alignment, mem_type)) |ptr| return ptr else |_| return GpuError.BackendError;
}
pub fn gpuFree(self: *Gpu, ptr: GpuPtr) void {
    self.backend.gpuFree(ptr);
}
pub fn gpuHostToDevicePointer(self: *Gpu, cpu_ptr: [*]u8) GpuPtr {
    return self.backend.gpuHostToDevicePointer(cpu_ptr);
}

// ── Basic types ──────────────────────────────────────────────

pub const FrameSchedule = struct { next_vblank_us: u32, swapchain_recreated: bool };
pub const FrameResult = struct { gpu_blocked_ns: u64 };
pub const PresentInfo = struct { blit_to_swapchain: bool = true };

test {
    std.testing.refAllDecls(@This());
}
