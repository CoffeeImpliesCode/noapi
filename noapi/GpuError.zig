//! GPU error set and memory type.
const std = @import("std");

pub const GpuError = error{
    OutOfMemory,
    DeviceLost,
    SurfaceInvalid,
    ShaderCompileFailed,
    InvalidHandle,
    BackendError,
};

pub const MemoryType = enum(u2) { default = 0, gpu = 1, readback = 2 };

test {
    std.testing.refAllDecls(@This());
}
