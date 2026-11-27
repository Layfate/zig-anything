//! `build` compiles a unit; `diff` replays every recorded case against the
//! Zig port and reports mismatches.
//!
//! Replay runs the harness over ranges of cases. Large recordings are split
//! into ranges that run in parallel, one process each. When the port crashes
//! (or hangs past the timeout) on a case, that case is reported and the
//! harness is restarted just after it, so every case still gets a verdict.

const std = @import("std");
const json = std.json;
const cli = @import("../cli.zig");
const jsonx = @import("../jsonx.zig");
const proc = @import("../proc.zig");
const cases_mod = @import("../cases.zig");
const unit_mod = @import("../unit.zig");
const runtime = @import("../runtime.zig");
const Io = std.Io;
const Case = cases_mod.Case;
const program = @import("program.zig");
const record = @import("record.zig");

pub const build_flags = [_]cli.Flag{
    .{ .name = "optimize", .value = "MODE", .help = "debug, safe (default), fast or small" },
};

pub const diff_flags = [_]cli.Flag{
    .{ .name = "tolerance", .value = "X", .help = "float tolerance, absolute or relative (default from config: 0)" },
    .{ .name = "strict-errors", .help = "error names must match exactly (default: any error matches any error)" },
    .{ .name = "limit", .value = "N", .help = "mismatches to print (default 10)" },
    .{ .name = "case", .value = "IDS", .help = "only replay these case ids, e.g. 3 or 3,17,40" },
    .{ .name = "no-build", .help = "use the existing harness binary" },
    .{ .name = "optimize", .value = "MODE", .help = "build mode: debug, safe (default; keeps safety checks), fast or small" },
    .{ .name = "effects", .help = "compare argument mutation and printed output even if the recording did not ask for it" },
    .{ .name = "jobs", .value = "N", .help = "parallel harness processes for large recordings (default: one per CPU core)" },
    .{ .name = "json", .help = "machine-readable summary" },
    .{ .name = "compare-stderr", .help = "program units: also compare stderr" },
    .{ .name = "exact-newlines", .help = "program units: treat CRLF and LF line endings as different" },
};

pub fn parseOptimize(c: *cli.Ctx, args: cli.Parsed) cli.Reported!unit_mod.Optimize {
    const v = args.get("optimize") orelse return .safe;
    return unit_mod.Optimize.parse(v) orelse
        c.fail("--optimize must be debug, safe, fast or small (got '{s}')", .{v});
}

pub fn runBuild(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const u = try unit_mod.load(c, args.pos(0));
    const mode = try parseOptimize(c, args);
    c.print("building {s} ({s})...\n", .{ c.rel(u.dir), @tagName(mode) });
    c.out.flush() catch {};
    if (!try unit_mod.build(c, u, mode, "zig-out", null)) {
        c.report("build failed; fix the compile errors above", .{});
        return 1;
    }
    c.print("{s}built{s} {s}\n", .{ c.s(.green), c.s(.reset), c.rel(u.harnessExe(c.arena, "zig-out")) });
    return 0;
}

pub const Kind = enum {
    value,
    unexpected_error,
    missing_error,
    error_name,
    mutation,
    output,
    harness,
    crash,
    timeout,
    not_run,
    stdout,
    exit_code,
    stderr,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .value => "different value",
            .unexpected_error => "port returned an error, original returned a value",
            .missing_error => "original threw, port returned a value",
            .error_name => "different error name",
            .mutation => "arguments differ after the call (mutation)",
            .output => "different printed output",
            .harness => "harness could not call the port",
            .crash => "port crashed on this case",
            .timeout => "port did not finish this case in time",
            .not_run => "not run (too many crashes)",
            .stdout => "different stdout",
            .exit_code => "different exit code",
            .stderr => "different stderr",
        };
    }
};

pub const Mismatch = struct {
    case: *const Case,
    kind: Kind,
    got: ?json.Value,
};

