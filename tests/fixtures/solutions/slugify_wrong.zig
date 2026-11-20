//! A deliberately wrong port (keeps upper case) for regression tests.
const std = @import("std");

pub fn slugify(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(allocator, text.len);
    var pending_dash = false;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_dash and out.items.len > 0) out.appendAssumeCapacity('-');
            pending_dash = false;
            out.appendAssumeCapacity(c);
        } else pending_dash = true;
    }
    return out.items;
}
