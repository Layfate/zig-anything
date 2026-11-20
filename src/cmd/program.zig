//! Program units: port a whole command-line program, in any language.
//!
//! A case is an invocation: arguments plus optional stdin. Recording runs
//! the original command; diffing runs the Zig program built from
//! src/main.zig. Both run from the same working directory and are compared
//! on stdout and exit code (and stderr with --compare-stderr).

const std = @import("std");
const json = std.json;
const cli = @import("../cli.zig");
const config = @import("../config.zig");
const jsonx = @import("../jsonx.zig");
const proc = @import("../proc.zig");
const cases_mod = @import("../cases.zig");
const unit_mod = @import("../unit.zig");
const diff = @import("diff.zig");
const bench = @import("bench.zig");
const Io = std.Io;
const Case = cases_mod.Case;

const build_template = @embedFile("../assets/cli_build.zig");

pub const init_flags = [_]cli.Flag{
    .{ .name = "out", .value = "DIR", .help = "unit directory (default: <units_dir>/<name>)" },
    .{ .name = "cwd", .value = "DIR", .help = "working directory for both programs (default: current directory)" },
    .{ .name = "force", .help = "regenerate the manifest of an existing unit (main.zig is kept)" },
};

// ------------------------------------------------------------------ init

fn renderMain(a: std.mem.Allocator, command_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\//! Zig port of the program `{s}`.
        \\//!
        \\//! Write the program below, then:
        \\//!   zig-anything diff <unit>   compare with every recorded run
        \\//!   zig-anything gate <unit>   every check must pass
        \\//!
        \\//! Each recorded case runs this program with the case's arguments and
        \\//! stdin, from the same working directory as the original, and compares
        \\//! stdout and the exit code.
        \\
        \\const std = @import("std");
        \\const Io = std.Io;
        \\
        \\// {s}: port this program, then delete this line.
        \\pub fn main(init: std.process.Init) !u8 {{
        \\    const io = init.io;
        \\    const arena = init.arena.allocator();
        \\    const args = try init.minimal.args.toSlice(arena); // args[0] is the program itself
        \\
        \\    var in_buf: [4096]u8 = undefined;
        \\    var stdin = Io.File.stdin().readerStreaming(io, &in_buf);
        \\    const input = try stdin.interface.allocRemaining(arena, .unlimited);
        \\
        \\    var out_buf: [4096]u8 = undefined;
        \\    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
        \\    const out = &stdout.interface;
        \\
        \\    _ = args;
        \\    _ = input;
        \\    try out.writeAll("not ported yet\n");
        \\    try out.flush();
        \\    return 1;
        \\}}
        \\
    , .{ command_text, unit_mod.todo_marker });
}

