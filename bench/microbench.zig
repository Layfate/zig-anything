//! Micro benchmarks for zig-anything's own hot paths. Run with
//! `zig build microbench`. Each benchmark repeats until ~0.5 s has elapsed
//! and reports the median of 5 such rounds.

const std = @import("std");
const za = @import("zig_anything_src");
const Io = std.Io;
const Allocator = std.mem.Allocator;

fn now(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).nanoseconds;
}

fn report(name: []const u8, ns_per_op: f64, bytes_per_op: ?usize) void {
    if (bytes_per_op) |b| {
        const mbps = @as(f64, @floatFromInt(b)) / ns_per_op * 1e9 / (1024 * 1024);
        std.debug.print("{s: <44} {d: >12.1} us/op  {d: >8.1} MiB/s\n", .{ name, ns_per_op / 1000, mbps });
    } else {
        std.debug.print("{s: <44} {d: >12.1} us/op\n", .{ name, ns_per_op / 1000 });
    }
}

fn bench(io: Io, gpa: Allocator, name: []const u8, bytes: ?usize, ctx: anytype, comptime f: fn (@TypeOf(ctx), Allocator) anyerror!void) !void {
    var rounds: [5]f64 = undefined;
    for (&rounds) |*r| {
        var ops: u64 = 0;
        const start = now(io);
        while (now(io) - start < 500 * std.time.ns_per_ms / 5) {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            try f(ctx, arena.allocator());
            ops += 1;
        }
        r.* = @as(f64, @floatFromInt(now(io) - start)) / @as(f64, @floatFromInt(ops));
    }
    std.mem.sort(f64, &rounds, {}, std.sort.asc(f64));
    report(name, rounds[2], bytes);
}

const js_unit =
    \\// A representative chunk of a JavaScript module.
    \\import { helper } from "./helper.js";
    \\const re = /[a-z]+\/(\d+)/gi;
    \\export function slugify(text, sep = "-") {
    \\  return text.toLowerCase().replace(/[^a-z0-9]+/g, sep).replace(/^-|-$/g, "");
    \\}
    \\export const clamp = (value, lo = 0, hi = 1) => Math.min(Math.max(value, lo), hi);
    \\function internal(items) { return items.map((x) => `${x}:${helper(x)}`).join(","); }
    \\export async function load(url, { retries = 3 } = {}) {
    \\  for (let i = 0; i < retries; i++) { try { return await fetch(url); } catch (e) { /* retry */ } }
    \\  throw new Error(`failed: ${url}`);
    \\}
    \\module.exports = { internal };
    \\
;

const py_unit =
    \\def mean(values: list[float]) -> float:
    \\    """Arithmetic mean."""
    \\    return sum(values) / len(values)
    \\
    \\def slugify(text, sep="-"):
    \\    return sep.join(text.lower().split())
    \\
    \\class Thing:
    \\    def method(self, x):
    \\        return x * 2
    \\
;

fn repeat(a: Allocator, unit: []const u8, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |_| try out.appendSlice(a, unit);
    return out.items;
}

fn scanJs(src: []const u8, a: Allocator) anyerror!void {
    const fns = try za.scan.scanSource(a, .javascript, src);
    std.mem.doNotOptimizeAway(fns.len);
}

fn scanPy(src: []const u8, a: Allocator) anyerror!void {
    const fns = try za.scan.scanSource(a, .python, src);
    std.mem.doNotOptimizeAway(fns.len);
}

const params = [_]za.lang.Param{
    .{ .name = "query", .type = .string },
    .{ .name = "limit", .type = .int, .optional = true },
    .{ .name = "weights", .type = .number_array },
};

fn generate(_: void, a: Allocator) anyerror!void {
    const cs = try za.gen.generate(a, &params, .{ .samples = 1000, .max_cases = 5000 });
    std.mem.doNotOptimizeAway(cs.len);
}

const CompareCtx = struct { expected: []const u8, actual: []const u8 };

fn parseAndCompare(ctx: CompareCtx, a: Allocator) anyerror!void {
    const exp = try za.cases.parseCases(a, ctx.expected);
    var it: za.cases.LineIterator = .{ .rest = ctx.actual };
    var matched: usize = 0;
    for (exp) |case| {
        const line = it.next() orelse break;
        const got = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        if (za.jsonx.equal(case.expect.object.get("ok").?, got.object.get("ok").?, .{})) matched += 1;
    }
    std.mem.doNotOptimizeAway(matched);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    std.debug.print("zig-anything micro benchmarks (median of 5 rounds)\n\n", .{});

    const js = try repeat(a, js_unit, 1000);
    try bench(io, gpa, "scan JavaScript (1000 functions-ish module)", js.len, js, scanJs);
    const py = try repeat(a, py_unit, 1000);
    try bench(io, gpa, "scan Python (3000 defs)", py.len, py, scanPy);
    try bench(io, gpa, "generate cases (3 params, 1000 samples)", null, {}, generate);

    // 100k recorded cases with float/string/array results, and matching output.
    var expected: std.ArrayList(u8) = .empty;
    var actual: std.ArrayList(u8) = .empty;
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();
    for (0..100_000) |i| {
        const x = r.float(f64) * 1000;
        try expected.print(a, "{{\"id\":{d},\"args\":[\"q{d}\",{d}],\"expect\":{{\"ok\":{{\"score\":{d},\"tags\":[\"a\",\"b\"],\"n\":{d}}}}}}}\n", .{ i + 1, i, i % 50, x, i });
        try actual.print(a, "{{\"ok\":{{\"n\":{d}.0,\"tags\":[\"a\",\"b\"],\"score\":{d}}}}}\n", .{ i, x });
    }
    try bench(io, gpa, "parse + compare 100k cases", expected.items.len + actual.items.len, CompareCtx{ .expected = expected.items, .actual = actual.items }, parseAndCompare);
}
