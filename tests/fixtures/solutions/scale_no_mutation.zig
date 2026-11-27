//! A wrong port of `scaleInPlace`: right return value, but it forgets to
//! change its argument. Only a recording with side effects catches this.
pub fn scaleInPlace(xs: []f64, k: f64) usize {
    _ = k;
    return xs.len;
}
