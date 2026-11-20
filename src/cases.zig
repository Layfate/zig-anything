//! Recorded cases (`cases.jsonl`): one JSON object per line,
//!   {"id":1,"args":[...],"expect":{"ok":<value>}}
//!   {"id":2,"args":[...],"expect":{"err":"TypeError","msg":"..."}}
//!   {"id":3,"args":[...],"expect":{...},"flaky":true}
//! `flaky` marks cases whose result differed between two recording runs.

const std = @import("std");
const json = std.json;
const cli = @import("cli.zig");
const unit_mod = @import("unit.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Case = struct {
    id: u32,
    args: json.Value,
    expect: json.Value,
    flaky: bool,
    /// The original line, reused when writing benchmark inputs.
    raw: []const u8,

    pub fn isError(c: Case) bool {
        return c.expect == .object and c.expect.object.get("err") != null;
    }
};

/// Iterates the non-empty lines of `text`.
pub const LineIterator = struct {
    rest: []const u8,

    pub fn next(it: *LineIterator) ?[]const u8 {
        while (it.rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, it.rest, '\n') orelse it.rest.len;
            const line = std.mem.trim(u8, it.rest[0..nl], " \t\r");
            it.rest = if (nl < it.rest.len) it.rest[nl + 1 ..] else it.rest[it.rest.len..];
            if (line.len != 0) return line;
        }
        return null;
    }
};

pub fn parseCases(a: Allocator, text: []const u8) error{ BadCase, OutOfMemory }![]Case {
    var out: std.ArrayList(Case) = .empty;
    var it: LineIterator = .{ .rest = text };
    var n: u32 = 0;
    while (it.next()) |line| {
        n += 1;
        const v = json.parseFromSliceLeaky(json.Value, a, line, .{}) catch return error.BadCase;
        if (v != .object) return error.BadCase;
        const o = v.object;
        const args = o.get("args") orelse return error.BadCase;
        const expect = o.get("expect") orelse return error.BadCase;
        if (args != .array or expect != .object) return error.BadCase;
        const id: u32 = if (o.get("id")) |idv| switch (idv) {
            .integer => |i| std.math.cast(u32, i) orelse n,
            else => n,
        } else n;
        const flaky = if (o.get("flaky")) |f| f == .bool and f.bool else false;
        try out.append(a, .{ .id = id, .args = args, .expect = expect, .flaky = flaky, .raw = line });
    }
    return out.toOwnedSlice(a);
}

/// Loads a unit's cases, failing with a helpful message when none exist.
pub fn load(c: *cli.Ctx, u: unit_mod.Unit) cli.Reported![]Case {
    const p = u.path(c.arena, unit_mod.cases_name);
    const text = Io.Dir.cwd().readFileAlloc(c.io, p, c.arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            c.hint("run `zig-anything record {s}` first", .{c.rel(u.dir)});
            return c.fail("no recorded cases in {s}", .{c.rel(u.dir)});
        },
        else => return c.fail("cannot read {s}: {s}", .{ c.rel(p), @errorName(err) }),
    };
    return parseCases(c.arena, text) catch |err| switch (err) {
        error.BadCase => c.fail("{s} contains a malformed line; re-run `zig-anything record`", .{c.rel(p)}),
        error.OutOfMemory => c.fail("out of memory", .{}),
    };
}

test "parse cases" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\{"id":1,"args":[1],"expect":{"ok":2}}
        \\
        \\{"id":2,"args":["x"],"expect":{"err":"TypeError","msg":"bad"},"flaky":true}
    ;
    const cs = try parseCases(arena.allocator(), text);
    try std.testing.expectEqual(@as(usize, 2), cs.len);
    try std.testing.expect(!cs[0].isError() and cs[1].isError() and cs[1].flaky);
    try std.testing.expectError(error.BadCase, parseCases(arena.allocator(), "{\"args\":1}"));
}
