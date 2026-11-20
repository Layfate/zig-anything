//! `bench`: time the original and the Zig port on the same recorded inputs
//! and give a verdict.
//!
//! Two numbers are measured, each as the median of several runs:
//!   per call    in-process time per call after a warm-up pass (excludes
//!               runtime startup and argument parsing)
//!   end to end  wall time of one process that loads the code and runs
//!               every case once (includes startup)

const std = @import("std");
const json = std.json;
const cli = @import("../cli.zig");
const proc = @import("../proc.zig");
const cases_mod = @import("../cases.zig");
const runtime = @import("../runtime.zig");
const unit_mod = @import("../unit.zig");
const program = @import("program.zig");
const Io = std.Io;

pub const flags = [_]cli.Flag{
    .{ .name = "runs", .value = "N", .help = "measured runs per side; the median is reported (default 5)" },
    .{ .name = "target-ms", .value = "MS", .help = "approximate duration of each timed run (default 300)" },
    .{ .name = "no-build", .help = "use the existing optimized harness" },
    .{ .name = "json", .help = "machine-readable result" },
};

pub const Result = struct {
    cases: usize,
    runs: u32,
    original_ns_per_call: f64,
    port_ns_per_call: f64,
    original_process_ns: f64,
    port_process_ns: f64,
    speedup: f64,
    process_speedup: f64,
    verdict: []const u8,
};

fn median(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    const mid = xs.len / 2;
    return if (xs.len % 2 == 1) xs[mid] else (xs[mid - 1] + xs[mid]) / 2;
}

fn readNs(c: *cli.Ctx, p: []const u8) cli.Reported!f64 {
    const text = Io.Dir.cwd().readFileAlloc(c.io, p, c.arena, .limited(1 << 16)) catch |err|
        return c.fail("cannot read benchmark output {s}: {s}", .{ p, @errorName(err) });
    const v = json.parseFromSliceLeaky(json.Value, c.arena, std.mem.trim(u8, text, " \r\n"), .{}) catch
        return c.fail("benchmark output {s} is not JSON", .{p});
    const ns = if (v == .object) v.object.get("ns") else null;
    return switch (ns orelse return c.fail("benchmark output {s} has no \"ns\"", .{p})) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => c.fail("benchmark output {s}: bad \"ns\"", .{p}),
    };
}

const Side = enum { original, port };

/// One timed in-process run; returns total nanoseconds for `iters` passes.
fn timed(c: *cli.Ctx, u: unit_mod.Unit, side: Side, cases_path: []const u8, iters: u64) cli.Reported!f64 {
    const out = u.workPath(c.arena, if (side == .original) "bench.original.json" else "bench.port.json");
    switch (side) {
        .original => {
            const r = try runtime.invoke(c, u, .bench, cases_path, out, iters);
            if (!r.ok) return runtime.reportFailure(c, u, r);
        },
        .port => {
            const iters_s = std.fmt.allocPrint(c.arena, "{d}", .{iters}) catch return c.fail("out of memory", .{});
            const r = try proc.run(c, &.{ u.harnessExe(c.arena, "zig-out-fast"), "bench", cases_path, out, iters_s }, .{ .cwd = u.dir, .timeout_s = u.cfg.config.timeout });
            if (!r.ok) {
                c.err.writeAll(r.stderr) catch {};
                return c.fail("port benchmark crashed (exit code {?d})", .{r.exit_code});
            }
        },
    }
    return readNs(c, out);
}

/// One end-to-end process run (startup + every case once), wall time.
fn processRun(c: *cli.Ctx, u: unit_mod.Unit, side: Side, cases_path: []const u8) cli.Reported!f64 {
    const out = u.workPath(c.arena, "bench.e2e.jsonl");
    switch (side) {
        .original => {
            const r = try runtime.invoke(c, u, .run, cases_path, out, 1);
            if (!r.ok) return runtime.reportFailure(c, u, r);
            return @floatFromInt(r.ns);
        },
        .port => {
            const r = try proc.run(c, &.{ u.harnessExe(c.arena, "zig-out-fast"), "run", cases_path, out }, .{ .cwd = u.dir, .timeout_s = u.cfg.config.timeout });
            if (!r.ok) return c.fail("port crashed during the end-to-end run", .{});
            return @floatFromInt(r.ns);
        },
    }
}

