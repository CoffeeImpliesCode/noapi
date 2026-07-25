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
const GpuArena = @import("GpuArena.zig");

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
};

pub fn init(options: Options) !Gpu {
    return .{
        .backend = try VkBackend.init(.{
            .app_name = options.app_name,
            .validation = options.validation,
            .frames_in_flight = options.frames_in_flight,
            .loader = options.loader,
            .io = options.io,
        }),
        .frames_in_flight = options.frames_in_flight,
    };
}

pub fn deinit(self: *Gpu) void {
    self.backend.deinit();
}

pub fn beginFrame(self: *Gpu, window_index: u32) !FrameSchedule {
    return self.backend.beginFrame(window_index);
}
pub fn endFrame(self: *Gpu, window_index: u32, present: ?PresentInfo) FrameResult {
    return self.backend.endFrame(window_index, present);
}
pub fn waitIdle(self: *Gpu) void {
    self.backend.waitIdle();
}

pub fn addWindow(self: *Gpu, surface: vk.SurfaceKHR, initial_extent: Extent2D) !u32 {
    return self.backend.addWindow(surface, initial_extent);
}
pub fn removeWindow(self: *Gpu, index: u32) void {
    self.backend.removeWindow(index);
}
pub fn numWindows(self: *const Gpu) u32 {
    return self.backend.numWindows();
}
pub fn surfaceSize(self: *const Gpu, window_index: u32) Extent2D {
    return self.backend.surfaceSize(window_index);
}
pub fn notifyResize(self: *Gpu, window_index: u32, size: Extent2D) void {
    self.backend.notifyResize(window_index, size);
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
    return Buffer{ .gpu = self, .handle = .null_handle, .gpu_ptr = ptr };
}
pub fn bufferDestroy(self: *Gpu, buf: Buffer) void {
    _ = self;
    _ = buf;
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

pub fn commandsBegin(self: *Gpu) CommandBuffer {
    return .{ .gpu = self, .handle = .null_handle };
}

pub fn drawTriangles(self: *Gpu, cmd: CommandBuffer, texture: ?TextureHandle, vertices: []const Vertex, indices: []const u32, clip_rect: ?Rect) void {
    _ = self;
    _ = cmd;
    _ = texture;
    _ = vertices;
    _ = indices;
    _ = clip_rect;
}

pub fn gpuMalloc(self: *Gpu, size: u64, alignment: u29, mem_type: MemoryType) GpuError!GpuPtr {
    if (self.backend.gpuMalloc(size, alignment, mem_type)) |ptr| return ptr else |_| return GpuError.BackendError;
}
pub fn gpuFree(self: *Gpu, idx: u32) void {
    self.backend.gpuFree(idx);
}
pub fn gpuHostToDevicePointer(self: *Gpu, cpu_ptr: [*]u8) GpuPtr {
    _ = self;
    _ = cpu_ptr;
    return .{};
}

// ── Basic types ──────────────────────────────────────────────

pub const FrameSchedule = struct { next_vblank_us: u32, swapchain_recreated: bool };
pub const FrameResult = struct { gpu_blocked_ns: u64 };
pub const PresentInfo = struct { blit_to_swapchain: bool = true };

/// Window wraps a Gpu + window index for ergonomic multi-window rendering.
pub const Window = struct {
    gpu: *Gpu,
    index: u32,

    pub fn beginFrame(self: *Window) !FrameSchedule {
        return self.gpu.backend.beginFrame(self.index);
    }
    pub fn endFrame(self: *Window, present: ?PresentInfo) FrameResult {
        return self.gpu.backend.endFrame(self.index, present);
    }
    pub fn currentSwapchainImage(self: *const Window) TextureHandle {
        return self.gpu.backend.currentSwapchainImage(self.index);
    }
    pub fn commandsBegin(self: *Window) CommandBuffer {
        return .{ .gpu = self.gpu, .handle = self.gpu.backend.getCurrentCmdBuf(self.index) };
    }
    pub fn surfaceSize(self: *const Window) Extent2D {
        return self.gpu.backend.surfaceSize(self.index);
    }
    pub fn notifyResize(self: *Window, size: Extent2D) void {
        self.gpu.backend.notifyResize(self.index, size);
    }
};

pub const TextureHandle = @import("TextureHandle.zig");
pub const Vertex = @import("Vertex.zig");
pub const Rect = @import("Rect.zig");
pub const Extent2D = @import("Extent2D.zig");
pub const DeviceLimits = @import("DeviceLimits.zig");
pub const GpuPtr = @import("GpuPtr.zig");
pub const GpuSlice = @import("GpuPtr.zig").GpuSlice;
pub const memAlloc = @import("GpuPtr.zig").memAlloc;
pub const memSuballoc = @import("GpuPtr.zig").memSuballoc;
pub const GpuError = @import("GpuError.zig").GpuError;
pub const MemoryType = @import("GpuError.zig").MemoryType;
pub const ShaderStage = @import("Shader.zig").ShaderStage;
pub const PushData = @import("CommandBuffer.zig").PushData;
pub const IndexFormat = @import("CommandBuffer.zig").IndexFormat;
pub const DrawIndexedIndirectCommand = @import("CommandBuffer.zig").DrawIndexedIndirectCommand;
pub const DispatchIndirectCommand = @import("CommandBuffer.zig").DispatchIndirectCommand;
pub const Stage = @import("Barrier.zig").Stage;
pub const Hazard = @import("Barrier.zig").Hazard;
pub const BufferDesc = @import("Buffer.zig").BufferDesc;
pub const TextureDesc = @import("Texture.zig").TextureDesc;
pub const TextureType = @import("Texture.zig").TextureType;
pub const TextureFormat = @import("Texture.zig").TextureFormat;
pub const TextureUsage = @import("Texture.zig").TextureUsage;
pub const TextureViewDesc = @import("Texture.zig").TextureViewDesc;
pub const TextureRegion = @import("Texture.zig").TextureRegion;
pub const BlitRect = @import("Texture.zig").BlitRect;
pub const SamplerDesc = @import("Texture.zig").SamplerDesc;
pub const Filter = @import("Texture.zig").Filter;
pub const AddressMode = @import("Texture.zig").AddressMode;
pub const DepthState = @import("DepthState.zig");
pub const CompareOp = @import("DepthState.zig").CompareOp;
pub const RasterState = @import("RasterState.zig");
pub const Topology = @import("RasterState.zig").Topology;
pub const CullMode = @import("RasterState.zig").CullMode;
pub const BlendState = @import("BlendState.zig");
pub const BlendOp = @import("BlendState.zig").BlendOp;
pub const BlendFactor = @import("BlendState.zig").BlendFactor;
pub const Viewport = @import("Viewport.zig");
pub const Scissor = @import("Viewport.zig").Scissor;
pub const LoadOp = @import("Rendering.zig").LoadOp;
pub const StoreOp = @import("Rendering.zig").StoreOp;
pub const RenderingAttachment = @import("Rendering.zig").RenderingAttachment;
pub const RenderingDesc = @import("Rendering.zig");
pub const PlatformWindow = @import("PlatformWindow.zig");

test {
    std.testing.refAllDecls(@This());
}
