//! Platform window handle. Created via PlatformWindow.create().
const std = @import("std");
const PlatformWindow = @This();

pub fn create(title: [:0]const u8, width: u32, height: u32) PlatformWindow { _ = title; _ = width; _ = height; return .{}; }
pub fn destroy(self: *PlatformWindow) void { _ = self; }

test { std.testing.refAllDecls(@This()); }
