//! Surface — unified API-level handle for a Vulkan surface + swapchain.
//! Replaces both Gpu.Window and PlatformWindow. Created from a vk.SurfaceKHR
//! obtained from the platform (e.g. SDL3); delegates all per-window work to
//! the VkBackend.

const std = @import("std");
const tracy = @import("tracy");
const Surface = @This();

const Gpu = @import("Gpu.zig").Gpu;
const vk = @import("vk.zig");
const Extent2D = @import("Extent2D.zig");
const TextureHandle = @import("TextureHandle.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const FrameSchedule = @import("Gpu.zig").FrameSchedule;
const FrameResult = @import("Gpu.zig").FrameResult;
const PresentInfo = @import("Gpu.zig").PresentInfo;

gpu: *Gpu,
index: u32,

pub fn init(gpu: *Gpu, vk_surface: vk.SurfaceKHR, extent: Extent2D) !Surface {
    const idx = try gpu.backend.addWindow(vk_surface, extent);
    return .{ .gpu = gpu, .index = idx };
}

pub fn deinit(self: *Surface) void {
    self.gpu.backend.removeWindow(self.index);
}

pub fn beginFrame(self: *Surface) !FrameSchedule {
    const zone = tracy.Zone.begin(.{ .src = @src() }); defer zone.end();
    return self.gpu.backend.beginFrame(self.index);
}

pub fn endFrame(self: *Surface, present: ?PresentInfo) FrameResult {
    const zone = tracy.Zone.begin(.{ .src = @src() }); defer zone.end();
    return self.gpu.backend.endFrame(self.index, present);
}

pub fn currentImage(self: *const Surface) TextureHandle {
    return self.gpu.backend.currentSwapchainImage(self.index);
}

pub fn commandsBegin(self: *Surface) CommandBuffer {
    const zone = tracy.Zone.begin(.{ .src = @src() }); defer zone.end();
    return .{ .gpu = self.gpu, .handle = self.gpu.backend.getCurrentCmdBuf(self.index) };
}

pub fn surfaceSize(self: *const Surface) Extent2D {
    return self.gpu.backend.surfaceSize(self.index);
}

pub fn notifyResize(self: *Surface, extent: Extent2D) void {
    self.gpu.backend.notifyResize(self.index, extent);
}

test {
    std.testing.refAllDecls(@This());
}
