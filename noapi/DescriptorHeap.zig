//! Descriptor heap — opaque handle to a GPU descriptor set group.
//! Created by Gpu.descHeapCreate, destroyed by Gpu.descHeapDestroy.
const std = @import("std");
const DescriptorHeap = @This();

index: u32 = 0, // index into VkBackend.desc_heaps pool

pub fn deinit(self: *DescriptorHeap) void { self.* = undefined; }
pub fn setTextures(self: *DescriptorHeap, start_idx: u32, descs: []const TextureDescriptor) void { _ = self; _ = start_idx; _ = descs; }
pub fn setTexturesRw(self: *DescriptorHeap, start_idx: u32, descs: []const TextureDescriptor) void { _ = self; _ = start_idx; _ = descs; }
pub fn setSamplers(self: *DescriptorHeap, start_idx: u32, descs: []const SamplerDescriptor) void { _ = self; _ = start_idx; _ = descs; }

pub const TextureDescriptor = u64;
pub const SamplerDescriptor = u64;

test { std.testing.refAllDecls(@This()); }
