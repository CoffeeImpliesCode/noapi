//! Blend state object.
const std = @import("std");
const BlendState = @This();

pub const BlendOp = enum(u3) { add, subtract, reverse_subtract, min, max };
pub const BlendFactor = enum(u4) { zero, one, src_color, dst_color, src_alpha, dst_alpha, one_minus_src_alpha, one_minus_src_color, one_minus_dst_alpha, one_minus_dst_color };
pub const ColorComponents = packed struct { r: bool = true, g: bool = true, b: bool = true, a: bool = true };

enable: bool = false,
color_op: BlendOp = .add,
src_color_factor: BlendFactor = .one,
dst_color_factor: BlendFactor = .zero,
alpha_op: BlendOp = .add,
src_alpha_factor: BlendFactor = .one,
dst_alpha_factor: BlendFactor = .zero,
color_write_mask: ColorComponents = .{},

test { std.testing.refAllDecls(@This()); }
