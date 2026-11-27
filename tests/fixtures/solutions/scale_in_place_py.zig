//! Reference port of `scale_in_place` (Python) used by the end-to-end tests.
const std = @import("std");

pub fn scale_in_place(xs: []f64, k: f64) usize {
    for (xs) |*x| x.* *= k;
    return xs.len;
}

test "scale_in_place" {
    var xs = [_]f64{ 1, 2 };
    try std.testing.expectEqual(@as(usize, 2), scale_in_place(&xs, 3));
    try std.testing.expectEqual(@as(f64, 6), xs[1]);
}