fn calibrate(c: *cli.Ctx, u: unit_mod.Unit, side: Side, cases_path: []const u8, target_ns: f64) cli.Reported!u64 {
    var iters: u64 = 1;
    while (true) {
        const ns = @max(try timed(c, u, side, cases_path, iters), 1);
        if (ns >= target_ns / 4 or iters >= 1 << 30) {
            const scaled = @ceil(@as(f64, @floatFromInt(iters)) * target_ns / ns);
            return @intFromFloat(std.math.clamp(scaled, 1, @as(f64, 1 << 30)));
        }
        // Grow quickly while runs are too short to time reliably.
        iters = @min(iters * 10, 1 << 30);
    }
}

pub fn verdictFor(speedup: f64) []const u8 {
    if (speedup >= 1.05) return "faster";
    if (speedup <= 0.95) return "slower";
    return "parity";
}

/// Builds, calibrates and measures. Shared with `gate --bench`.
pub fn measure(c: *cli.Ctx, u: unit_mod.Unit, runs: u32, target_ms: u32, build: bool, quiet: bool) cli.Reported!Result {
    const cs = try cases_mod.load(c, u);
    try u.ensureWorkDir(c);
    // Error paths are excluded: exceptions are expensive in most runtimes and
    // cheap in Zig, which would flatter the port.
    var aw: Io.Writer.Allocating = .init(c.arena);
    var n: usize = 0;
    for (cs) |case| {
        if (case.flaky or case.isError()) continue;
        aw.writer.writeAll(case.raw) catch return c.fail("out of memory", .{});
        aw.writer.writeByte('\n') catch return c.fail("out of memory", .{});
        n += 1;
    }
    if (n == 0) return c.fail("no deterministic, non-throwing cases to benchmark", .{});
    const bench_cases = u.workPath(c.arena, "bench-cases.jsonl");
    Io.Dir.cwd().writeFile(c.io, .{ .sub_path = bench_cases, .data = aw.written() }) catch |err|
        return c.fail("cannot write {s}: {s}", .{ bench_cases, @errorName(err) });

    if (build) {
        if (!quiet) {
            c.print("building ReleaseFast harness...\n", .{});
            c.out.flush() catch {};
        }
        if (!try unit_mod.build(c, u, .fast, "zig-out-fast", null)) return c.fail("build failed", .{});
    }
    const target_ns: f64 = @as(f64, @floatFromInt(target_ms)) * 1e6;
    if (!quiet) {
        c.print("calibrating ({d} cases)...\n", .{n});
        c.out.flush() catch {};
    }
    const iters_o = try calibrate(c, u, .original, bench_cases, target_ns);
    const iters_p = try calibrate(c, u, .port, bench_cases, target_ns);

    const per_o = c.arena.alloc(f64, runs) catch return c.fail("out of memory", .{});
    const per_p = c.arena.alloc(f64, runs) catch return c.fail("out of memory", .{});
    const e2e_o = c.arena.alloc(f64, runs) catch return c.fail("out of memory", .{});
    const e2e_p = c.arena.alloc(f64, runs) catch return c.fail("out of memory", .{});
    const calls_o: f64 = @floatFromInt(n * iters_o);
    const calls_p: f64 = @floatFromInt(n * iters_p);
    for (0..runs) |i| {
        if (!quiet) {
            c.print("\rrun {d}/{d}", .{ i + 1, runs });
            c.out.flush() catch {};
        }
        // Alternate sides so machine noise affects both equally.
        per_o[i] = try timed(c, u, .original, bench_cases, iters_o) / calls_o;
        per_p[i] = try timed(c, u, .port, bench_cases, iters_p) / calls_p;
        e2e_o[i] = try processRun(c, u, .original, bench_cases);
        e2e_p[i] = try processRun(c, u, .port, bench_cases);
    }
    if (!quiet) c.print("\r", .{});
    const mo = median(per_o);
    const mp = @max(median(per_p), 0.001);
    const eo = median(e2e_o);
    const ep = @max(median(e2e_p), 1);
    const speedup = mo / mp;
    const res: Result = .{
        .cases = n,
        .runs = runs,
        .original_ns_per_call = mo,
        .port_ns_per_call = mp,
        .original_process_ns = eo,
        .port_process_ns = ep,
        .speedup = speedup,
        .process_speedup = eo / ep,
        .verdict = verdictFor(speedup),
    };
    const saved = std.json.Stringify.valueAlloc(c.arena, res, .{}) catch "";
    Io.Dir.cwd().writeFile(c.io, .{ .sub_path = u.workPath(c.arena, "bench.json"), .data = saved }) catch {};
    return res;
}