pub const Outcome = struct {
    total: usize,
    compared: usize,
    matched: usize,
    flaky: usize,
    mismatches: []const Mismatch,
    crashed: bool,
    crash_stderr: []const u8,
    /// Cases the port crashed or hung on.
    crashes: usize = 0,

    pub fn passed(o: Outcome) bool {
        return o.compared > 0 and o.matched == o.compared and !o.crashed;
    }
};

pub const Options = struct {
    tolerance: f64 = 0,
    strict_errors: bool = false,
    /// Compare "mut" (arguments after the call) and "out" (printed output).
    effects: bool = false,
    /// Parallel harness processes (1 = a single process).
    jobs: usize = 1,
    /// Compare integers as doubles (see jsonx.CompareOptions.doubles).
    doubles: bool = false,
};

fn errName(v: json.Value) ?[]const u8 {
    if (v != .object) return null;
    const e = v.object.get("err") orelse return null;
    return if (e == .string) e.string else "?";
}

fn field(v: json.Value, name: []const u8) ?json.Value {
    return if (v == .object) v.object.get(name) else null;
}

/// Classifies one case. Returns null on a match. `args` are the recorded
/// arguments, which an absent "mut" means are unchanged.
pub fn classify(expect: json.Value, got: json.Value, args: json.Value, opts: Options) ?Kind {
    if (got == .object and got.object.get("harness_error") != null) return .harness;
    const got_err = errName(got);
    if (errName(expect)) |want| {
        const have = got_err orelse return .missing_error;
        if (opts.strict_errors and !std.mem.eql(u8, want, have)) return .error_name;
    } else {
        if (got_err != null) return .unexpected_error;
        const want_ok = field(expect, "ok");
        const have_ok = field(got, "ok");
        if (want_ok == null or have_ok == null) return .value;
        if (!jsonx.equal(want_ok.?, have_ok.?, .{ .tolerance = opts.tolerance, .doubles = opts.doubles })) return .value;
    }
    if (opts.effects) {
        const want_mut = field(expect, "mut") orelse args;
        const have_mut = field(got, "mut") orelse args;
        if (!jsonx.equal(want_mut, have_mut, .{ .tolerance = opts.tolerance, .doubles = opts.doubles })) return .mutation;
        const want_out = field(expect, "out");
        const have_out = field(got, "out");
        const wo = if (want_out) |o| (if (o == .string) o.string else "") else "";
        const ho = if (have_out) |o| (if (o == .string) o.string else "") else "";
        if (!std.mem.eql(u8, wo, ho)) return .output;
    }
    return null;
}

/// Effects are compared when the recording captured them (or on request).
pub fn effectsWanted(c: *cli.Ctx, u: unit_mod.Unit, args: cli.Parsed) bool {
    if (args.has("effects")) return true;
    const rec = record.loadRecording(c, u) orelse return false;
    return rec.effects;
}

/// The longest any case is allowed to take before the harness is stopped
/// and the case is reported as hung.
const max_crash_resumes = 64;

const Range = struct { first: usize, end: usize };

/// One harness run over a range; returns the result lines it produced.
const Slot = struct {
    lines: []const []const u8 = &.{},
    finished: bool = false,
    timed_out: bool = false,
    stderr: []const u8 = "",
};

fn splitLines(c: *cli.Ctx, text: []const u8) cli.Reported![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it: cases_mod.LineIterator = .{ .rest = text };
    while (it.next()) |l| lines.append(c.arena, l) catch return c.fail("out of memory", .{});
    return lines.items;
}

/// Runs the (already built) harness over every case and compares.
pub fn replay(c: *cli.Ctx, u: unit_mod.Unit, cs: []const Case, opts: Options) cli.Reported!Outcome {
    return replayFile(c, u, cs, u.path(c.arena, unit_mod.cases_name), opts);
}

