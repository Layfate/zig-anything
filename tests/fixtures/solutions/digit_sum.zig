//! Reference port of `digit_sum` used by the end-to-end tests.
const std = @import("std");

pub fn digit_sum(n: i64) !i64 {
    if (n < 0) return error.ValueError;
    var rest: u64 = @intCast(n);
    var total: i64 = 0;
    while (true) {
        total += @intCast(rest % 10);
        rest /= 10;
        if (rest == 0) return total;
    }
}

test "digit_sum" {
    try std.testing.expectEqual(@as(i64, 6), try digit_sum(123));
    try std.testing.expectEqual(@as(i64, 0), try digit_sum(0));
    try std.testing.expectError(error.ValueError, digit_sum(-5));
}