pub fn runInit(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const usage = "usage: zig-anything init-cli <name> -- <command> [args...]";
    const name = args.pos(0) orelse return c.fail("{s}", .{usage});
    if (args.positional.len < 2) {
        c.hint("example: zig-anything init-cli wordcount -- python tools/wc.py", .{});
        return c.fail("{s}", .{usage});
    }
    const command = args.positional[1..];
    const cfg = try config.load(c, c.cwd);
    const dir = if (args.get("out")) |o|
        c.abs(o) catch return c.fail("out of memory", .{})
    else
        std.fs.path.join(c.arena, &.{ cfg.root, cfg.config.units_dir, name }) catch return c.fail("out of memory", .{});
    const run_dir = c.abs(args.get("cwd") orelse ".") catch return c.fail("out of memory", .{});
    Io.Dir.cwd().access(c.io, run_dir, .{}) catch return c.fail("working directory {s} does not exist", .{run_dir});

    const manifest_path = std.fs.path.join(c.arena, &.{ dir, unit_mod.manifest_name }) catch return c.fail("out of memory", .{});
    if (unit_mod.exists(c, manifest_path) and !args.has("force")) {
        c.hint("pass --force to regenerate its manifest (your main.zig is kept)", .{});
        return c.fail("a unit already exists at {s}", .{c.rel(dir)});
    }
    const manifest: unit_mod.Manifest = .{
        .kind = .cli,
        .name = name,
        .command = command,
        .cwd = try unit_mod.relativeSource(c, dir, run_dir),
    };
    const text = std.json.Stringify.valueAlloc(c.arena, manifest, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }) catch return c.fail("out of memory", .{});
    try unit_mod.writeFile(c, manifest_path, std.mem.concat(c.arena, u8, &.{ text, "\n" }) catch return c.fail("out of memory", .{}));

    const j = struct {
        fn f(cc: *cli.Ctx, parts: []const []const u8) cli.Reported![]const u8 {
            return std.fs.path.join(cc.arena, parts) catch cc.fail("out of memory", .{});
        }
    }.f;
    const command_text = std.mem.join(c.arena, " ", command) catch return c.fail("out of memory", .{});
    const build_path = try j(c, &.{ dir, "build.zig" });
    if (!unit_mod.exists(c, build_path)) try unit_mod.writeFile(c, build_path, build_template);
    const gi = try j(c, &.{ dir, ".gitignore" });
    if (!unit_mod.exists(c, gi)) try unit_mod.writeFile(c, gi, "zig-out/\nzig-out-fast/\n.zig-cache/\n.za/\n");
    const inputs = try j(c, &.{ dir, unit_mod.inputs_name });
    if (!unit_mod.exists(c, inputs)) try unit_mod.writeFile(c, inputs,
        \\# One run per line: an argument array, or {"args": [...], "stdin": "..."}.
        \\# Lines starting with # are ignored. Add the invocations that matter.
        \\[]
        \\
    );
    const main_path = try j(c, &.{ dir, "src", "main.zig" });
    const created = !unit_mod.exists(c, main_path);
    if (created) try unit_mod.writeFile(c, main_path, renderMain(c.arena, command_text) catch return c.fail("out of memory", .{}));

    const rel_dir = c.rel(dir);
    c.print("{s}created{s} program unit {s}{s}{s} for `{s}`\n", .{ c.s(.green), c.s(.reset), c.s(.bold), rel_dir, c.s(.reset), command_text });
    c.print("  runs in   {s}\n  inputs    {s}/inputs.jsonl (edit: one invocation per line)\n  port      {s}/src/main.zig{s}\n", .{ c.rel(run_dir), rel_dir, rel_dir, if (created) " (new stub)" else " (kept)" });
    c.print("\nnext:\n  # add invocations to {s}/inputs.jsonl\n  zig-anything record {s}\n  zig-anything diff {s}\n", .{ rel_dir, rel_dir, rel_dir });
    return 0;
}

// ---------------------------------------------------------------- record

const Invocation = struct {
    args: []const []const u8,
    args_json: []const u8,
    stdin: ?[]const u8,
};

fn readInputs(c: *cli.Ctx, u: unit_mod.Unit) cli.Reported![]Invocation {
    const p = u.path(c.arena, unit_mod.inputs_name);
    const text = Io.Dir.cwd().readFileAlloc(c.io, p, c.arena, .limited(256 << 20)) catch {
        c.hint("add one invocation per line, e.g. [\"--upper\", \"file.txt\"] or {{\"args\": [], \"stdin\": \"hello\\n\"}}", .{});
        return c.fail("program units need {s}", .{c.rel(p)});
    };
    var list: std.ArrayList(Invocation) = .empty;
    var it: cases_mod.LineIterator = .{ .rest = text };
    var line_no: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        if (line[0] == '#' or std.mem.startsWith(u8, line, "//")) continue;
        const v = json.parseFromSliceLeaky(json.Value, c.arena, line, .{}) catch
            return c.fail("{s}:{d}: not valid JSON", .{ c.rel(p), line_no });
        var args_v: json.Value = v;
        var stdin: ?[]const u8 = null;
        if (v == .object) {
            args_v = v.object.get("args") orelse .{ .array = .init(c.arena) };
            if (v.object.get("stdin")) |si| {
                if (si != .string) return c.fail("{s}:{d}: \"stdin\" must be a string", .{ c.rel(p), line_no });
                stdin = si.string;
            }
        }
        if (args_v != .array) return c.fail("{s}:{d}: expected an argument array like [\"--flag\", \"value\"]", .{ c.rel(p), line_no });
        const strs = c.arena.alloc([]const u8, args_v.array.items.len) catch return c.fail("out of memory", .{});
        for (args_v.array.items, strs) |item, *slot| {
            if (item != .string) return c.fail("{s}:{d}: every argument must be a string", .{ c.rel(p), line_no });
            slot.* = item.string;
        }
        list.append(c.arena, .{
            .args = strs,
            .args_json = jsonx.stringify(c.arena, args_v) catch return c.fail("out of memory", .{}),
            .stdin = stdin,
        }) catch return c.fail("out of memory", .{});
    }
    if (list.items.len == 0) return c.fail("{s} has no invocations", .{c.rel(p)});
    return list.items;
}