/// Like `replay`, with the cases read by the harness from `cases_path`
/// (whose lines must correspond one to one with `cs`).
pub fn replayFile(c: *cli.Ctx, u: unit_mod.Unit, cs: []const Case, cases_path: []const u8, opts: Options) cli.Reported!Outcome {
    try u.ensureWorkDir(c);
    const exe = u.harnessExe(c.arena, "zig-out");
    Io.Dir.cwd().access(c.io, exe, .{}) catch {
        c.hint("build the unit first: zig-anything build <unit>", .{});
        return c.fail("no harness at {s}", .{c.rel(exe)});
    };

    // Below a few thousand cases one process is faster than several: the
    // harness starts in milliseconds and most ports take microseconds.
    const min_per_shard = 2000;
    const shards = std.math.clamp(cs.len / min_per_shard, 1, @max(opts.jobs, 1));
    var pending: std.ArrayList(Range) = .empty;
    const per = (cs.len + shards - 1) / @max(shards, 1);
    for (0..shards) |k| {
        const lo = @min(k * per, cs.len);
        const hi = @min(lo + per, cs.len);
        if (hi > lo) pending.append(c.arena, .{ .first = lo, .end = hi }) catch return c.fail("out of memory", .{});
    }

    // Result line per case, or the reason there is none.
    const got = c.arena.alloc(?[]const u8, cs.len) catch return c.fail("out of memory", .{});
    @memset(got, null);
    const failed_kind = c.arena.alloc(?Kind, cs.len) catch return c.fail("out of memory", .{});
    @memset(failed_kind, null);
    var crashes: usize = 0;
    var first_stderr: []const u8 = "";
    var attempt: usize = 0;

    while (pending.items.len > 0) {
        const batch = pending.toOwnedSlice(c.arena) catch return c.fail("out of memory", .{});
        const jobs = c.arena.alloc(proc.Job, batch.len) catch return c.fail("out of memory", .{});
        const outs = c.arena.alloc([]const u8, batch.len) catch return c.fail("out of memory", .{});
        for (batch, jobs, outs, 0..) |r, *job, *out, k| {
            out.* = if (batch.len == 1 and attempt == 0)
                u.workPath(c.arena, "actual.jsonl")
            else
                u.workPath(c.arena, std.fmt.allocPrint(c.arena, "actual.{d}.{d}.jsonl", .{ attempt, k }) catch return c.fail("out of memory", .{}));
            Io.Dir.cwd().deleteFile(c.io, out.*) catch {};
            const first = std.fmt.allocPrint(c.arena, "{d}", .{r.first}) catch return c.fail("out of memory", .{});
            const end = std.fmt.allocPrint(c.arena, "{d}", .{r.end}) catch return c.fail("out of memory", .{});
            job.* = .{ .argv = c.arena.dupe([]const u8, &.{ exe, "run", cases_path, out.*, first, end }) catch return c.fail("out of memory", .{}), .opts = .{
                .cwd = u.dir,
                .timeout_s = u.cfg.config.timeout,
                .missing_hint = "build the unit first: zig-anything build <unit>",
            } };
        }
        attempt += 1;
        const results = try proc.runManyQuiet(c, jobs);
        for (batch, results, outs, jobs) |r, res, out, job| {
            const text = Io.Dir.cwd().readFileAlloc(c.io, out, c.arena, .unlimited) catch "";
            const lines = try splitLines(c, text);
            const n = @min(lines.len, r.end - r.first);
            for (lines[0..n], r.first..) |l, i| got[i] = l;
            var timed_out = false;
            var stderr: []const u8 = "";
            const ok = if (res) |rr| blk: {
                stderr = rr.stderr;
                break :blk rr.ok;
            } else |err| switch (err) {
                error.Timeout => blk: {
                    timed_out = true;
                    break :blk false;
                },
                else => return proc.reportRunError(c, job.argv, job.opts, err),
            };
            if (ok and n == r.end - r.first) continue;
            // The harness stopped early: the next case is the culprit.
            const bad = r.first + n;
            if (bad >= r.end) continue; // exited non-zero after the last case
            failed_kind[bad] = if (timed_out) .timeout else .crash;
            crashes += 1;
            if (first_stderr.len == 0) first_stderr = if (timed_out)
                std.fmt.allocPrint(c.arena, "(no output for {d}s; the port may loop forever on case {d})", .{ u.cfg.config.timeout, cs[bad].id }) catch ""
            else
                stderr;
            if (crashes <= max_crash_resumes and bad + 1 < r.end)
                pending.append(c.arena, .{ .first = bad + 1, .end = r.end }) catch return c.fail("out of memory", .{});
        }
    }

    var mismatches: std.ArrayList(Mismatch) = .empty;
    var matched: usize = 0;
    var compared: usize = 0;
    var flaky: usize = 0;
    for (cs, 0..) |*case, i| {
        if (case.flaky) {
            flaky += 1;
            continue;
        }
        compared += 1;
        const line = got[i] orelse {
            mismatches.append(c.arena, .{ .case = case, .kind = failed_kind[i] orelse .not_run, .got = null }) catch return c.fail("out of memory", .{});
            continue;
        };
        const g = json.parseFromSliceLeaky(json.Value, c.arena, line, .{}) catch {
            mismatches.append(c.arena, .{ .case = case, .kind = .harness, .got = null }) catch return c.fail("out of memory", .{});
            continue;
        };
        if (classify(case.expect, g, case.args, opts)) |kind| {
            mismatches.append(c.arena, .{ .case = case, .kind = kind, .got = g }) catch return c.fail("out of memory", .{});
        } else matched += 1;
    }
    return .{
        .total = cs.len,
        .compared = compared,
        .matched = matched,
        .flaky = flaky,
        .mismatches = mismatches.items,
        .crashed = crashes > 0,
        .crash_stderr = first_stderr,
        .crashes = crashes,
    };
}

