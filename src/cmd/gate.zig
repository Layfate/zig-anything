//! `gate`: the definition of done for a port unit. `status`: an overview of
//! every unit under a directory.

const std = @import("std");
const json = std.json;
const cli = @import("../cli.zig");
const config = @import("../config.zig");
const jsonx = @import("../jsonx.zig");
const cases_mod = @import("../cases.zig");
const unit_mod = @import("../unit.zig");
const diff = @import("diff.zig");
const bench = @import("bench.zig");
const Io = std.Io;

pub const gate_flags = [_]cli.Flag{
    .{ .name = "bench", .help = "also require the port to be at least as fast as the original" },
    .{ .name = "tolerance", .value = "X", .help = "float tolerance for the diff check" },
    .{ .name = "strict-errors", .help = "error names must match exactly" },
    .{ .name = "json", .help = "machine-readable result" },
};

pub const status_flags = [_]cli.Flag{
    .{ .name = "json", .help = "machine-readable output" },
};

const Check = struct {
    name: []const u8,
    state: enum { pass, fail, skip },
    detail: []const u8,
};

pub fn runGate(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const u = try unit_mod.load(c, args.pos(0));
    const json_out = args.has("json");
    var checks: std.ArrayList(Check) = .empty;
    const add = struct {
        fn f(cc: *cli.Ctx, list: *std.ArrayList(Check), ch: Check, quiet: bool) void {
            list.append(cc.arena, ch) catch {};
            if (quiet) return;
            const tag = switch (ch.state) {
                .pass => .{ cc.s(.green), "[ok]  " },
                .fail => .{ cc.s(.red), "[FAIL]" },
                .skip => .{ cc.s(.dim), "[skip]" },
            };
            cc.print("{s}{s}{s} {s: <14} {s}\n", .{ tag[0], tag[1], cc.s(.reset), ch.name, ch.detail });
            cc.out.flush() catch {};
        }
    }.f;
    if (!json_out) c.print("{s}gate {s}{s}\n", .{ c.s(.bold), c.rel(u.dir), c.s(.reset) });

    add(c, &checks, .{ .name = "manifest", .state = .pass, .detail = u.manifest.function }, json_out);

    const stub = unit_mod.portIsStub(c, u);
    add(c, &checks, .{
        .name = "port written",
        .state = if (stub) .fail else .pass,
        .detail = if (stub) "src/port.zig still contains " ++ unit_mod.todo_marker else "no TODO marker",
    }, json_out);

    // Cases (load directly so a missing file is a failed check, not an abort).
    const cases_text = Io.Dir.cwd().readFileAlloc(c.io, u.path(c.arena, unit_mod.cases_name), c.arena, .unlimited) catch null;
    const cs: []const cases_mod.Case = if (cases_text) |t| cases_mod.parseCases(c.arena, t) catch &.{} else &.{};
    var stable: usize = 0;
    for (cs) |case| {
        if (!case.flaky) stable += 1;
    }
    add(c, &checks, .{
        .name = "cases recorded",
        .state = if (stable > 0) .pass else .fail,
        .detail = if (stable > 0) std.fmt.allocPrint(c.arena, "{d} deterministic case(s)", .{stable}) catch "" else "run `zig-anything record` first",
    }, json_out);

    const built = try unit_mod.build(c, u, .safe, "zig-out", null);
    add(c, &checks, .{ .name = "builds", .state = if (built) .pass else .fail, .detail = if (built) "-Doptimize=safe" else "compile errors above" }, json_out);

    if (built) {
        const tests_ok = try unit_mod.build(c, u, .debug, "zig-out", "test");
        add(c, &checks, .{ .name = "port tests", .state = if (tests_ok) .pass else .fail, .detail = if (tests_ok) "zig build test" else "failures above" }, json_out);
    } else add(c, &checks, .{ .name = "port tests", .state = .skip, .detail = "build failed" }, json_out);

    var diff_ok = false;
    if (built and stable > 0) {
        const o = try diff.replay(c, u, cs, .{
            .tolerance = try cli.parseFloat(c, args, "tolerance", u.cfg.config.tolerance),
            .strict_errors = args.has("strict-errors"),
        });
        diff_ok = o.passed();
        add(c, &checks, .{
            .name = "behavior",
            .state = if (diff_ok) .pass else .fail,
            .detail = std.fmt.allocPrint(c.arena, "{d}/{d} cases match{s}", .{ o.matched, o.compared, if (diff_ok) "" else "; run `zig-anything diff` for details" }) catch "",
        }, json_out);
    } else add(c, &checks, .{ .name = "behavior", .state = .skip, .detail = "needs a build and recorded cases" }, json_out);

    if (args.has("bench")) {
        if (diff_ok) {
            const r = try bench.measure(c, u, 3, 200, true, true);
            add(c, &checks, .{
                .name = "performance",
                .state = if (r.speedup >= 1.0) .pass else .fail,
                .detail = std.fmt.allocPrint(c.arena, "{d:.2}x per call vs original", .{r.speedup}) catch "",
            }, json_out);
        } else add(c, &checks, .{ .name = "performance", .state = .skip, .detail = "behavior must match first" }, json_out);
    }

    var failed: usize = 0;
    for (checks.items) |ch| {
        if (ch.state != .pass) failed += 1;
    }
    if (json_out) {
        c.print("{{\"unit\":", .{});
        jsonx.writeString(c.out, u.manifest.name) catch {};
        c.print(",\"passed\":{},\"checks\":[", .{failed == 0});
        for (checks.items, 0..) |ch, i| {
            if (i != 0) c.print(",", .{});
            c.print("{{\"name\":\"{s}\",\"state\":\"{s}\",\"detail\":", .{ ch.name, @tagName(ch.state) });
            jsonx.writeString(c.out, ch.detail) catch {};
            c.print("}}", .{});
        }
        c.print("]}}\n", .{});
    } else if (failed == 0) {
        c.print("{s}PASSED{s}: {s} is a faithful port\n", .{ c.s(.green), c.s(.reset), u.manifest.function });
    } else {
        c.print("{s}NOT DONE{s}: {d} check(s) did not pass\n", .{ c.s(.red), c.s(.reset), failed });
    }
    return if (failed == 0) 0 else 1;
}

