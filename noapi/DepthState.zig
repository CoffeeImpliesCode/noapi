//! Depth-stencil state object.
const std = @import("std");
const DepthState = @This();

pub const CompareOp = enum(u3) { never, less, equal, less_equal, greater, not_equal, greater_equal, always };
pub const DepthMode = packed struct { read: bool = false, write: bool = false };

mode: DepthMode = .{},
compare: CompareOp = .less_equal,

test { std.testing.refAllDecls(@This()); }
