//! Shader — GPU shader object.
const std = @import("std");
const Gpu = @import("Gpu.zig");
const Shader = @This();

gpu: *Gpu,
handle: Gpu.ShaderHandle = .null_handle,
stage: ShaderStage = .vertex,

pub const ShaderStage = enum(u2) { vertex, fragment, compute };

test { std.testing.refAllDecls(@This()); }
