//! `build` compiles a unit; `diff` replays every recorded case against the
//! Zig port and reports mismatches.

const std = @import("std");
const json = std.json;
const cli = @import("../cli.zig");
const jsonx = @import("../jsonx.zig");
const proc = @import("../proc.zig");
const cases_mod = @import("../cases.zig");
const unit_mod = @import("../unit.zig");
const Io = std.Io;
const Case = cases_mod.Case;
const program = @import("program.zig");

pub const build_flags = [_]cli.Flag{
    .{ .name = "optimize", .value = "MODE", .help = "debug, safe (default), fast or small" },
};

pub const diff_flags = [_]cli.Flag{
    .{ .name = "tolerance", .value = "X", .help = "float tolerance, absolute or relative (default from config: 0)" },
    .{ .name = "strict-errors", .help = "error names must match exactly (default: any error matches any error)" },
    .{ .name = "limit", .value = "N", .help = "mismatches to print (default 10)" },
    .{ .name = "no-build", .help = "use the existing harness binary" },
    .{ .name = "optimize", .value = "MODE", .help = "build mode: debug, safe (default; keeps safety checks), fast or small" },
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
    harness,
    crash,
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
            .harness => "harness could not call the port",
            .crash => "port crashed on this case",
            .not_run => "not run (port crashed earlier)",
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

    pub fn passed(o: Outcome) bool {
        return o.compared > 0 and o.matched == o.compared and !o.crashed;
    }
};

pub const Options = struct {
    tolerance: f64 = 0,
    strict_errors: bool = false,
};

fn errName(v: json.Value) ?[]const u8 {
    if (v != .object) return null;
    const e = v.object.get("err") orelse return null;
    return if (e == .string) e.string else "?";
}

/// Classifies one case. Returns null on a match.
pub fn classify(expect: json.Value, got: json.Value, opts: Options) ?Kind {
    if (got == .object and got.object.get("harness_error") != null) return .harness;
    const got_err = errName(got);
    if (errName(expect)) |want| {
        const have = got_err orelse return .missing_error;
        if (opts.strict_errors and !std.mem.eql(u8, want, have)) return .error_name;
        return null;
    }
    if (got_err != null) return .unexpected_error;
    const want_ok = if (expect == .object) expect.object.get("ok") else null;
    const have_ok = if (got == .object) got.object.get("ok") else null;
    if (want_ok == null or have_ok == null) return .value;
    return if (jsonx.equal(want_ok.?, have_ok.?, .{ .tolerance = opts.tolerance })) null else .value;
}

