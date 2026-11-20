//! Input generation for recording: hand-picked edge cases and semantic traps
//! per parameter type, plus seeded random samples. Output is a list of JSON
//! argument arrays (as text), deduplicated, in a stable order.

const std = @import("std");
const lang = @import("lang.zig");
const jsonx = @import("jsonx.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ParamType = lang.ParamType;
const Param = lang.Param;

pub const Options = struct {
    /// Number of random cases on top of the edge cases.
    samples: u32 = 64,
    seed: u64 = 1,
    /// Hard cap on the number of generated cases.
    max_cases: u32 = 2000,
};

const long_string: []const u8 = blk: {
    var buf: [300]u8 = undefined;
    for (&buf, 0..) |*c, i| c.* = "abcdefghij"[i % 10];
    const final = buf;
    break :blk &final;
};

/// Edge values per type, as JSON text. Index 0 is the "typical" value used
/// for the other parameters when one parameter varies.
fn edges(t: ParamType) []const []const u8 {
    return switch (t) {
        .number => &.{
            "3",                  "0",                       "1",                        "-1",      "0.5",  "-0.5",       "2",                "10",
            "100",                "123.456",                 "1e-9",                     "1000000", "-1e6", "2147483647", "9007199254740992", "0.1",
            "{\"$num\":\"NaN\"}", "{\"$num\":\"Infinity\"}", "{\"$num\":\"-Infinity\"}",
        },
        .int => &.{ "3", "0", "1", "-1", "2", "7", "10", "255", "256", "1000", "-1000", "2147483647", "-2147483648", "9007199254740991" },
        .string => &.{
            "\"hello world\"",           "\"\"",                "\"a\"",                 "\" \"",
            "\"  padded  \"",            "\"Hello, World!\"",   "\"UPPER lower\"",       "\"line1\\nline2\"",
            "\"tab\\tsep\"",
            "\"ünïcödé\"",
            "\"日本語テキスト\"",
            "\"emoji 🎉 ok\"",
            "\"a,b,c\"",                 "\"0\"",               "\"-1\"",                "\"3.14\"",
            "\"null\"",                  "\"racecar\"",         "\"aaaa\"",              "\"The quick brown fox jumps over the lazy dog\"",
            "\"" ++ long_string ++ "\"", "\"camelCaseString\"", "\"snake_case_string\"", "\"--dash--\"",
            "\"<b>&amp;</b>\"",          "\"back\\\\slash\"",   "\"quote\\\"d\"",
        },
        .bool => &.{ "true", "false" },
        .number_array => &.{ "[1,2,3]", "[]", "[0]", "[-1,0,1]", "[3,1,2]", "[5,5,5]", "[1.5,2.5,-0.25]", "[1e9,-1e9]", "[0.1,0.2,0.3]", "[42]" },
        .int_array => &.{ "[1,2,3]", "[]", "[0]", "[-1,0,1]", "[3,1,2]", "[5,5,5]", "[100,-100]", "[2147483647]", "[42]" },
        .string_array => &.{ "[\"a\",\"b\",\"c\"]", "[]", "[\"\"]", "[\"a\"]", "[\"b\",\"a\",\"c\"]", "[\"hello\",\"world\"]", "[\"dup\",\"dup\"]", "[\"ünï\",\"日本\"]", "[\"with space\",\"x\"]" },
        .any => &.{ "\"text\"", "null", "0", "1", "-1", "\"\"", "true", "false", "[]", "{}", "[1,2,3]", "{\"a\":1}", "\"a\"", "2.5" },
    };
}

const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789     -_.,!?";
const unicode_bits = [_][]const u8{ "é", "ß", "ж", "中", "🎉", "ñ", "Ω" };

fn randomString(w: *Io.Writer, r: std.Random) !void {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    const len = r.uintAtMost(usize, 24);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (r.uintLessThan(u8, 12) == 0) {
            const u = unicode_bits[r.uintLessThan(usize, unicode_bits.len)];
            @memcpy(buf[n .. n + u.len], u);
            n += u.len;
        } else {
            buf[n] = alphabet[r.uintLessThan(usize, alphabet.len)];
            n += 1;
        }
    }
    try jsonx.writeString(w, buf[0..n]);
}

fn randomNumber(w: *Io.Writer, r: std.Random) !void {
    switch (r.uintLessThan(u8, 4)) {
        0 => try w.print("{d}", .{r.intRangeAtMost(i64, -10, 10)}),
        1 => try w.print("{d}", .{r.intRangeAtMost(i64, -100000, 100000)}),
        2 => {
            // Two decimals keeps values readable in reports.
            const v: f64 = @as(f64, @floatFromInt(r.intRangeAtMost(i64, -100000, 100000))) / 100.0;
            try w.print("{d}", .{v});
        },
        else => try w.print("{d}", .{(r.float(f64) - 0.5) * 2000.0}),
    }
}