const Outcome = struct { stdout: []const u8, stderr: []const u8, exit: ?u8, ns: u64 };

/// Runs one invocation of `program` (+ args) with optional stdin.
fn invoke(c: *cli.Ctx, u: unit_mod.Unit, program: []const []const u8, inv_args: []const []const u8, stdin: ?[]const u8, idx: usize) cli.Reported!Outcome {
    var stdin_path: ?[]const u8 = null;
    if (stdin) |text| {
        const p = u.workPath(c.arena, std.fmt.allocPrint(c.arena, "stdin-{d}.txt", .{idx}) catch return c.fail("out of memory", .{}));
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = p, .data = text }) catch |err| return c.fail("cannot write {s}: {s}", .{ p, @errorName(err) });
        stdin_path = p;
    }
    const r = try proc.run(c, proc.command(c, program, inv_args), .{
        .cwd = u.cwd_abs,
        .timeout_s = u.cfg.config.timeout,
        .stdin_path = stdin_path,
    });
    return .{ .stdout = r.stdout, .stderr = r.stderr, .exit = r.exit_code, .ns = r.ns };
}

fn writeExpect(w: *Io.Writer, o: Outcome) !void {
    try w.writeAll("{\"ok\":{\"stdout\":");
    try jsonx.writeString(w, o.stdout);
    try w.writeAll(",\"stderr\":");
    try jsonx.writeString(w, o.stderr);
    if (o.exit) |code| try w.print(",\"exit\":{d}}}}}", .{code}) else try w.writeAll(",\"exit\":null}}");
}

