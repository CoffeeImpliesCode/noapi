//! Queue — GPU work submission.
const std = @import("std");
const Gpu = @import("Gpu.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const Semaphore = @import("Semaphore.zig");
const Queue = @This();

gpu: *Gpu,
handle: Gpu.QueueHandle = .null_handle,

pub fn submit(self: *Queue, cmd_bufs: []const CommandBuffer) void {
    if (cmd_bufs.len == 0) return;
    var handles: [64]Gpu.CommandBufferHandle = undefined;
    for (cmd_bufs, 0..) |cb, i| handles[i] = cb.handle;
    self.gpu.backend.queueSubmit(handles[0..cmd_bufs.len]);
}

pub fn submitSignal(self: *Queue, cmd_bufs: []const CommandBuffer, sem: Semaphore, value: u64) void {
    if (cmd_bufs.len == 0) return;
    var handles: [64]Gpu.CommandBufferHandle = undefined;
    for (cmd_bufs, 0..) |cb, i| handles[i] = cb.handle;
    self.gpu.backend.queueSubmitSignal(handles[0..cmd_bufs.len], sem.handle, value);
}

pub fn waitIdle(self: *Queue) void {
    self.gpu.backend.queueWaitIdle();
}

pub fn commandsBegin(self: *Queue, window_index: u32) CommandBuffer {
    return .{ .gpu = self.gpu, .handle = self.gpu.backend.getCurrentCmdBuf(window_index) };
}

test {
    std.testing.refAllDecls(@This());
}
