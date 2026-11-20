//! Reference port of `slugify` used by the end-to-end tests.
const std = @import("std");

pub fn slugify(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(allocator, text.len);
    var pending_dash = false;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_dash and out.items.len > 0) out.appendAssumeCapacity('-');
            pending_dash = false;
            out.appendAssumeCapacity(std.ascii.toLower(c));
        } else pending_dash = true;
    }
    return out.items;
}

test "slugify" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("hello-world", try slugify(arena.allocator(), "  Hello, World! "));
}
