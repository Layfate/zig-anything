//! Structure-aware mutation of recorded argument arrays, for `fuzz`.
//!
//! A mutation keeps the arity and the JSON shape of each argument (an
//! integer stays an integer, a string stays a string) so the original keeps
//! accepting it, then changes one or more values: boundary numbers,
//! character edits that keep UTF-8 valid, element insertion, removal and
//! swaps, and splicing in values seen elsewhere in the corpus.

const std = @import("std");
const json = std.json;
const lang = @import("lang.zig");
const Allocator = std.mem.Allocator;
const Value = json.Value;

const interesting_ints = [_]i64{ 0, 1, -1, 2, 7, 8, 10, 16, 31, 32, 63, 64, 100, 127, 128, 255, 256, 1000, 1024, 4096, 65535, 65536, 2147483647, -2147483648, 4294967295, 9007199254740991, -9007199254740991 };
const interesting_floats = [_]f64{ 0, -0.0, 0.5, -0.5, 1e-9, 1e-300, 0.1, 0.2, 0.3, 1.5, 2.5, 3.14159, 1e9, 1e21, -1e21, 1.7976931348623157e308, 5e-324 };
const insert_bits = [_][]const u8{ " ", "  ", "-", "_", ".", ",", "\n", "\t", "\r\n", "\"", "\\", "'", "0", "9", "a", "Z", "é", "ß", "中", "🎉", "\u{200b}", "\u{0301}", "İ", "ﬁ", "<", "&", "%", "/" };

