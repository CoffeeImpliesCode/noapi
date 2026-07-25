//! GPU memory arena — bump allocator atop a gpuMalloc block.
const std = @import("std");
const GpuPtr = @import("GpuPtr.zig");
const GpuSlice = @import("GpuPtr.zig").GpuSlice;
const GpuError = @import("GpuError.zig").GpuError;
const MemoryType = @import("GpuError.zig").MemoryType;
const GpuArena = @This();

base: GpuPtr = undefined,
offset: usize = 0,
size: usize = 0,

pub fn create(size: usize) GpuError!GpuArena {
    const ptr = try gpuMalloc(size, @alignOf(u64), .default);
    return .{ .base = ptr, .offset = 0, .size = size };
}

pub fn destroy(self: *GpuArena) void { gpuFree(self.base); self.* = undefined; }
pub fn alloc(self: *GpuArena, size: usize, alignment: u29) GpuPtr {
    const aligned = std.mem.alignForward(usize, self.offset, alignment);
    self.offset = aligned + size;
    return self.base.offset(aligned);
}

pub fn allocT(self: *GpuArena, comptime T: type, count: usize) GpuSlice(T) {
    const byte_size = count * @sizeOf(T);
    const aligned = std.mem.alignForward(usize, self.offset, @alignOf(T));
    self.offset = aligned + byte_size;
    const base: [*]T = @ptrCast(@alignCast(self.base.cpu + aligned));
    return .{ .cpu = base[0..count], .gpu = self.base.gpu + @as(u64, @intCast(aligned)) };
}

pub fn reset(self: *GpuArena) void { self.offset = 0; }

pub fn gpuMalloc(size: usize, alignment: u29, mem_type: MemoryType) GpuError!GpuPtr {
    _ = size; _ = alignment; _ = mem_type; return GpuError.BackendError;
}

pub fn gpuFree(ptr: GpuPtr) void { _ = ptr; }

pub fn gpuHostToDevicePointer(cpu: [*]u8) u64 { return @intFromPtr(cpu); }

test { std.testing.refAllDecls(@This()); }