/// Runs the (already built) harness over every case and compares.
pub fn replay(c: *cli.Ctx, u: unit_mod.Unit, cs: []const Case, opts: Options) cli.Reported!Outcome {
    try u.ensureWorkDir(c);
    const exe = u.harnessExe(c.arena, "zig-out");
    const out_path = u.workPath(c.arena, "actual.jsonl");
    Io.Dir.cwd().deleteFile(c.io, out_path) catch {};
    const r = try proc.run(c, &.{ exe, "run", u.path(c.arena, unit_mod.cases_name), out_path }, .{
        .cwd = u.dir,
        .timeout_s = u.cfg.config.timeout,
        .missing_hint = "build the unit first: zig-anything build <unit>",
    });
    const text = Io.Dir.cwd().readFileAlloc(c.io, out_path, c.arena, .unlimited) catch "";
    var lines: std.ArrayList([]const u8) = .empty;
    var it: cases_mod.LineIterator = .{ .rest = text };
    while (it.next()) |l| lines.append(c.arena, l) catch return c.fail("out of memory", .{});

    var mismatches: std.ArrayList(Mismatch) = .empty;
    var matched: usize = 0;
    var compared: usize = 0;
    var flaky: usize = 0;
    const crashed = !r.ok or lines.items.len < cs.len;
    for (cs, 0..) |*case, i| {
        if (case.flaky) {
            flaky += 1;
            continue;
        }
        compared += 1;
        if (i >= lines.items.len) {
            const kind: Kind = if (i == lines.items.len) .crash else .not_run;
            mismatches.append(c.arena, .{ .case = case, .kind = kind, .got = null }) catch return c.fail("out of memory", .{});
            continue;
        }
        const got = json.parseFromSliceLeaky(json.Value, c.arena, lines.items[i], .{}) catch {
            mismatches.append(c.arena, .{ .case = case, .kind = .harness, .got = null }) catch return c.fail("out of memory", .{});
            continue;
        };
        if (classify(case.expect, got, opts)) |kind| {
            mismatches.append(c.arena, .{ .case = case, .kind = kind, .got = got }) catch return c.fail("out of memory", .{});
        } else matched += 1;
    }
    return .{
        .total = cs.len,
        .compared = compared,
        .matched = matched,
        .flaky = flaky,
        .mismatches = mismatches.items,
        .crashed = crashed,
        .crash_stderr = if (crashed) r.stderr else "",
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
    for (o.mismatches) |m| {
        if (m.kind == .not_run) continue;
        if (shown == limit) break;
        shown += 1;
        c.print("{s}case {d}{s}: {s}\n", .{ c.s(.yellow), m.case.id, c.s(.reset), m.kind.label() });
        c.print("  args      {s}\n", .{show(c, m.case.args)});
        c.print("  expected  {s}\n", .{show(c, m.case.expect)});
        c.print("  got       {s}\n", .{show(c, m.got)});
    }
    const visible = o.mismatches.len;
    if (visible > shown) c.print("... and {d} more (--limit N to show more)\n", .{visible - shown});
    const color = if (o.passed()) c.s(.green) else c.s(.red);
    c.print("{s}{d}/{d}{s} cases match", .{ color, o.matched, o.compared, c.s(.reset) });
    if (o.flaky > 0) c.print(" ({d} flaky skipped)", .{o.flaky});
    c.print("  [{s}]\n", .{c.rel(u.dir)});
}

pub fn runDiff(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const u = try unit_mod.load(c, args.pos(0));
    if (u.isCli()) return program.runDiff(c, u, args);
    const cs = try cases_mod.load(c, u);
    const opts: Options = .{
        .tolerance = try cli.parseFloat(c, args, "tolerance", u.cfg.config.tolerance),
        .strict_errors = args.has("strict-errors"),
    };
    const limit = try cli.parseInt(usize, c, args, "limit", 10);
    if (!args.has("no-build")) {
        if (!try unit_mod.build(c, u, try parseOptimize(c, args), "zig-out", null)) {
            c.report("build failed; fix the compile errors above", .{});
            return 1;
        }
    }
    const o = try replay(c, u, cs, opts);
    saveSummary(c, u, o);
    if (args.has("json")) {
        c.print("{{\"unit\":", .{});
        jsonx.writeString(c.out, u.manifest.name) catch {};
        c.print(",\"total\":{d},\"compared\":{d},\"matched\":{d},\"flaky\":{d},\"crashed\":{},\"passed\":{},\"mismatches\":[", .{
            o.total, o.compared, o.matched, o.flaky, o.crashed, o.passed(),
        });
        for (o.mismatches[0..@min(o.mismatches.len, limit)], 0..) |m, i| {
            if (i != 0) c.print(",", .{});
            c.print("{{\"id\":{d},\"kind\":\"{s}\",\"args\":{s},\"expected\":{s},\"got\":{s}}}", .{
                m.case.id,                                                           @tagName(m.kind), jsonx.stringify(c.arena, m.case.args) catch "null", jsonx.stringify(c.arena, m.case.expect) catch "null",
                if (m.got) |g| jsonx.stringify(c.arena, g) catch "null" else "null",
            });
        }
        c.print("]}}\n", .{});
    } else printReport(c, u, o, limit);
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
    try std.testing.expectEqual(@as(?Kind, null), classify(P.p(a, "{\"ok\":1}"), P.p(a, "{\"ok\":1.0}"), .{}));
    try std.testing.expectEqual(Kind.value, classify(P.p(a, "{\"ok\":1}"), P.p(a, "{\"ok\":2}"), .{}).?);
    try std.testing.expectEqual(Kind.unexpected_error, classify(P.p(a, "{\"ok\":1}"), P.p(a, "{\"err\":\"X\"}"), .{}).?);
    try std.testing.expectEqual(Kind.missing_error, classify(P.p(a, "{\"err\":\"TypeError\"}"), P.p(a, "{\"ok\":1}"), .{}).?);
    try std.testing.expectEqual(@as(?Kind, null), classify(P.p(a, "{\"err\":\"TypeError\",\"msg\":\"m\"}"), P.p(a, "{\"err\":\"Bad\"}"), .{}));
    try std.testing.expectEqual(Kind.error_name, classify(P.p(a, "{\"err\":\"TypeError\"}"), P.p(a, "{\"err\":\"Bad\"}"), .{ .strict_errors = true }).?);
    try std.testing.expectEqual(Kind.harness, classify(P.p(a, "{\"ok\":1}"), P.p(a, "{\"harness_error\":\"x\"}"), .{}).?);
}