pub fn record(c: *cli.Ctx, u: unit_mod.Unit, args: cli.Parsed) !u8 {
    const invs = try readInputs(c, u);
    try u.ensureWorkDir(c);
    const verify = !args.has("no-verify");
    const command_text = std.mem.join(c.arena, " ", u.manifest.command) catch "";
    c.print("recording `{s}`: {d} invocation(s) in {s}\n", .{ command_text, invs.len, c.rel(u.cwd_abs) });
    c.out.flush() catch {};

    var aw: Io.Writer.Allocating = .init(c.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    var flaky_n: usize = 0;
    var exits: std.AutoArrayHashMapUnmanaged(i32, usize) = .empty;
    for (invs, 0..) |inv, i| {
        const first = try invoke(c, u, u.manifest.command, inv.args, inv.stdin, i);
        var flaky = false;
        if (verify) {
            const second = try invoke(c, u, u.manifest.command, inv.args, inv.stdin, i);
            flaky = !std.mem.eql(u8, first.stdout, second.stdout) or first.exit != second.exit;
        }
        if (flaky) flaky_n += 1;
        const gop = exits.getOrPut(c.arena, if (first.exit) |e| e else -1) catch return c.fail("out of memory", .{});
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        try w.print("{{\"id\":{d},\"args\":{s}", .{ i + 1, inv.args_json });
        if (inv.stdin) |text| {
            try w.writeAll(",\"stdin\":");
            try jsonx.writeString(w, text);
        }
        try w.writeAll(",\"expect\":");
        try writeExpect(w, first);
        if (flaky) try w.writeAll(",\"flaky\":true");
        try w.writeAll("}\n");
    }
    const cases_path = u.path(c.arena, unit_mod.cases_name);
    const previous = Io.Dir.cwd().readFileAlloc(c.io, cases_path, c.arena, .unlimited) catch null;
    const unchanged = previous != null and std.mem.eql(u8, previous.?, aw.written());
    if (!unchanged) try unit_mod.writeFile(c, cases_path, aw.written());

    c.print("{s}recorded{s} {d} run(s) -> {s}{s}\n  exit codes  ", .{ c.s(.green), c.s(.reset), invs.len, c.rel(cases_path), if (unchanged) " (unchanged)" else "" });
    var eit = exits.iterator();
    var first_e = true;
    while (eit.next()) |e| {
        if (e.key_ptr.* < 0) {
            c.print("{s}signal {d}", .{ if (first_e) "" else ", ", e.value_ptr.* });
        } else c.print("{s}{d}: {d}", .{ if (first_e) "" else ", ", e.key_ptr.*, e.value_ptr.* });
        first_e = false;
    }
    c.print("\n", .{});
    if (verify) c.print("  flaky       {d}{s}\n", .{ flaky_n, if (flaky_n > 0) " (output differed between two runs; diff skips them)" else "" });
    return 0;
}

// ------------------------------------------------------------------ diff

pub const CompareOptions = struct {
    compare_stderr: bool = false,
    /// Compare "\r\n" and "\n" as different (default: normalize to "\n").
    exact_newlines: bool = false,
};

fn normalizedEql(a_text: []const u8, b_text: []const u8, exact: bool) bool {
    if (exact) return std.mem.eql(u8, a_text, b_text);
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        if (i < a_text.len and a_text[i] == '\r' and i + 1 < a_text.len and a_text[i + 1] == '\n') i += 1;
        if (j < b_text.len and b_text[j] == '\r' and j + 1 < b_text.len and b_text[j + 1] == '\n') j += 1;
        if (i == a_text.len or j == b_text.len) return i == a_text.len and j == b_text.len;
        if (a_text[i] != b_text[j]) return false;
        i += 1;
        j += 1;
    }
}

fn field(v: json.Value, name: []const u8) ?json.Value {
    if (v != .object) return null;
    const ok = v.object.get("ok") orelse return null;
    if (ok != .object) return null;
    return ok.object.get(name);
}

pub fn classify(expect: json.Value, got: Outcome, opts: CompareOptions) ?diff.Kind {
    const want_exit: ?i64 = if (field(expect, "exit")) |e| (if (e == .integer) e.integer else null) else null;
    const have_exit: ?i64 = if (got.exit) |e| @as(i64, e) else null;
    if (want_exit != have_exit) return .exit_code;
    const want_out = if (field(expect, "stdout")) |s| (if (s == .string) s.string else "") else "";
    if (!normalizedEql(want_out, got.stdout, opts.exact_newlines)) return .stdout;
    if (opts.compare_stderr) {
        const want_err = if (field(expect, "stderr")) |s| (if (s == .string) s.string else "") else "";
        if (!normalizedEql(want_err, got.stderr, opts.exact_newlines)) return .stderr;
    }
    return null;
}

fn outcomeValue(c: *cli.Ctx, o: Outcome) ?json.Value {
    var aw: Io.Writer.Allocating = .init(c.arena);
    writeExpect(&aw.writer, o) catch return null;
    return json.parseFromSliceLeaky(json.Value, c.arena, aw.written(), .{}) catch null;
}