// ---------------------------------------------------------------- status

const UnitStatus = struct {
    name: []const u8,
    dir: []const u8,
    language: []const u8,
    cases: usize,
    state: []const u8,
    matched: ?usize = null,
    compared: ?usize = null,
    speedup: ?f64 = null,
};

fn countLines(text: []const u8) usize {
    var it: cases_mod.LineIterator = .{ .rest = text };
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn mtime(c: *cli.Ctx, p: []const u8) ?i96 {
    const st = Io.Dir.cwd().statFile(c.io, p, .{}) catch return null;
    return st.mtime.nanoseconds;
}

fn inspect(c: *cli.Ctx, dir: []const u8) ?UnitStatus {
    const a = c.arena;
    const text = Io.Dir.cwd().readFileAlloc(c.io, std.fs.path.join(a, &.{ dir, unit_mod.manifest_name }) catch return null, a, .limited(1 << 20)) catch return null;
    const m = json.parseFromSliceLeaky(unit_mod.Manifest, a, text, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return null;
    var s: UnitStatus = .{ .name = m.name, .dir = c.rel(dir), .language = @tagName(m.language), .cases = 0, .state = "" };
    const port_path = std.fs.path.join(a, &.{ dir, "src", "port.zig" }) catch return null;
    const cases_path = std.fs.path.join(a, &.{ dir, unit_mod.cases_name }) catch return null;
    const diff_path = std.fs.path.join(a, &.{ dir, unit_mod.work_dir, "last-diff.json" }) catch return null;
    const port_text = Io.Dir.cwd().readFileAlloc(c.io, port_path, a, .limited(16 << 20)) catch "";
    const stub = std.mem.indexOf(u8, port_text, unit_mod.todo_marker) != null;
    if (Io.Dir.cwd().readFileAlloc(c.io, cases_path, a, .unlimited)) |ct| s.cases = countLines(ct) else |_| {}
    if (Io.Dir.cwd().readFileAlloc(c.io, std.fs.path.join(a, &.{ dir, unit_mod.work_dir, "bench.json" }) catch return null, a, .limited(1 << 16))) |bt| {
        if (json.parseFromSliceLeaky(json.Value, a, bt, .{})) |bv| {
            if (bv == .object) if (bv.object.get("speedup")) |sp| switch (sp) {
                .float => |f| s.speedup = f,
                .integer => |i| s.speedup = @floatFromInt(i),
                else => {},
            };
        } else |_| {}
    } else |_| {}
    var last_passed: ?bool = null;
    if (Io.Dir.cwd().readFileAlloc(c.io, diff_path, a, .limited(1 << 16))) |dt| {
        if (json.parseFromSliceLeaky(json.Value, a, dt, .{})) |dv| {
            if (dv == .object) {
                if (dv.object.get("matched")) |x| if (x == .integer) {
                    s.matched = @intCast(x.integer);
                };
                if (dv.object.get("compared")) |x| if (x == .integer) {
                    s.compared = @intCast(x.integer);
                };
                if (dv.object.get("passed")) |x| if (x == .bool) {
                    last_passed = x.bool;
                };
            }
        } else |_| {}
    } else |_| {}
    const stale = blk: {
        const dm = mtime(c, diff_path) orelse break :blk false;
        const pm = mtime(c, port_path) orelse 0;
        const cm = mtime(c, cases_path) orelse 0;
        break :blk pm > dm or cm > dm;
    };
    s.state = if (stub)
        "stub"
    else if (s.cases == 0)
        "unrecorded"
    else if (last_passed == null)
        "untested"
    else if (stale)
        "stale"
    else if (last_passed.?)
        "passing"
    else
        "failing";
    return s;
}

pub fn runStatus(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const root = if (args.pos(0)) |p|
        c.abs(p) catch return c.fail("out of memory", .{})
    else blk: {
        const cfg = try config.load(c, c.cwd);
        const units = std.fs.path.join(c.arena, &.{ cfg.root, cfg.config.units_dir }) catch return c.fail("out of memory", .{});
        Io.Dir.cwd().access(c.io, units, .{}) catch break :blk c.cwd;
        break :blk units;
    };
    var list: std.ArrayList(UnitStatus) = .empty;
    if (inspect(c, root)) |s| list.append(c.arena, s) catch {};
    {
        var dir = Io.Dir.cwd().openDir(c.io, root, .{ .iterate = true }) catch return c.fail("cannot open {s}", .{c.rel(root)});
        defer dir.close(c.io);
        var walker = dir.walkSelectively(c.gpa) catch return c.fail("out of memory", .{});
        defer walker.deinit();
        while (walker.next(c.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = entry.basename;
            if (name[0] == '.' or std.mem.eql(u8, name, "node_modules") or std.mem.eql(u8, name, "zig-out") or
                std.mem.eql(u8, name, "zig-out-fast") or std.mem.eql(u8, name, "src")) continue;
            const full = std.fs.path.join(c.arena, &.{ root, entry.path }) catch continue;
            if (inspect(c, full)) |s| {
                list.append(c.arena, s) catch {};
                continue; // units don't nest
            }
            if (entry.depth() < 4) walker.enter(c.io, entry) catch {};
        }
    }
    std.mem.sort(UnitStatus, list.items, {}, struct {
        fn lt(_: void, x: UnitStatus, y: UnitStatus) bool {
            return std.mem.lessThan(u8, x.dir, y.dir);
        }
    }.lt);

    if (args.has("json")) {
        std.json.Stringify.value(list.items, .{}, c.out) catch {};
        c.print("\n", .{});
        return 0;
    }
    if (list.items.len == 0) {
        c.print("no port units under {s}\n", .{c.rel(root)});
        c.hint("create one with `zig-anything init <source-file> <function>`", .{});
        return 0;
    }
    c.print("{s}{s: <24} {s: <11} {s: >6}  {s: <11} {s: <12} {s}{s}\n", .{ c.s(.bold), "UNIT", "LANGUAGE", "CASES", "STATE", "LAST DIFF", "SPEEDUP", c.s(.reset) });
    var passing: usize = 0;
    for (list.items) |s| {
        if (std.mem.eql(u8, s.state, "passing")) passing += 1;
        var db: [32]u8 = undefined;
        var sb: [32]u8 = undefined;
        const d = if (s.matched != null and s.compared != null) std.fmt.bufPrint(&db, "{d}/{d}", .{ s.matched.?, s.compared.? }) catch "-" else "-";
        const sp = if (s.speedup) |x| std.fmt.bufPrint(&sb, "{d:.1}x", .{x}) catch "-" else "-";
        const color = if (std.mem.eql(u8, s.state, "passing")) c.s(.green) else if (std.mem.eql(u8, s.state, "failing")) c.s(.red) else c.s(.yellow);
        c.print("{s: <24} {s: <11} {d: >6}  {s}{s: <11}{s} {s: <12} {s}\n", .{ s.dir, s.language, s.cases, color, s.state, c.s(.reset), d, sp });
    }
    c.print("\n{d}/{d} unit(s) passing\n", .{ passing, list.items.len });
    return 0;
}
