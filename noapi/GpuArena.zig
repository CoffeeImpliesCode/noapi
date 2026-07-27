//! GPU memory arena — bump allocator atop a pre-allocated GpuPtr block.
//! Caller owns the allocation and must free it after arena destruction.
const std = @import("std");
const GpuPtr = @import("GpuPtr.zig");
const GpuSlice = @import("GpuPtr.zig").GpuSlice;
const GpuArena = @This();

base: GpuPtr = undefined,
offset: usize = 0,
size: usize = 0,

pub fn create(base: GpuPtr, size: usize) GpuArena {
    return .{ .base = base, .offset = 0, .size = size };
}

pub fn destroy(self: *GpuArena) void {
    self.* = undefined;
}
pub fn alloc(self: *GpuArena, size: usize, alignment: u29) GpuPtr {
    const aligned = std.mem.alignForward(usize, self.offset, alignment);
    const end = aligned + size;
    if (end > self.size) @panic("GpuArena: allocation exceeds arena size");
    self.offset = end;
    return self.base.offset(aligned);
}

pub fn allocT(self: *GpuArena, comptime T: type, count: usize) GpuSlice(T) {
    const byte_size = count * @sizeOf(T);
    const aligned = std.mem.alignForward(usize, self.offset, @alignOf(T));
    const end = aligned + byte_size;
    if (end > self.size) @panic("GpuArena: allocation exceeds arena size");
    self.offset = end;
    const base: [*]T = @ptrCast(@alignCast(self.base.cpu + aligned));
    return .{ .cpu = base[0..count], .gpu = self.base.gpu + @as(u64, @intCast(aligned)) };
}

pub fn reset(self: *GpuArena) void {
    self.offset = 0;
}

test {
    std.testing.refAllDecls(@This());
}