/// Runs the built Zig program (from `prefix`) over every case.
pub fn replay(c: *cli.Ctx, u: unit_mod.Unit, cs: []const Case, prefix: []const u8, opts: CompareOptions) cli.Reported!diff.Outcome {
    try u.ensureWorkDir(c);
    const exe = std.fs.path.join(c.arena, &.{ u.dir, prefix, "bin", "port" ++ proc.exe_suffix }) catch return c.fail("out of memory", .{});
    var mismatches: std.ArrayList(diff.Mismatch) = .empty;
    var matched: usize = 0;
    var compared: usize = 0;
    var flaky: usize = 0;
    for (cs, 0..) |*case, i| {
        if (case.flaky) {
            flaky += 1;
            continue;
        }
        compared += 1;
        var argv: std.ArrayList([]const u8) = .empty;
        for (case.args.array.items) |a| if (a == .string) argv.append(c.arena, a.string) catch {};
        const got = try invoke(c, u, &.{exe}, argv.items, case.stdin, i);
        if (classify(case.expect, got, opts)) |kind| {
            mismatches.append(c.arena, .{ .case = case, .kind = kind, .got = outcomeValue(c, got) }) catch return c.fail("out of memory", .{});
        } else matched += 1;
    }
    return .{ .total = cs.len, .compared = compared, .matched = matched, .flaky = flaky, .mismatches = mismatches.items, .crashed = false, .crash_stderr = "" };
}

pub fn runDiff(c: *cli.Ctx, u: unit_mod.Unit, args: cli.Parsed) !u8 {
    const cs = try cases_mod.load(c, u);
    const limit = try cli.parseInt(usize, c, args, "limit", 10);
    if (!args.has("no-build")) {
        if (!try unit_mod.build(c, u, try diff.parseOptimize(c, args), "zig-out", null)) {
            c.report("build failed; fix the compile errors above", .{});
            return 1;
        }
    }
    const o = try replay(c, u, cs, "zig-out", .{ .compare_stderr = args.has("compare-stderr"), .exact_newlines = args.has("exact-newlines") });
    diff.saveSummary(c, u, o);
    if (args.has("json")) {
        c.print("{{\"unit\":", .{});
        jsonx.writeString(c.out, u.manifest.name) catch {};
        c.print(",\"total\":{d},\"compared\":{d},\"matched\":{d},\"flaky\":{d},\"passed\":{}}}\n", .{ o.total, o.compared, o.matched, o.flaky, o.passed() });
    } else diff.printReport(c, u, o, limit);
    return if (o.passed()) 0 else 1;
}

// ----------------------------------------------------------------- bench

pub fn measure(c: *cli.Ctx, u: unit_mod.Unit, runs: u32, do_build: bool, quiet: bool) cli.Reported!bench.Result {
    const cs = try cases_mod.load(c, u);
    if (do_build) {
        if (!quiet) {
            c.print("building optimized program (-Doptimize=fast)...\n", .{});
            c.out.flush() catch {};
        }
        if (!try unit_mod.build(c, u, .fast, "zig-out-fast", null)) return c.fail("build failed", .{});
    }
    const exe = std.fs.path.join(c.arena, &.{ u.dir, "zig-out-fast", "bin", "port" ++ proc.exe_suffix }) catch return c.fail("out of memory", .{});
    var stable: std.ArrayList(*const Case) = .empty;
    for (cs) |*case| if (!case.flaky) stable.append(c.arena, case) catch {};
    if (stable.items.len == 0) return c.fail("no deterministic runs to benchmark", .{});

    const orig = c.arena.alloc(f64, runs) catch return c.fail("out of memory", .{});
    const port = c.arena.alloc(f64, runs) catch return c.fail("out of memory", .{});
    for (0..runs) |r| {
        if (!quiet) {
            c.print("\rrun {d}/{d}", .{ r + 1, runs });
            c.out.flush() catch {};
        }
        var to: u64 = 0;
        var tp: u64 = 0;
        for (stable.items, 0..) |case, i| {
            var argv: std.ArrayList([]const u8) = .empty;
            for (case.args.array.items) |a| if (a == .string) argv.append(c.arena, a.string) catch {};
            to += (try invoke(c, u, u.manifest.command, argv.items, case.stdin, i)).ns;
            tp += (try invoke(c, u, &.{exe}, argv.items, case.stdin, i)).ns;
        }
        const n: f64 = @floatFromInt(stable.items.len);
        orig[r] = @as(f64, @floatFromInt(to)) / n;
        port[r] = @as(f64, @floatFromInt(tp)) / n;
    }
    if (!quiet) c.print("\r", .{});
    std.mem.sort(f64, orig, {}, std.sort.asc(f64));
    std.mem.sort(f64, port, {}, std.sort.asc(f64));
    const mo = orig[runs / 2];
    const mp = @max(port[runs / 2], 1);
    const res: bench.Result = .{
        .cases = stable.items.len,
        .runs = runs,
        .original_ns_per_call = mo,
        .port_ns_per_call = mp,
        .original_process_ns = mo,
        .port_process_ns = mp,
        .speedup = mo / mp,
        .process_speedup = mo / mp,
        .verdict = bench.verdictFor(mo / mp),
    };
    const saved = std.json.Stringify.valueAlloc(c.arena, res, .{}) catch "";
    Io.Dir.cwd().writeFile(c.io, .{ .sub_path = u.workPath(c.arena, "bench.json"), .data = saved }) catch {};
    return res;
}