fn ratio(buf: []u8, x: f64) []const u8 {
    if (x >= 1) return std.fmt.bufPrint(buf, "{d:.1}x faster", .{x}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1}x slower", .{1 / x}) catch "?";
}

pub fn run(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const u = try unit_mod.load(c, args.pos(0));
    if (u.isCli()) return program.runBench(c, u, args);
    if (unit_mod.portIsStub(c, u)) c.warn("src/port.zig still has the {s} marker; timings may be meaningless", .{unit_mod.todo_marker});
    const runs = try cli.parseInt(u32, c, args, "runs", 5);
    if (runs == 0) return c.fail("--runs must be at least 1", .{});
    const target_ms = try cli.parseInt(u32, c, args, "target-ms", 300);
    const json_out = args.has("json");
    const r = try measure(c, u, runs, @max(target_ms, 1), !args.has("no-build"), json_out);
    if (json_out) {
        std.json.Stringify.value(r, .{}, c.out) catch {};
        c.print("\n", .{});
        return 0;
    }
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;
    c.print("{s}bench {s}{s}  ({d} cases, median of {d} runs, port built with -Doptimize=fast)\n", .{ c.s(.bold), u.manifest.function, c.s(.reset), r.cases, r.runs });
    c.print("                 {s: <16}{s: <16}\n", .{ runtime.runtimeLabel(u), "zig port" });
    c.print("  per call       {s: <16}{s: <16}{s}\n", .{ proc.fmtNs(&b1, r.original_ns_per_call), proc.fmtNs(&b2, r.port_ns_per_call), ratio(&b3, r.speedup) });
    c.print("  end to end     {s: <16}{s: <16}", .{ proc.fmtNs(&b1, r.original_process_ns), proc.fmtNs(&b2, r.port_process_ns) });
    c.print("{s}\n", .{ratio(&b3, r.process_speedup)});
    const color = if (std.mem.eql(u8, r.verdict, "faster")) c.s(.green) else if (std.mem.eql(u8, r.verdict, "slower")) c.s(.red) else c.s(.yellow);
    c.print("verdict: {s}{s}{s} per call\n", .{ color, r.verdict, c.s(.reset) });
    if (r.original_ns_per_call < 200) {
        c.hint("calls take under 200 ns; if the original calls the port across a process or FFI boundary per call, that overhead will dominate. Port the caller too, or batch.", .{});
    }
    return 0;
}

test "median and verdict" {
    var xs = [_]f64{ 5, 1, 3 };
    try std.testing.expectEqual(@as(f64, 3), median(&xs));
    var ys = [_]f64{ 4, 1, 3, 2 };
    try std.testing.expectEqual(@as(f64, 2.5), median(&ys));
    try std.testing.expectEqualStrings("faster", verdictFor(2));
    try std.testing.expectEqualStrings("parity", verdictFor(1.0));
    try std.testing.expectEqualStrings("slower", verdictFor(0.5));
}
