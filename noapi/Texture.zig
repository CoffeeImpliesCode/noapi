//! Texture resource + format/type/view/sampler descriptors.
const std = @import("std");
const TextureHandle = @import("TextureHandle.zig");
const GpuPtr = @import("GpuPtr.zig");
const Queue = @import("Queue.zig");
const Semaphore = @import("Semaphore.zig");
const Texture = @This();

pub const TextureFormat = enum(u8) {
    default, r8_unorm, rg8_unorm, rgba8_unorm, abgr8_unorm, bgra8_unorm,
    r8_srgb, rg8_srgb, rgba8_srgb, abgr8_srgb, bgra8_srgb,
    r16_unorm, rg16_unorm, rgba16_unorm,
    d16_unorm, d32_float,
    r16_float, rg16_float, rgba16_float, r32_float, rg32_float, rgba32_float,
    bc1_rgba_unorm, bc3_rgba_unorm, bc7_rgba_unorm,
};

pub const TextureType = enum(u3) { @"2d", @"3d", @"1d", cube, @"2d_array", @"1d_array", cube_array };

pub const TextureUsage = packed struct {
    sampled: bool = true, storage: bool = false, transfer_src: bool = false,
    color_attachment: bool = false, depth_stencil_attachment: bool = false,
};

pub const TextureDesc = struct {
    type: TextureType = .@"2d", dimensions: [3]u32 = .{ 1, 1, 1 },
    mip_count: u32 = 1, layer_count: u32 = 1, sample_count: u32 = 1,
    format: TextureFormat = .rgba8_unorm, usage: TextureUsage = .{},
};

pub const TextureViewDesc = struct {
    type: TextureType = .@"2d", format: TextureFormat = .default,
    base_mip: u32 = 0, mip_count: u8 = 0, base_layer: u16 = 0, layer_count: u16 = 0,
};

pub const SamplerDesc = struct {
    min_filter: Filter = .linear, mag_filter: Filter = .linear, mip_filter: Filter = .linear,
    address_mode_u: AddressMode = .repeat, address_mode_v: AddressMode = .repeat, address_mode_w: AddressMode = .repeat,
    mip_lod_bias: f32 = 0, min_lod: f32 = 0, max_lod: f32 = 32, max_anisotropy: f32 = 1,
};

pub const Filter = enum(u1) { linear, nearest };
pub const AddressMode = enum(u3) { repeat, mirrored_repeat, clamp_to_edge };

pub const TextureRegion = struct {
    rect: [3]i32 = .{ 0, 0, 0 }, size: [3]u32 = .{ 0, 0, 0 },
    mip_level: u32 = 0, base_layer: u32 = 0, layer_count: u32 = 1,
};

pub const BlitRect = struct {
    offset_a: [3]i32 = .{ 0, 0, 0 }, offset_b: [3]i32 = .{ 0, 0, 0 },
    mip_level: u32 = 0, base_layer: u32 = 0, layer_count: u32 = 1,
};

handle: TextureHandle = .{},
type: TextureType = .@"2d",
dimensions: [3]u32 = .{ 0, 0, 0 },
format: TextureFormat = .rgba8_unorm,
mip_count: u32 = 1,
layer_count: u32 = 1,
sample_count: u32 = 1,

pub fn create(desc: TextureDesc, storage: GpuPtr, queue: Queue, signal_sem: Semaphore, signal_value: u64, name: []const u8) Texture {
    _ = desc; _ = storage; _ = queue; _ = signal_sem; _ = signal_value; _ = name;
    return .{};
}

pub fn destroy(self: *Texture) void { _ = self; }

test { std.testing.refAllDecls(@This()); }
