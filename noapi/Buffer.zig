//! Buffer — GPU buffer resource.
const std = @import("std");
const Gpu = @import("Gpu.zig");
const GpuPtr = @import("GpuPtr.zig");
const Buffer = @This();

gpu: *Gpu,
handle: Gpu.BufferHandle = .null_handle,
gpu_ptr: GpuPtr = .{},  // device address + cpu pointer

pub const BufferDesc = extern struct { size: u64, usage: u32 };

test { std.testing.refAllDecls(@This()); }
