//! JSON helpers shared by the recorder, differ and generator: semantic
//! equality of recorded values and a fast string escaper.

const std = @import("std");
const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const CompareOptions = struct {
    /// Absolute-or-relative tolerance for floating point comparison.
    /// 0 means "the same f64 after parsing".
    tolerance: f64 = 0,
};

/// Numeric view of a JSON value, including `{"$num": ...}` tags.
fn asNumber(v: json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        .object => |o| blk: {
            if (o.count() != 1) break :blk null;
            const t = o.get("$num") orelse break :blk null;
            if (t != .string) break :blk null;
            if (std.mem.eql(u8, t.string, "NaN")) break :blk std.math.nan(f64);
            if (std.mem.eql(u8, t.string, "Infinity")) break :blk std.math.inf(f64);
            if (std.mem.eql(u8, t.string, "-Infinity")) break :blk -std.math.inf(f64);
            break :blk null;
        },
        else => null,
    };
}

fn isNumeric(v: json.Value) bool {
    return switch (v) {
        .integer, .float, .number_string => true,
        .object => asNumber(v) != null,
        else => false,
    };
}

fn numbersEqual(a: f64, b: f64, tol: f64) bool {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.isNan(a) and std.math.isNan(b);
    if (a == b) return true;
    if (tol == 0 or std.math.isInf(a) or std.math.isInf(b)) return false;
    const diff = @abs(a - b);
    return diff <= tol or diff <= tol * @max(@abs(a), @abs(b));
}

/// Semantic equality: numbers compare by value (so `1`, `1.0` and `1e0` are
/// equal), objects compare without regard to key order, and arrays compare
/// element-wise.
pub fn equal(a: json.Value, b: json.Value, opts: CompareOptions) bool {
    if (isNumeric(a) and isNumeric(b)) {
        // Exact integer comparison first so large integers never lose precision.
        if (a == .integer and b == .integer) return a.integer == b.integer;
        if (a == .number_string and b == .number_string) {
            if (std.mem.eql(u8, a.number_string, b.number_string)) return true;
        }
        return numbersEqual(asNumber(a).?, asNumber(b).?, opts.tolerance);
    }
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (b != .array or b.array.items.len != x.items.len) break :blk false;
            for (x.items, b.array.items) |l, r| {
                if (!equal(l, r, opts)) break :blk false;
            }
            break :blk true;
        },
        .object => |x| blk: {
            if (b != .object or b.object.count() != x.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!equal(entry.value_ptr.*, other, opts)) break :blk false;
            }
            break :blk true;
        },
        .integer, .float, .number_string => false,
    };
}

/// Writes `s` as a JSON string literal (UTF-8 passed through).
pub fn writeString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c >= 0x20 and c != '"' and c != '\\') continue;
        try w.writeAll(s[start..i]);
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.print("\\u{x:0>4}", .{c}),
        }
        start = i + 1;
    }
    try w.writeAll(s[start..]);
    try w.writeByte('"');
}

/// Stringifies a value compactly into `a`.
pub fn stringify(a: Allocator, v: json.Value) ![]u8 {
    return json.Stringify.valueAlloc(a, v, .{});
}

/// Returns `s` shortened to at most `max` bytes (on a UTF-8 boundary) with an
/// ellipsis appended when truncated.
pub fn truncate(a: Allocator, s: []const u8, max: usize) ![]const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(a, "{s}…", .{s[0..end]});
}

/// A short type label used in record summaries.
pub fn kindName(v: json.Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "bool",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => if (asNumber(v) != null) "number" else "object",
    };
}

// ---------------------------------------------------------------- tests

fn p(a: Allocator, s: []const u8) !json.Value {
    return json.parseFromSliceLeaky(json.Value, a, s, .{});
}

test "numbers compare by value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(equal(try p(a, "1"), try p(a, "1.0"), .{}));
    try std.testing.expect(equal(try p(a, "1e2"), try p(a, "100"), .{}));
    try std.testing.expect(!equal(try p(a, "0.1"), try p(a, "0.10000000000000002"), .{}));
    try std.testing.expect(equal(try p(a, "0.1"), try p(a, "0.10000000000000002"), .{ .tolerance = 1e-12 }));
    try std.testing.expect(equal(try p(a, "{\"$num\":\"NaN\"}"), try p(a, "{\"$num\":\"NaN\"}"), .{}));
    try std.testing.expect(!equal(try p(a, "{\"$num\":\"Infinity\"}"), try p(a, "1e308"), .{ .tolerance = 1 }));
    try std.testing.expect(equal(try p(a, "123456789012345678901234567890"), try p(a, "123456789012345678901234567890"), .{}));
    try std.testing.expect(!equal(try p(a, "9007199254740993"), try p(a, "9007199254740992"), .{}));
}

test "structural comparison" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(equal(try p(a, "{\"a\":1,\"b\":[true,null]}"), try p(a, "{\"b\":[true,null],\"a\":1.0}"), .{}));
    try std.testing.expect(!equal(try p(a, "{\"a\":1}"), try p(a, "{\"a\":1,\"b\":2}"), .{}));
    try std.testing.expect(!equal(try p(a, "[1,2]"), try p(a, "[2,1]"), .{}));
    try std.testing.expect(!equal(try p(a, "\"1\""), try p(a, "1"), .{}));
    try std.testing.expect(!equal(try p(a, "null"), try p(a, "false"), .{}));
    try std.testing.expect(equal(try p(a, "\"héllo\""), try p(a, "\"h\\u00e9llo\""), .{}));
}

test "writeString escapes control characters" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeString(&aw.writer, "a\"b\\c\nd\x01é");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001é\"", aw.written());
}

test "truncate respects UTF-8 boundaries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("abc", try truncate(a, "abc", 10));
    try std.testing.expectEqualStrings("é…", try truncate(a, "éé", 3));
}