pub const Mutator = struct {
    a: Allocator,
    r: std.Random,
    /// Strings seen anywhere in the corpus, for splicing.
    strings: std.ArrayList([]const u8) = .empty,
    /// Numbers seen anywhere in the corpus.
    numbers: std.ArrayList(f64) = .empty,

    /// Remembers the strings and numbers of `v` for later splicing.
    pub fn learn(m: *Mutator, v: Value) !void {
        switch (v) {
            .string => |s| if (m.strings.items.len < 4096) try m.strings.append(m.a, s),
            .integer => |i| if (m.numbers.items.len < 4096) try m.numbers.append(m.a, @floatFromInt(i)),
            .float => |f| if (m.numbers.items.len < 4096) try m.numbers.append(m.a, f),
            .array => |arr| for (arr.items) |x| try m.learn(x),
            .object => |o| {
                if (o.get("$num") != null) return;
                var it = o.iterator();
                while (it.next()) |e| try m.learn(e.value_ptr.*);
            },
            else => {},
        }
    }

    /// Returns a mutated copy of the argument array `args` (as JSON text).
    /// `params` gives the declared type of each top-level argument.
    pub fn mutate(m: *Mutator, params: []const lang.Param, args: []const Value) ![]const u8 {
        const out = try m.a.dupe(Value, args);
        if (out.len == 0) return "[]";
        // Stack 1 to 3 mutations, like havoc mode in coverage-guided fuzzers.
        const stack = 1 + m.r.uintLessThan(usize, 3);
        for (0..stack) |_| {
            const i = m.r.uintLessThan(usize, out.len);
            const t: lang.ParamType = if (i < params.len) params[i].type else .any;
            out[i] = try m.value(out[i], t, 0);
        }
        return json.Stringify.valueAlloc(m.a, Value{ .array = json.Array.fromOwnedSlice(m.a, out) }, .{});
    }

    fn value(m: *Mutator, v: Value, t: lang.ParamType, depth: u32) error{OutOfMemory}!Value {
        if (depth > 8) return v;
        return switch (v) {
            .bool => |b| .{ .bool = !b },
            .integer => |i| .{ .integer = m.int(i, t) },
            .float => |f| m.float(f, t),
            .number_string => v,
            .string => |s| .{ .string = try m.string(s) },
            .array => |arr| try m.array(arr.items, t, depth),
            .object => |o| blk: {
                if (o.get("$num") != null) break :blk m.float(0, t);
                if (o.count() == 0) break :blk v;
                var copy = try o.clone(m.a);
                const k = m.r.uintLessThan(usize, copy.count());
                copy.values()[k] = try m.value(copy.values()[k], .any, depth + 1);
                break :blk .{ .object = copy };
            },
            .null => switch (t) {
                .int => .{ .integer = 0 },
                .number => .{ .float = 0.5 },
                .string => .{ .string = "" },
                .bool => .{ .bool = true },
                else => v,
            },
        };
    }

    fn int(m: *Mutator, i: i64, t: lang.ParamType) i64 {
        _ = t;
        return switch (m.r.uintLessThan(u8, 8)) {
            0 => i +% 1,
            1 => i -% 1,
            2 => -%i,
            3 => i *% 2,
            4 => @divTrunc(i, 2),
            5 => interesting_ints[m.r.uintLessThan(usize, interesting_ints.len)],
            6 => if (m.numbers.items.len > 0) clampInt(m.numbers.items[m.r.uintLessThan(usize, m.numbers.items.len)]) else 0,
            else => m.r.intRangeAtMost(i64, -64, 64),
        };
    }

    fn float(m: *Mutator, f: f64, t: lang.ParamType) Value {
        const choice = m.r.uintLessThan(u8, 10);
        // Non-finite values travel as {"$num": ...}; only for number params.
        if (choice == 9 and t == .number) {
            const tags = [_][]const u8{ "NaN", "Infinity", "-Infinity" };
            return numTag(m.a, tags[m.r.uintLessThan(usize, tags.len)]) catch .{ .float = f };
        }
        const x: f64 = switch (choice) {
            0 => f + 1,
            1 => f - 1,
            2 => -f,
            3 => f * 2,
            4 => f / 2,
            5 => interesting_floats[m.r.uintLessThan(usize, interesting_floats.len)],
            6 => if (m.numbers.items.len > 0) m.numbers.items[m.r.uintLessThan(usize, m.numbers.items.len)] else 0,
            7 => f + (m.r.float(f64) - 0.5) * 1e-6,
            else => @round(f),
        };
        return if (std.math.isFinite(x)) .{ .float = x } else .{ .float = f };
    }

    fn string(m: *Mutator, s: []const u8) ![]const u8 {
        const cps = try codepoints(m.a, s);
        var list: std.ArrayList([]const u8) = .fromOwnedSlice(cps);
        switch (m.r.uintLessThan(u8, 9)) {
            0, 1 => { // insert
                const at = m.r.uintAtMost(usize, list.items.len);
                try list.insert(m.a, at, insert_bits[m.r.uintLessThan(usize, insert_bits.len)]);
            },
            2 => if (list.items.len > 0) { // delete a run
                const at = m.r.uintLessThan(usize, list.items.len);
                const n = @min(list.items.len - at, 1 + m.r.uintLessThan(usize, 4));
                list.replaceRangeAssumeCapacity(at, n, &.{});
            },
            3 => if (list.items.len > 0) { // duplicate a run
                const at = m.r.uintLessThan(usize, list.items.len);
                const n = @min(list.items.len - at, 1 + m.r.uintLessThan(usize, 8));
                const run = try m.a.dupe([]const u8, list.items[at .. at + n]);
                try list.insertSlice(m.a, at, run);
            },
            4 => if (list.items.len > 0) { // swap case of one character
                const at = m.r.uintLessThan(usize, list.items.len);
                const ch = list.items[at];
                if (ch.len == 1 and std.ascii.isAlphabetic(ch[0])) {
                    const flipped = try m.a.alloc(u8, 1);
                    flipped[0] = if (std.ascii.isUpper(ch[0])) std.ascii.toLower(ch[0]) else std.ascii.toUpper(ch[0]);
                    list.items[at] = flipped;
                }
            },
            5 => if (m.strings.items.len > 0) { // splice in another corpus string
                const other = try codepoints(m.a, m.strings.items[m.r.uintLessThan(usize, m.strings.items.len)]);
                const at = m.r.uintAtMost(usize, list.items.len);
                try list.insertSlice(m.a, at, other[0..@min(other.len, 32)]);
            },
            6 => if (list.items.len > 1) { // truncate
                list.shrinkRetainingCapacity(m.r.uintLessThan(usize, list.items.len));
            },
            7 => return "",
            else => if (m.strings.items.len > 0) return m.strings.items[m.r.uintLessThan(usize, m.strings.items.len)],
        }
        return std.mem.concat(m.a, u8, list.items);
    }

    fn array(m: *Mutator, items: []const Value, t: lang.ParamType, depth: u32) !Value {
        const elem: lang.ParamType = switch (t) {
            .number_array => .number,
            .int_array => .int,
            .string_array => .string,
            else => .any,
        };
        var list: std.ArrayList(Value) = .empty;
        try list.appendSlice(m.a, items);
        switch (m.r.uintLessThan(u8, 7)) {
            0 => if (list.items.len > 0) { // mutate one element
                const k = m.r.uintLessThan(usize, list.items.len);
                list.items[k] = try m.value(list.items[k], elem, depth + 1);
            },
            1 => if (list.items.len > 0) { // insert a mutated copy
                const k = m.r.uintLessThan(usize, list.items.len);
                try list.insert(m.a, m.r.uintAtMost(usize, list.items.len), try m.value(list.items[k], elem, depth + 1));
            } else try list.append(m.a, switch (elem) {
                .int => .{ .integer = 1 },
                .number => .{ .float = 1.5 },
                .string => .{ .string = "a" },
                else => .{ .integer = 0 },
            }),
            2 => if (list.items.len > 0) {
                _ = list.orderedRemove(m.r.uintLessThan(usize, list.items.len));
            },
            3 => if (list.items.len > 1) { // swap two
                const x = m.r.uintLessThan(usize, list.items.len);
                const y = m.r.uintLessThan(usize, list.items.len);
                std.mem.swap(Value, &list.items[x], &list.items[y]);
            },
            4 => if (list.items.len > 0) { // duplicate one
                const k = m.r.uintLessThan(usize, list.items.len);
                try list.insert(m.a, k, list.items[k]);
            },
            5 => std.mem.reverse(Value, list.items),
            else => list.clearRetainingCapacity(),
        }
        return .{ .array = list.toManaged(m.a) };
    }
};