pub fn runBench(c: *cli.Ctx, u: unit_mod.Unit, args: cli.Parsed) !u8 {
    const runs = try cli.parseInt(u32, c, args, "runs", 5);
    if (runs == 0) return c.fail("--runs must be at least 1", .{});
    const r = try measure(c, u, runs, !args.has("no-build"), args.has("json"));
    if (args.has("json")) {
        std.json.Stringify.value(r, .{}, c.out) catch {};
        c.print("\n", .{});
        return 0;
    }
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const ratio = if (r.speedup >= 1)
        std.fmt.allocPrint(c.arena, "{d:.1}x faster", .{r.speedup}) catch ""
    else
        std.fmt.allocPrint(c.arena, "{d:.1}x slower", .{1 / r.speedup}) catch "";
    c.print("{s}bench {s}{s}  ({d} runs per side, median of {d})\n", .{ c.s(.bold), u.manifest.name, c.s(.reset), r.cases, r.runs });
    c.print("                 {s: <16}{s: <16}\n", .{ "original", "zig port" });
    c.print("  per run        {s: <16}{s: <16}{s}\n", .{ proc.fmtNs(&b1, r.original_ns_per_call), proc.fmtNs(&b2, r.port_ns_per_call), ratio });
    const color = if (std.mem.eql(u8, r.verdict, "faster")) c.s(.green) else if (std.mem.eql(u8, r.verdict, "slower")) c.s(.red) else c.s(.yellow);
    c.print("verdict: {s}{s}{s} (whole process, startup included)\n", .{ color, r.verdict, c.s(.reset) });
    return 0;
}

test "newline-normalized comparison" {
    try std.testing.expect(normalizedEql("a\r\nb\r\n", "a\nb\n", false));
    try std.testing.expect(!normalizedEql("a\r\nb", "a\nb", true));
    try std.testing.expect(!normalizedEql("a\nb", "a\nc", false));
    try std.testing.expect(!normalizedEql("a\n", "a", false));
    try std.testing.expect(normalizedEql("", "", false));
}

test "classify program outcomes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expect = try json.parseFromSliceLeaky(json.Value, a, "{\"ok\":{\"stdout\":\"3\\n\",\"stderr\":\"\",\"exit\":0}}", .{});
    try std.testing.expectEqual(@as(?diff.Kind, null), classify(expect, .{ .stdout = "3\r\n", .stderr = "x", .exit = 0, .ns = 0 }, .{}));
    try std.testing.expectEqual(diff.Kind.exit_code, classify(expect, .{ .stdout = "3\n", .stderr = "", .exit = 1, .ns = 0 }, .{}).?);
    try std.testing.expectEqual(diff.Kind.stdout, classify(expect, .{ .stdout = "4\n", .stderr = "", .exit = 0, .ns = 0 }, .{}).?);
    try std.testing.expectEqual(diff.Kind.stderr, classify(expect, .{ .stdout = "3\n", .stderr = "x", .exit = 0, .ns = 0 }, .{ .compare_stderr = true }).?);
}