fn show(c: *cli.Ctx, v: ?json.Value) []const u8 {
    const val = v orelse return "-";
    const s = jsonx.stringify(c.arena, val) catch return "?";
    return jsonx.truncate(c.arena, s, 160) catch s;
}

pub fn saveSummary(c: *cli.Ctx, u: unit_mod.Unit, o: Outcome) void {
    const s = std.fmt.allocPrint(c.arena, "{{\"total\":{d},\"compared\":{d},\"matched\":{d},\"flaky\":{d},\"crashed\":{},\"passed\":{}}}\n", .{
        o.total, o.compared, o.matched, o.flaky, o.crashed, o.passed(),
    }) catch return;
    Io.Dir.cwd().writeFile(c.io, .{ .sub_path = u.workPath(c.arena, "last-diff.json"), .data = s }) catch {};
}

pub fn printReport(c: *cli.Ctx, u: unit_mod.Unit, o: Outcome, limit: usize) void {
    if (o.crashed and o.crash_stderr.len > 0) {
        const tail = o.crash_stderr[o.crash_stderr.len - @min(o.crash_stderr.len, 2000) ..];
        c.print("{s}port crashed:{s}\n{s}\n", .{ c.s(.red), c.s(.reset), tail });
    }
    var shown: usize = 0;
    var not_run: usize = 0;
    for (o.mismatches) |m| {
        if (m.kind == .not_run) {
            not_run += 1;
            continue;
        }
        if (shown == limit) continue;
        shown += 1;
        c.print("{s}case {d}{s}: {s}\n", .{ c.s(.yellow), m.case.id, c.s(.reset), m.kind.label() });
        c.print("  args      {s}\n", .{show(c, m.case.args)});
        c.print("  expected  {s}\n", .{show(c, m.case.expect)});
        c.print("  got       {s}\n", .{show(c, m.got)});
    }
    const visible = o.mismatches.len - not_run;
    if (visible > shown) c.print("... and {d} more (--limit N to show more)\n", .{visible - shown});
    if (o.crashes > 1) c.print("the port crashed or hung on {d} cases; each was restarted after\n", .{o.crashes});
    if (not_run > 0) c.print("{d} case(s) not run: more than {d} crashes\n", .{ not_run, max_crash_resumes });
    const color = if (o.passed()) c.s(.green) else c.s(.red);
    c.print("{s}{d}/{d}{s} cases match", .{ color, o.matched, o.compared, c.s(.reset) });
    if (o.flaky > 0) c.print(" ({d} flaky skipped)", .{o.flaky});
    c.print("  [{s}]\n", .{c.rel(u.dir)});
}

