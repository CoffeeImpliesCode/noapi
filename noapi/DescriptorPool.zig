//! Descriptor pool — freelist allocator for descriptor heap slots.
const std = @import("std");
const DescriptorHeap = @import("DescriptorHeap.zig");
const TextureDescriptor = @import("DescriptorHeap.zig").TextureDescriptor;
const SamplerDescriptor = @import("DescriptorHeap.zig").SamplerDescriptor;
const DescriptorPool = @This();

heap: DescriptorHeap = undefined,
next_texture: u32 = 0,
next_texture_rw: u32 = 0,
next_sampler: u32 = 0,

pub fn create(heap: DescriptorHeap, texture_count: u32, sampler_count: u32) DescriptorPool {
    _ = texture_count; _ = sampler_count;
    return .{ .heap = heap };
}

pub fn destroy(self: *DescriptorPool) void { self.heap.deinit(); }

pub fn allocTexture(self: *DescriptorPool) TextureDescriptor { _ = self; return 0; }
pub fn allocTextureRw(self: *DescriptorPool) TextureDescriptor { _ = self; return 0; }
pub fn allocSampler(self: *DescriptorPool) SamplerDescriptor { _ = self; return 0; }
pub fn freeAll(self: *DescriptorPool) void { self.next_texture = 0; self.next_texture_rw = 0; self.next_sampler = 0; }

test { std.testing.refAllDecls(@This()); }
