//! Reference port of `scaleInPlace` used by the end-to-end tests.
const std = @import("std");

pub fn scaleInPlace(xs: []f64, k: f64) usize {
    for (xs) |*x| x.* *= k;
    return xs.len;
}

test "scaleInPlace" {
    var xs = [_]f64{ 1, 2 };
    try std.testing.expectEqual(@as(usize, 2), scaleInPlace(&xs, 3));
    try std.testing.expectEqual(@as(f64, 6), xs[1]);
}