/// Parses `--case 3,17` into the selected cases (in recorded order).
pub fn selectCases(c: *cli.Ctx, cs: []const Case, spec: []const u8) cli.Reported![]const Case {
    var out: std.ArrayList(Case) = .empty;
    var it = std.mem.tokenizeAny(u8, spec, ", ");
    var wanted: std.ArrayList(u32) = .empty;
    while (it.next()) |tok| {
        const id = std.fmt.parseInt(u32, tok, 10) catch return c.fail("--case expects case ids like 3 or 3,17 (got '{s}')", .{tok});
        wanted.append(c.arena, id) catch return c.fail("out of memory", .{});
    }
    for (cs) |case| {
        if (std.mem.indexOfScalar(u32, wanted.items, case.id) != null) out.append(c.arena, case) catch return c.fail("out of memory", .{});
    }
    if (out.items.len == 0) return c.fail("no recorded case has id {s} (ids run from 1 to {d})", .{ spec, cs.len });
    return out.items;
}

pub fn writeCasesFile(c: *cli.Ctx, u: unit_mod.Unit, cs: []const Case, name: []const u8) cli.Reported![]const u8 {
    var aw: Io.Writer.Allocating = .init(c.arena);
    for (cs) |case| aw.writer.print("{s}\n", .{case.raw}) catch return c.fail("out of memory", .{});
    const p = u.workPath(c.arena, name);
    Io.Dir.cwd().writeFile(c.io, .{ .sub_path = p, .data = aw.written() }) catch |err|
        return c.fail("cannot write {s}: {s}", .{ p, @errorName(err) });
    return p;
}

pub fn writeJson(c: *cli.Ctx, u: unit_mod.Unit, o: Outcome, limit: usize) void {
    c.print("{{\"unit\":", .{});
    jsonx.writeString(c.out, u.manifest.name) catch {};
    c.print(",\"total\":{d},\"compared\":{d},\"matched\":{d},\"flaky\":{d},\"crashed\":{},\"crashes\":{d},\"passed\":{},\"mismatches\":[", .{
        o.total, o.compared, o.matched, o.flaky, o.crashed, o.crashes, o.passed(),
    });
    for (o.mismatches[0..@min(o.mismatches.len, limit)], 0..) |m, i| {
        if (i != 0) c.print(",", .{});
        c.print("{{\"id\":{d},\"kind\":\"{s}\",\"args\":{s},\"expected\":{s},\"got\":{s}}}", .{
            m.case.id,                                                           @tagName(m.kind), jsonx.stringify(c.arena, m.case.args) catch "null", jsonx.stringify(c.arena, m.case.expect) catch "null",
            if (m.got) |g| jsonx.stringify(c.arena, g) catch "null" else "null",
        });
    }
    c.print("]}}\n", .{});
}

pub fn runDiff(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const u = try unit_mod.load(c, args.pos(0));
    if (u.isCli()) return program.runDiff(c, u, args);
    const all = try cases_mod.load(c, u);
    const opts: Options = .{
        .tolerance = try cli.parseFloat(c, args, "tolerance", u.cfg.config.tolerance),
        .strict_errors = args.has("strict-errors"),
        .effects = effectsWanted(c, u, args),
        .jobs = try cli.jobCount(c, args, u.cfg.config.jobs),
        .doubles = runtime.adapterOf(u).numbers_are_doubles,
    };
    const limit = try cli.parseInt(usize, c, args, "limit", 10);
    if (!args.has("no-build")) {
        if (!try unit_mod.build(c, u, try parseOptimize(c, args), "zig-out", null)) {
            c.report("build failed; fix the compile errors above", .{});
            return 1;
        }
    }
    const selected = args.get("case") != null;
    const cs = if (args.get("case")) |spec| try selectCases(c, all, spec) else all;
    const cases_path = if (selected) try writeCasesFile(c, u, cs, "selected.jsonl") else u.path(c.arena, unit_mod.cases_name);
    const o = try replayFile(c, u, cs, cases_path, opts);
    // A partial replay says nothing about the unit as a whole.
    if (!selected) saveSummary(c, u, o);
    if (args.has("json")) writeJson(c, u, o, limit) else printReport(c, u, o, limit);
    if (o.compared == 0) {
        c.warn("every case is flaky; nothing was compared", .{});
        return 1;
    }
    return if (o.passed()) 0 else 1;
}

