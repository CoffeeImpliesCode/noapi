//! Command buffer — GPU command recording.
const std = @import("std");
const Gpu = @import("Gpu.zig");
const CommandBuffer = @This();

gpu: *Gpu,
handle: Gpu.CommandBufferHandle = .null_handle,

pub const PushData = extern struct {
    vert_data: u64 = 0,
    frag_data: u64 = 0,
    indirect: u64 = 0,
};

pub const IndexFormat = enum(u32) { u16 = 0, u32 };

pub const DrawIndexedIndirectCommand = extern struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
};

pub const DispatchIndirectCommand = extern struct {
    num_groups_x: u32,
    num_groups_y: u32,
    num_groups_z: u32,
};

pub fn barrier(self: *CommandBuffer, before: Stage, after: Stage, hazards: Hazard) void {
    self.gpu.backend.cmdBarrier(self.handle, before, after, hazards);
}
pub fn draw(self: *CommandBuffer, data: PushData, vertex_count: u32, instance_count: u32) void {
    self.gpu.backend.cmdPushConstantsGraphics(self.handle, data);
    self.gpu.backend.cmdDraw(self.handle, vertex_count, instance_count);
}
pub fn drawIndexed(self: *CommandBuffer, data: PushData, indices: GpuPtr, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32) void {
    self.gpu.backend.cmdPushConstantsGraphics(self.handle, data);
    self.gpu.backend.cmdBindIndexBuffer(self.handle, @enumFromInt(indices.vk_buffer), 0, .u32);
    self.gpu.backend.cmdDrawIndexed(self.handle, index_count, instance_count, first_index, vertex_offset);
}
pub fn drawIndexedIndirect(self: *CommandBuffer, data: PushData, indices: GpuPtr, arguments: GpuPtr, max_draws: u32) void {
    self.gpu.backend.cmdPushConstantsGraphics(self.handle, data);
    self.gpu.backend.cmdBindIndexBuffer(self.handle, @enumFromInt(indices.vk_buffer), 0, .u32);
    self.gpu.backend.cmdDrawIndexedIndirect(self.handle, @enumFromInt(arguments.vk_buffer), 0, max_draws, @sizeOf(DrawIndexedIndirectCommand));
}
pub fn drawIndexedIndirectMulti(self: *CommandBuffer, data: PushData, indices: GpuPtr, arguments: GpuPtr, stride: u32, draw_count: u32) void {
    self.gpu.backend.cmdPushConstantsGraphics(self.handle, data);
    self.gpu.backend.cmdBindIndexBuffer(self.handle, @enumFromInt(indices.vk_buffer), 0, .u32);
    self.gpu.backend.cmdDrawIndexedIndirectMulti(self.handle, @enumFromInt(arguments.vk_buffer), 0, draw_count, stride);
}
pub fn dispatch(self: *CommandBuffer, data: u64, group_x: u32, group_y: u32, group_z: u32) void {
    self.gpu.backend.cmdPushConstantsCompute(self.handle, data);
    self.gpu.backend.cmdDispatch(self.handle, group_x, group_y, group_z);
}
pub fn dispatchIndirect(self: *CommandBuffer, data: u64, arguments: GpuPtr) void {
    self.gpu.backend.cmdPushConstantsCompute(self.handle, data);
    self.gpu.backend.cmdDispatchIndirect(self.handle, @enumFromInt(arguments.vk_buffer), 0);
}
pub fn bindIndexBuffer(self: *CommandBuffer, indices: GpuPtr, format: IndexFormat) void {
    self.gpu.backend.cmdBindIndexBuffer(self.handle, @enumFromInt(indices.vk_buffer), 0, format);
}
pub fn bindVertexBuffer(self: *CommandBuffer, binding: u32, buf: GpuPtr, offset: u64) void {
    self.gpu.backend.cmdBindVertexBuffer(self.handle, binding, @enumFromInt(buf.vk_buffer), offset);
}
pub fn setShaders(self: *CommandBuffer, vert: Shader, frag: Shader) void {
    self.gpu.backend.cmdSetShaders(self.handle, vert.handle, frag.handle);
}
pub fn setComputeShader(self: *CommandBuffer, shader: Shader) void {
    self.gpu.backend.cmdSetComputeShader(self.handle, shader.handle);
}
pub fn setDepthState(self: *CommandBuffer, state: DepthState) void {
    self.gpu.backend.cmdSetDepthState(self.handle, state);
}
pub fn setRasterState(self: *CommandBuffer, state: RasterState) void {
    self.gpu.backend.cmdSetRasterState(self.handle, state);
}
pub fn setBlendState(self: *CommandBuffer, state: BlendState) void {
    self.gpu.backend.cmdSetBlendState(self.handle, state);
}
pub fn setViewport(self: *CommandBuffer, vp: Viewport) void {
    self.gpu.backend.cmdSetViewport(self.handle, vp);
}
pub fn setScissor(self: *CommandBuffer, sc: Scissor) void {
    self.gpu.backend.cmdSetScissor(self.handle, sc);
}
pub fn bindDescriptorSets(self: *CommandBuffer, heap: DescriptorHeap) void {
    self.gpu.backend.cmdBindDescriptorSets(self.handle, heap.index);
}
pub fn beginRendering(self: *CommandBuffer, desc: RenderingDesc) void {
    self.gpu.backend.cmdBeginRendering(self.handle, desc);
}
pub fn endRendering(self: *CommandBuffer) void {
    self.gpu.backend.cmdEndRendering(self.handle);
}
pub fn memCopy(self: *CommandBuffer, dst: GpuPtr, src: GpuPtr, bytes: u64) void {
    self.gpu.backend.cmdMemCopy(self.handle, @enumFromInt(src.vk_buffer), @enumFromInt(dst.vk_buffer), bytes);
}
pub fn setVertexInput(self: *CommandBuffer, bindings: []const VertexBinding, attributes: []const VertexAttribute) void {
    self.gpu.backend.cmdSetVertexInput(self.handle, bindings, attributes);
}
pub fn copyToTexture(self: *CommandBuffer, tex: Texture, src: GpuPtr, region: TextureRegion) void {
    self.gpu.backend.cmdCopyToTexture(self.handle, tex.handle, @enumFromInt(src.vk_buffer), region);
}
pub fn copyFromTexture(self: *CommandBuffer, tex: Texture, dst: GpuPtr, region: TextureRegion) void {
    self.gpu.backend.cmdCopyFromTexture(self.handle, tex.handle, @enumFromInt(dst.vk_buffer), region);
}
pub fn blitTextureHandle(self: *CommandBuffer, dst: TextureHandle, dst_rect: BlitRect, src: TextureHandle, src_rect: BlitRect, filter: Filter) void {
    self.gpu.backend.cmdBlitTexture(self.handle, dst, dst_rect, src, src_rect, filter);
}
pub fn addWaitSemaphore(self: *CommandBuffer, window_index: u32, sem: Semaphore, value: u64) void {
    self.gpu.backend.cmdAddWaitSemaphore(window_index, sem.handle, value);
}
pub fn addSignalSemaphore(self: *CommandBuffer, window_index: u32, sem: Semaphore, value: u64) void {
    self.gpu.backend.cmdAddSignalSemaphore(window_index, sem.handle, value);
}
pub fn beginDebugLabel(self: *CommandBuffer, name: [:0]const u8, color: [4]f32) void {
    self.gpu.backend.cmdBeginDebugLabel(self.handle, name, color);
}
pub fn endDebugLabel(self: *CommandBuffer) void {
    self.gpu.backend.cmdEndDebugLabel(self.handle);
}
pub fn insertDebugLabel(self: *CommandBuffer, name: [:0]const u8, color: [4]f32) void {
    self.gpu.backend.cmdBeginDebugLabel(self.handle, name, color);
    self.gpu.backend.cmdEndDebugLabel(self.handle);
}

const Stage = @import("Barrier.zig").Stage;
const Hazard = @import("Barrier.zig").Hazard;
const Shader = @import("Shader.zig");
const Semaphore = @import("Semaphore.zig");
const DepthState = @import("DepthState.zig");
const RasterState = @import("RasterState.zig");
const BlendState = @import("BlendState.zig");
const Viewport = @import("Viewport.zig");
const Scissor = @import("Viewport.zig").Scissor;
const DescriptorHeap = @import("DescriptorHeap.zig");
const RenderingDesc = @import("Rendering.zig");
const Texture = @import("Texture.zig");
const TextureRegion = @import("Texture.zig").TextureRegion;
const BlitRect = @import("Texture.zig").BlitRect;
const Filter = @import("Texture.zig").Filter;
const GpuPtr = @import("GpuPtr.zig");
const TextureHandle = @import("TextureHandle.zig");
const VertexBinding = @import("VertexInput.zig").VertexBinding;
const VertexAttribute = @import("VertexInput.zig").VertexAttribute;

test {
    std.testing.refAllDecls(@This());
}
