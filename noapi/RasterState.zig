//! Rasterization state object.
const std = @import("std");
const RasterState = @This();

pub const Topology = enum(u3) { triangle_list, triangle_strip, triangle_fan };
pub const CullMode = enum(u2) { none, front, back, all };

topology: Topology = .triangle_list,
cull_mode: CullMode = .back,
alpha_to_coverage: bool = false,

test { std.testing.refAllDecls(@This()); }