test "classify" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const P = struct {
        fn p(al: std.mem.Allocator, s: []const u8) json.Value {
            return json.parseFromSliceLeaky(json.Value, al, s, .{}) catch unreachable;
        }
    };
    const none = P.p(a, "[]");
    try std.testing.expectEqual(@as(?Kind, null), classify(P.p(a, "{\"ok\":1}"), P.p(a, "{\"ok\":1.0}"), none, .{}));
    try std.testing.expectEqual(Kind.value, classify(P.p(a, "{\"ok\":1}"), P.p(a, "{\"ok\":2}"), none, .{}).?);
    try std.testing.expectEqual(Kind.unexpected_error, classify(P.p(a, "{\"ok\":1}"), P.p(a, "{\"err\":\"X\"}"), none, .{}).?);
    try std.testing.expectEqual(Kind.missing_error, classify(P.p(a, "{\"err\":\"TypeError\"}"), P.p(a, "{\"ok\":1}"), none, .{}).?);
    try std.testing.expectEqual(@as(?Kind, null), classify(P.p(a, "{\"err\":\"TypeError\",\"msg\":\"m\"}"), P.p(a, "{\"err\":\"Bad\"}"), none, .{}));
    try std.testing.expectEqual(Kind.error_name, classify(P.p(a, "{\"err\":\"TypeError\"}"), P.p(a, "{\"err\":\"Bad\"}"), none, .{ .strict_errors = true }).?);
    try std.testing.expectEqual(Kind.harness, classify(P.p(a, "{\"ok\":1}"), P.p(a, "{\"harness_error\":\"x\"}"), none, .{}).?);
}

test "classify side effects" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const P = struct {
        fn p(al: std.mem.Allocator, s: []const u8) json.Value {
            return json.parseFromSliceLeaky(json.Value, al, s, .{}) catch unreachable;
        }
    };
    const args = P.p(a, "[[3,1,2]]");
    const fx: Options = .{ .effects = true };
    // The original sorted in place; a port with const params cannot.
    const sorted = P.p(a, "{\"ok\":null,\"mut\":[[1,2,3]]}");
    try std.testing.expectEqual(Kind.mutation, classify(sorted, P.p(a, "{\"ok\":null}"), args, fx).?);
    try std.testing.expectEqual(@as(?Kind, null), classify(sorted, P.p(a, "{\"ok\":null,\"mut\":[[1,2,3]]}"), args, fx));
    // Without effects, only the value counts.
    try std.testing.expectEqual(@as(?Kind, null), classify(sorted, P.p(a, "{\"ok\":null}"), args, .{}));
    // A port that leaves its arguments alone matches an original that did too.
    try std.testing.expectEqual(@as(?Kind, null), classify(P.p(a, "{\"ok\":1}"), P.p(a, "{\"ok\":1,\"mut\":[[3,1,2]]}"), args, fx));
    try std.testing.expectEqual(Kind.output, classify(P.p(a, "{\"ok\":1,\"out\":\"hi\\n\"}"), P.p(a, "{\"ok\":1}"), args, fx).?);
    try std.testing.expectEqual(Kind.output, classify(P.p(a, "{\"ok\":1}"), P.p(a, "{\"ok\":1,\"out\":\"debug\"}"), args, fx).?);
}
