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

const tracy = @import("tracy");

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
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
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
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.backend.flushPendingFrees();
    self.backend.deinit();
}

pub fn flushPendingFrees(self: *Gpu) void {
    self.backend.flushPendingFrees();
}

pub fn waitIdle(self: *Gpu) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
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
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    _ = name;
    const handle = try self.backend.shaderCreate(spv, @intFromEnum(stage), entry);
    return Shader{ .gpu = self, .handle = handle, .stage = stage };
}

pub fn shaderDestroy(self: *Gpu, shader: Shader) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.backend.shaderDestroy(shader.handle);
}

pub fn semaphoreCreate(self: *Gpu, initial: u64) !Semaphore {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    return Semaphore{ .gpu = self, .handle = try self.backend.semaphoreCreate(initial) };
}
pub fn semaphoreDestroy(self: *Gpu, sem: Semaphore) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.backend.semaphoreDestroy(sem.handle);
}

pub fn bufferCreate(self: *Gpu, desc: BufferDesc) !Buffer {
    const ptr = try self.gpuMalloc(desc.size, 64, .gpu);
    return Buffer{ .gpu = self, .gpu_ptr = ptr };
}
pub fn bufferDestroy(self: *Gpu, buf: Buffer) void {
    self.gpuFree(buf.gpu_ptr);
}

pub fn textureSizeAndAlign(self: *Gpu, desc: TextureDesc) @TypeOf(self.backend.textureSizeAndAlign(desc)) {
    return self.backend.textureSizeAndAlign(desc);
}
pub fn textureCreate(self: *Gpu, desc: TextureDesc) !TextureHandle {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    return self.backend.textureCreate(desc, .{}, 0);
}
pub fn textureDestroy(self: *Gpu, tex: TextureHandle) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.backend.textureDestroy(tex);
}

pub fn textureViewDescriptor(self: *Gpu, tex: TextureHandle, view_desc: TextureViewDesc) u64 {
    return self.backend.textureViewDescriptor(tex, view_desc);
}
pub fn descHeapSetTexturesRw(self: *Gpu, heap: DescriptorHeap, start_idx: u32, descriptors: []const u64) void {
    self.backend.descHeapSetTexturesRw(heap.index, start_idx, descriptors);
}
pub fn descHeapSetTextures(self: *Gpu, heap: DescriptorHeap, start_idx: u32, descriptors: []const u64) void {
    self.backend.descHeapSetTextures(heap.index, start_idx, descriptors);
}
pub fn descHeapSetSamplers(self: *Gpu, heap: DescriptorHeap, start_idx: u32, descriptors: []const u64) void {
    self.backend.descHeapSetSamplers(heap.index, start_idx, descriptors);
}
pub fn textureRwViewDescriptor(self: *Gpu, tex: TextureHandle, view_desc: TextureViewDesc) u64 {
    return self.backend.textureRwViewDescriptor(tex, view_desc);
}
pub fn samplerDescriptor(self: *Gpu, desc: SamplerDesc) u64 {
    return self.backend.samplerDescriptor(desc);
}
pub fn semaphoreWait(self: *Gpu, sem: Semaphore, value: u64) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.backend.semaphoreWait(sem.handle, value);
}

pub fn queueSubmit(self: *Gpu, cmd_bufs: []const CommandBuffer) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    var handles: [64]vk.CommandBuffer = undefined;
    const count = @min(cmd_bufs.len, handles.len);
    for (cmd_bufs[0..count], 0..) |cb, i| handles[i] = cb.handle;
    self.backend.queueSubmit(handles[0..count]);
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
        if (tex.texture.id != 0) {
            const heap = self.descHeapCreate(1, 0, 1) catch return;
            defer self.descHeapDestroy(heap);
            const tex_view = self.textureViewDescriptor(tex, .{ .format = .default });
            const sampler = self.samplerDescriptor(.{ .min_filter = .linear, .mag_filter = .linear, .mip_filter = .linear });
            self.descHeapSetTextures(heap, 0, &.{tex_view});
            self.descHeapSetSamplers(heap, 0, &.{sampler});
            self.backend.cmdBindDescriptorSets(cmd.handle, heap.index);
        }
    }
    self.backend.cmdDrawIndexed(cmd.handle, @intCast(indices.len), 1, 0, 0);
}

pub fn generateMipmaps(self: *Gpu, cmd: CommandBuffer, texture: Texture) void {
    // Ensure any prior writes to the texture are visible to the first blit
    self.backend.cmdBarrier(cmd.handle, .{ .transfer = true }, .{ .transfer = true }, .{});
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
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    if (self.backend.gpuMalloc(size, alignment, mem_type)) |ptr| return ptr else |_| return GpuError.BackendError;
}
pub fn gpuFree(self: *Gpu, ptr: GpuPtr) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    self.backend.gpuFree(ptr);
}
pub fn gpuHostToDevicePointer(self: *Gpu, cpu_ptr: [*]u8) GpuPtr {
    return self.backend.gpuHostToDevicePointer(cpu_ptr);
}

pub fn instanceHandle(self: *const Gpu) vk.Instance {
    return self.backend.instance.handle;
}

// ── Basic types ──────────────────────────────────────────────

pub const FrameSchedule = struct { next_vblank_us: u32, swapchain_recreated: bool };
pub const FrameResult = struct { gpu_blocked_ns: u64 };
pub const PresentInfo = struct { blit_to_swapchain: bool = true };

test {
    std.testing.refAllDecls(@This());
}
