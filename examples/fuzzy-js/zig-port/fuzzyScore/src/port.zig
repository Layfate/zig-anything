//! Zig port of `fuzzyScore` (src/fuzzy.mjs:7).
//!
//! JavaScript strings are sequences of UTF-16 code units: `length`,
//! `charCodeAt` and indices all count units, so a character outside the
//! Basic Multilingual Plane (an emoji, say) is two units. The recorded cases
//! include such strings, so this port walks UTF-16 units decoded on the fly
//! from the UTF-8 input, reproducing the original's positions and scores
//! exactly without allocating.

const std = @import("std");

fn lower(c: u16) u16 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isBoundary(c: u16) bool {
    return c == ' ' or c == '-' or c == '_' or c == '/' or c == '.';
}

/// Streams the UTF-16 code units of a (valid) UTF-8 string, with an inline
/// fast path for ASCII bytes.
const Units = struct {
    s: []const u8,
    i: usize = 0,
    pending: u16 = 0,

    fn init(s: []const u8) Units {
        return .{ .s = s };
    }

    inline fn next(u: *Units) ?u16 {
        if (u.pending != 0) {
            const low = u.pending;
            u.pending = 0;
            return low;
        }
        if (u.i >= u.s.len) return null;
        const b = u.s[u.i];
        if (b < 0x80) {
            u.i += 1;
            return b;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch unreachable;
        const cp = std.unicode.utf8Decode(u.s[u.i..][0..n]) catch unreachable;
        u.i += n;
        if (cp < 0x10000) return @intCast(cp);
        const v = cp - 0x10000;
        u.pending = @intCast(0xDC00 + (v & 0x3FF));
        return @intCast(0xD800 + (v >> 10));
    }
};

pub fn fuzzyScore(query: []const u8, text: []const u8) f64 {
    if (query.len == 0) return 1;
    // The original's `query.length > text.length` early exit is only a
    // shortcut: the loop below reaches the same answer (0) when the text runs
    // out first. Skipping it avoids two O(n) UTF-16 length scans per call,
    // which JavaScript gets for free.
    var qu: Units = .init(query);
    var tu: Units = .init(text);
    var q: ?u16 = qu.next();
    var qi: usize = 0;
    var score: f64 = 0;
    var streak: f64 = 0;
    var prev: isize = -2;
    var before: ?u16 = null; // text unit at ti - 1
    var ti: isize = 0;
    while (q) |qc| : (ti += 1) {
        const t = tu.next() orelse return 0;
        defer before = t;
        if (lower(t) != lower(qc)) continue;
        var bonus: f64 = 1;
        if (before == null or isBoundary(before.?)) bonus += 2;
        if (prev == ti - 1) {
            streak += 1;
            bonus += streak;
        } else streak = 0;
        if (t == qc) bonus += 0.5;
        score += bonus;
        prev = ti;
        qi += 1;
        q = qu.next();
    }
    const n: f64 = @floatFromInt(qi);
    const best = n * 3.5 + (n * (n - 1)) / 2;
    // Math.round on a non-negative value: nearest integer, halves up.
    return @round((score / best) * 1000) / 1000;
}

test "fuzzyScore" {
    try std.testing.expectEqual(@as(f64, 1), fuzzyScore("", "anything"));
    try std.testing.expectEqual(@as(f64, 0), fuzzyScore("xyz", "abc"));
    try std.testing.expect(fuzzyScore("fb", "foo bar") > fuzzyScore("fb", "afoobar"));
    // "ok" after an emoji: the emoji counts as two units, as in JavaScript.
    try std.testing.expectEqual(@as(f64, 0.375), fuzzyScore("ok", "emoji 🎉 ok"));
}
