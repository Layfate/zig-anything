//! A port that crashes on empty input, for crash-detection tests.
const std = @import("std");

pub fn slugify(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    _ = allocator;
    if (text.len == 0) @panic("boom");
    return text;
}
