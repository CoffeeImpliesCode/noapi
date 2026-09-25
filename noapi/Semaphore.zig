// zlint-disable unused-decls -- public API type, re-exported via root.zig
//! Semaphore — timeline or binary semaphore.
const std = @import("std");
const Gpu = @import("Gpu.zig");

gpu: *Gpu,
handle: Gpu.SemaphoreHandle = .null_handle,

test {
    std.testing.refAllDecls(@This());
}
