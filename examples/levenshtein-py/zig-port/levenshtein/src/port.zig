//! Zig port of `levenshtein` (src/textdist.py:4).
//!
//! Python strings are sequences of code points, so the input is decoded from
//! UTF-8 first; comparing bytes would count "é" as two edits.

const std = @import("std");

fn codepoints(allocator: std.mem.Allocator, s: []const u8) ![]const u21 {
    const view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    var out: std.ArrayList(u21) = try .initCapacity(allocator, s.len);
    while (it.nextCodepoint()) |cp| out.appendAssumeCapacity(cp);
    return out.items;
}

pub fn levenshtein(allocator: std.mem.Allocator, a_utf8: []const u8, b_utf8: []const u8) !i64 {
    var a = try codepoints(allocator, a_utf8);
    var b = try codepoints(allocator, b_utf8);
    if (a.len < b.len) std.mem.swap([]const u21, &a, &b);

    // Two rolling rows, allocated once per call.
    var previous = try allocator.alloc(usize, b.len + 1);
    var current = try allocator.alloc(usize, b.len + 1);
    for (previous, 0..) |*p, j| p.* = j;
    for (a, 1..) |ca, i| {
        current[0] = i;
        for (b, 1..) |cb, j| {
            const cost: usize = @intFromBool(ca != cb);
            current[j] = @min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost);
        }
        std.mem.swap([]usize, &previous, &current);
    }
    return @intCast(previous[b.len]);
}

test "levenshtein" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(i64, 3), try levenshtein(a, "kitten", "sitting"));
    try std.testing.expectEqual(@as(i64, 1), try levenshtein(a, "café", "cafe"));
    try std.testing.expectEqual(@as(i64, 0), try levenshtein(a, "", ""));
}