fn clampInt(f: f64) i64 {
    if (!std.math.isFinite(f)) return 0;
    return @intFromFloat(std.math.clamp(@trunc(f), -9007199254740991, 9007199254740991));
}

fn numTag(a: Allocator, tag: []const u8) !Value {
    var o: json.ObjectMap = .empty;
    try o.put(a, "$num", .{ .string = tag });
    return .{ .object = o };
}

/// Splits UTF-8 into code points (invalid bytes become single-byte pieces).
fn codepoints(a: Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + n, s.len);
        try out.append(a, s[i..end]);
        i = end;
    }
    return out.toOwnedSlice(a);
}

test "mutations keep arity, shape and valid UTF-8" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(7);
    var m: Mutator = .{ .a = a, .r = prng.random() };
    const params = [_]lang.Param{ .{ .name = "s", .type = .string }, .{ .name = "n", .type = .int }, .{ .name = "xs", .type = .number_array } };
    const seed = try json.parseFromSliceLeaky(Value, a, "[\"héllo 🎉\", 3, [1.5, 2]]", .{});
    try m.learn(seed);
    var distinct: std.StringHashMapUnmanaged(void) = .empty;
    for (0..500) |_| {
        const text = try m.mutate(&params, seed.array.items);
        const v = try json.parseFromSliceLeaky(Value, a, text, .{});
        try std.testing.expectEqual(@as(usize, 3), v.array.items.len);
        try std.testing.expect(v.array.items[0] == .string);
        try std.testing.expect(std.unicode.utf8ValidateSlice(v.array.items[0].string));
        try std.testing.expect(v.array.items[1] == .integer);
        try std.testing.expect(v.array.items[2] == .array);
        try distinct.put(a, text, {});
    }
    // Mutations actually explore: at least half of them are new inputs, even
    // from a single seed (the fuzz loop also drops repeats).
    try std.testing.expect(distinct.count() >= 250);
}

test "mutation is deterministic for a seed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const params = [_]lang.Param{.{ .name = "x", .type = .number }};
    const seed = try json.parseFromSliceLeaky(Value, a, "[2.5]", .{});
    var outs: [2][]const u8 = undefined;
    for (&outs) |*o| {
        var prng: std.Random.DefaultPrng = .init(42);
        var m: Mutator = .{ .a = a, .r = prng.random() };
        var all: std.ArrayList(u8) = .empty;
        for (0..50) |_| try all.appendSlice(a, try m.mutate(&params, seed.array.items));
        o.* = all.items;
    }
    try std.testing.expectEqualStrings(outs[0], outs[1]);
}
