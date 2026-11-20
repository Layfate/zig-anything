//! Reference port of `mean` used by the end-to-end tests.
const std = @import("std");

pub fn mean(xs: []const f64) !f64 {
    if (xs.len == 0) return error.RangeError;
    var total: f64 = 0;
    for (xs) |x| total += x; // same summation order as the original
    return total / @as(f64, @floatFromInt(xs.len));
}

test "mean" {
    try std.testing.expectEqual(@as(f64, 2), try mean(&.{ 1, 2, 3 }));
    try std.testing.expectError(error.RangeError, mean(&.{}));
}