fn randomValue(w: *Io.Writer, r: std.Random, t: ParamType) Io.Writer.Error!void {
    switch (t) {
        .number => try randomNumber(w, r),
        .int => try w.print("{d}", .{if (r.boolean()) r.intRangeAtMost(i64, -20, 20) else r.intRangeAtMost(i64, -1000000, 1000000)}),
        .string => try randomString(w, r),
        .bool => try w.writeAll(if (r.boolean()) "true" else "false"),
        .number_array, .int_array, .string_array => {
            const elem: ParamType = switch (t) {
                .number_array => .number,
                .int_array => .int,
                else => .string,
            };
            const len = r.uintAtMost(usize, 8);
            try w.writeByte('[');
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (i != 0) try w.writeByte(',');
                try randomValue(w, r, elem);
            }
            try w.writeByte(']');
        },
        .any => {
            const choices = [_]ParamType{ .number, .int, .string, .bool, .number_array, .string_array };
            try randomValue(w, r, choices[r.uintLessThan(usize, choices.len)]);
        },
    }
}

fn pool(p: Param) []const []const u8 {
    return edges(p.type);
}

const Builder = struct {
    a: Allocator,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    out: std.ArrayList([]const u8) = .empty,
    max: u32,

    fn add(b: *Builder, case: []const u8) !void {
        if (b.out.items.len >= b.max) return;
        const gop = try b.seen.getOrPut(b.a, case);
        if (gop.found_existing) {
            b.a.free(case);
            return;
        }
        try b.out.append(b.a, case);
    }
};

fn writeCase(a: Allocator, params: []const Param, values: []const []const u8) ![]const u8 {
    _ = params;
    var aw: Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    try aw.writer.writeByte('[');
    for (values, 0..) |v, i| {
        if (i != 0) try aw.writer.writeByte(',');
        try aw.writer.writeAll(v);
    }
    try aw.writer.writeByte(']');
    return aw.toOwnedSlice();
}

/// Generates argument arrays for a function with `params`. All memory comes
/// from `a`; use an arena.
pub fn generate(a: Allocator, params: []const Param, opts: Options) ![]const []const u8 {
    var b: Builder = .{ .a = a, .max = opts.max_cases };
    if (params.len == 0) {
        try b.add(try a.dupe(u8, "[]"));
        return b.out.toOwnedSlice(a);
    }
    const values = try a.alloc([]const u8, params.len);

    // 1. All typical values.
    for (params, values) |p, *v| v.* = pool(p)[0];
    try b.add(try writeCase(a, params, values));

    // 2. One parameter at a time through its edge pool (plus null when optional).
    for (params, 0..) |p, i| {
        for (pool(p)) |edge| {
            for (params, values) |q, *v| v.* = pool(q)[0];
            values[i] = edge;
            try b.add(try writeCase(a, params, values));
        }
        if (p.optional) {
            for (params, values) |q, *v| v.* = pool(q)[0];
            values[i] = "null";
            try b.add(try writeCase(a, params, values));
        }
    }

    // 3. Seeded random combinations: each parameter draws either an edge
    //    value or a fresh random value.
    var prng: std.Random.DefaultPrng = .init(opts.seed);
    const r = prng.random();
    var produced: u32 = 0;
    var attempts: u32 = 0;
    while (produced < opts.samples and attempts < opts.samples * 4) : (attempts += 1) {
        var aw: Io.Writer.Allocating = .init(a);
        try aw.writer.writeByte('[');
        for (params, 0..) |p, i| {
            if (i != 0) try aw.writer.writeByte(',');
            const pl = pool(p);
            if (r.boolean()) {
                try aw.writer.writeAll(pl[r.uintLessThan(usize, pl.len)]);
            } else {
                try randomValue(&aw.writer, r, p.type);
            }
        }
        try aw.writer.writeByte(']');
        const before = b.out.items.len;
        try b.add(try aw.toOwnedSlice());
        if (b.out.items.len > before) produced += 1;
        if (b.out.items.len >= b.max) break;
    }
    return b.out.toOwnedSlice(a);
}

// ---------------------------------------------------------------- tests

test "every edge value is valid JSON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    inline for (@typeInfo(ParamType).@"enum".field_names) |name| {
        for (edges(@field(ParamType, name))) |e| {
            _ = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), e, .{});
        }
    }
}

test "generate covers edges, dedups, is deterministic and valid" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const params = [_]Param{ .{ .name = "s", .type = .string }, .{ .name = "n", .type = .int, .optional = true } };
    const one = try generate(a, &params, .{ .samples = 50, .seed = 7 });
    const two = try generate(a, &params, .{ .samples = 50, .seed = 7 });
    try std.testing.expectEqual(one.len, two.len);
    for (one, two) |x, y| try std.testing.expectEqualStrings(x, y);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var saw_null = false;
    for (one) |c| {
        try std.testing.expect(!(try seen.getOrPut(a, c)).found_existing);
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, c, .{});
        try std.testing.expectEqual(@as(usize, 2), v.array.items.len);
        if (v.array.items[1] == .null) saw_null = true;
    }
    try std.testing.expect(saw_null);
    // typical + edges for each param + null + samples
    try std.testing.expect(one.len >= edges(.string).len + edges(.int).len);
}

test "generate respects max_cases and zero params" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const params = [_]Param{ .{ .name = "x", .type = .number }, .{ .name = "y", .type = .number } };
    try std.testing.expectEqual(@as(usize, 10), (try generate(a, &params, .{ .max_cases = 10 })).len);
    const none = try generate(a, &.{}, .{});
    try std.testing.expectEqual(@as(usize, 1), none.len);
    try std.testing.expectEqualStrings("[]", none[0]);
}
