//! `plan`: an ordered migration plan for a whole project.
//!
//! Every top-level function found by `scan` becomes a step. Steps are
//! ordered so a function comes after the project functions it calls (leaf
//! first: each port can then be finished and bridged on its own), and within
//! one wave by measured time (from `profile --json`, when given), then by how
//! ready the function is to port, then by size. Each step says what blocks
//! or complicates it (async, I/O, randomness, shared state) and the next
//! command to run, and units that already exist show their state.

const std = @import("std");
const json = std.json;
const cli = @import("../cli.zig");
const config = @import("../config.zig");
const lang = @import("../lang.zig");
const unit_mod = @import("../unit.zig");
const scan_cmd = @import("scan.zig");
const gate = @import("gate.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const flags = [_]cli.Flag{
    .{ .name = "all", .help = "include functions that are not exported" },
    .{ .name = "hot", .value = "FILE", .help = "weight steps by time, from `zig-anything profile <script> --json > FILE`" },
    .{ .name = "limit", .value = "N", .help = "steps to show (default 25; 0 = all)" },
    .{ .name = "json", .help = "machine-readable plan with the commands for every step" },
};

/// How ready a function is to port.
pub const Readiness = enum {
    /// Typed parameters, no side-effect signals.
    ready,
    /// Portable, but something needs a look (untyped values, I/O, ...).
    review,
    /// Not a function unit as written (async, variadic): wrap it first.
    blocked,
};

pub const Source = struct {
    path: []const u8,
    language: lang.Language,
    text: []const u8,
    functions: []const lang.Function,
};

pub const Node = struct {
    function: lang.Function,
    file: usize,
    /// Lines of the body (an estimate: up to the next top-level function).
    lines: u32,
    /// Indexes of project functions this one calls.
    calls: []const usize,
    called_by: []const usize = &.{},
    /// 0 for functions that call no other project function.
    wave: u32 = 0,
    readiness: Readiness = .ready,
    notes: []const []const u8 = &.{},
};

// ---------------------------------------------------------------- analysis

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}

/// Names called in `body` as plain function calls (`name(`), not methods
/// (`x.name(`) or definitions (`function name(`, `def name(`).
fn calledNames(a: Allocator, body: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        if (!isIdentChar(body[i]) or (i > 0 and isIdentChar(body[i - 1]))) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < body.len and isIdentChar(body[end])) end += 1;
        const name = body[i..end];
        var k = end;
        while (k < body.len and (body[k] == ' ' or body[k] == '\t')) k += 1;
        const is_call = k < body.len and body[k] == '(' and !std.ascii.isDigit(name[0]);
        if (is_call) {
            var p = i;
            while (p > 0 and (body[p - 1] == ' ' or body[p - 1] == '\t')) p -= 1;
            const method = p > 0 and body[p - 1] == '.';
            const before = std.mem.trimEnd(u8, body[0..p], " \t");
            const definition = std.mem.endsWith(u8, before, "function") or std.mem.endsWith(u8, before, "def") or
                std.mem.endsWith(u8, before, "new") or std.mem.endsWith(u8, before, "class");
            if (!method and !definition) try out.append(a, name);
        }
        i = end;
    }
    return out.items;
}

const Signal = struct { needle: []const u8, note: []const u8 };

const js_signals = [_]Signal{
    .{ .needle = "await ", .note = "awaits (async)" },
    .{ .needle = "fetch(", .note = "network I/O" },
    .{ .needle = "require(", .note = "loads modules at run time" },
    .{ .needle = "fs.", .note = "file I/O" },
    .{ .needle = "readFile", .note = "file I/O" },
    .{ .needle = "writeFile", .note = "file I/O" },
    .{ .needle = "appendFile", .note = "file I/O" },
    .{ .needle = "process.", .note = "reads process state" },
    .{ .needle = "console.", .note = "prints (record with --effects)" },
    .{ .needle = "Date.now", .note = "reads the clock" },
    .{ .needle = "new Date(", .note = "reads the clock" },
    .{ .needle = "Math.random", .note = "random" },
    .{ .needle = "this.", .note = "uses `this`" },
    .{ .needle = "document.", .note = "uses the DOM" },
    .{ .needle = "window.", .note = "uses the DOM" },
    .{ .needle = "setTimeout", .note = "timers" },
};

const py_signals = [_]Signal{
    .{ .needle = "await ", .note = "awaits (async)" },
    .{ .needle = "open(", .note = "file I/O" },
    .{ .needle = "print(", .note = "prints (record with --effects)" },
    .{ .needle = "random.", .note = "random" },
    .{ .needle = "time.", .note = "reads the clock" },
    .{ .needle = "datetime.", .note = "reads the clock" },
    .{ .needle = "os.", .note = "uses the OS" },
    .{ .needle = "sys.", .note = "reads process state" },
    .{ .needle = "requests.", .note = "network I/O" },
    .{ .needle = "subprocess", .note = "runs programs" },
    .{ .needle = "global ", .note = "writes globals" },
    .{ .needle = "self.", .note = "uses `self`" },
    .{ .needle = "input(", .note = "reads stdin" },
};

fn addNote(a: Allocator, notes: *std.ArrayList([]const u8), note: []const u8) !void {
    for (notes.items) |n| if (std.mem.eql(u8, n, note)) return;
    try notes.append(a, note);
}

/// The text of each function's body: from its line to the next top-level
/// function's line (or the end of the file).
fn bodies(a: Allocator, src: Source) ![]const []const u8 {
    var starts: std.ArrayList(usize) = .empty; // byte offset of every line
    try starts.append(a, 0);
    for (src.text, 0..) |ch, i| if (ch == '\n') try starts.append(a, i + 1);
    const lineStart = struct {
        fn f(st: []const usize, line: u32, len: usize) usize {
            if (line == 0) return 0;
            return if (line - 1 < st.len) st[line - 1] else len;
        }
    }.f;
    var lines: std.ArrayList(u32) = .empty;
    for (src.functions) |f| try lines.append(a, f.line);
    std.mem.sort(u32, lines.items, {}, std.sort.asc(u32));
    const out = try a.alloc([]const u8, src.functions.len);
    for (src.functions, out) |f, *body| {
        var next_line: ?u32 = null;
        for (lines.items) |l| if (l > f.line) {
            next_line = l;
            break;
        };
        const from = lineStart(starts.items, f.line, src.text.len);
        const to = if (next_line) |l| lineStart(starts.items, l, src.text.len) else src.text.len;
        body.* = src.text[from..@max(from, to)];
    }
    return out;
}

/// Builds the call graph, waves and readiness of every function.
pub fn analyze(a: Allocator, sources: []const Source, include_unexported: bool) ![]Node {
    var nodes: std.ArrayList(Node) = .empty;
    var body_of: std.ArrayList([]const u8) = .empty;
    for (sources, 0..) |src, fi| {
        const bs = try bodies(a, src);
        for (src.functions, bs) |f, b| {
            if (!f.exported and !include_unexported) continue;
            try nodes.append(a, .{ .function = f, .file = fi, .lines = @intCast(@max(1, std.mem.count(u8, std.mem.trimEnd(u8, b, " \t\r\n"), "\n") + 1)), .calls = &.{} });
            try body_of.append(a, b);
        }
    }
    const n = nodes.items.len;

    // Calls: same-file names first, else a name unique among the files in
    // the same language that the caller's file mentions (by module name, as
    // an import would), so `range(` in Python never links to a TS `range`.
    for (nodes.items, body_of.items, 0..) |*node, body, i| {
        const caller_src = sources[node.file];
        const names = try calledNames(a, body);
        var calls: std.ArrayList(usize) = .empty;
        for (names) |name| {
            if (std.mem.eql(u8, name, node.function.name)) continue; // recursion
            var same: ?usize = null;
            var other: ?usize = null;
            var others: usize = 0;
            for (nodes.items, 0..) |cand, j| {
                if (j == i or !std.mem.eql(u8, cand.function.name, name)) continue;
                if (cand.file == node.file) same = j else if (canImport(caller_src, sources[cand.file])) {
                    other = j;
                    others += 1;
                }
            }
            const target = same orelse (if (others == 1) other else null);
            if (target) |t| if (std.mem.indexOfScalar(usize, calls.items, t) == null) try calls.append(a, t);
        }
        node.calls = calls.items;
    }
    for (0..n) |i| {
        var by: std.ArrayList(usize) = .empty;
        for (nodes.items, 0..) |other, j| {
            if (std.mem.indexOfScalar(usize, other.calls, i) != null) try by.append(a, j);
        }
        nodes.items[i].called_by = by.items;
    }

    // Waves: longest path to a leaf. Calls inside a cycle are ignored, so
    // mutually recursive functions land in the same wave.
    const state = try a.alloc(u8, n); // 0 new, 1 visiting, 2 done
    @memset(state, 0);
    for (0..n) |i| _ = waveOf(nodes.items, state, i);

    // Readiness and notes.
    for (nodes.items, body_of.items) |*node, body| {
        var notes: std.ArrayList([]const u8) = .empty;
        const f = node.function;
        var readiness: Readiness = .ready;
        if (f.is_async) {
            readiness = .blocked;
            try addNote(a, &notes, "async: wrap it in a synchronous function to port");
        }
        if (f.variadic) {
            readiness = .blocked;
            try addNote(a, &notes, "variadic: rest parameters are never recorded");
        }
        var untyped = false;
        for (f.params) |p| untyped = untyped or p.type == .any;
        if (untyped) try addNote(a, &notes, "untyped parameter (std.json.Value)");
        const signals: []const Signal = if (sources[node.file].language == .python) &py_signals else &js_signals;
        // Skip the signature line: parameter names are not uses.
        const nl = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
        const inner = body[nl..];
        var signaled = false;
        for (signals) |s| if (std.mem.indexOf(u8, inner, s.needle) != null) {
            try addNote(a, &notes, s.note);
            signaled = true;
        };
        if (readiness == .ready and (untyped or signaled)) readiness = .review;
        node.readiness = readiness;
        node.notes = notes.items;
    }
    // A caller of a blocked function needs review too.
    for (nodes.items) |*node| {
        for (node.calls) |callee| if (nodes.items[callee].readiness == .blocked) {
            var notes: std.ArrayList([]const u8) = .fromOwnedSlice(@constCast(node.notes));
            try addNote(a, &notes, try std.fmt.allocPrint(a, "calls {s}, which is blocked", .{nodes.items[callee].function.name}));
            node.notes = notes.items;
            if (node.readiness == .ready) node.readiness = .review;
        };
    }
    return nodes.items;
}

fn canImport(from: Source, to: Source) bool {
    if ((from.language == .python) != (to.language == .python)) return false;
    const base = std.fs.path.basename(to.path);
    const stem = base[0 .. std.mem.indexOfScalar(u8, base, '.') orelse base.len];
    return stem.len > 0 and std.mem.indexOf(u8, from.text, stem) != null;
}

fn waveOf(nodes: []Node, state: []u8, i: usize) u32 {
    if (state[i] == 2) return nodes[i].wave;
    if (state[i] == 1) return 0; // a cycle: ignore this edge
    state[i] = 1;
    var w: u32 = 0;
    for (nodes[i].calls) |callee| {
        if (state[callee] == 1) continue;
        w = @max(w, waveOf(nodes, state, callee) + 1);
    }
    nodes[i].wave = w;
    state[i] = 2;
    return w;
}

// ---------------------------------------------------------------- the command

const Hot = struct { function: []const u8, file: []const u8, total_ns: f64 };

/// Reads the output of `profile --json`.
fn loadHot(c: *cli.Ctx, p: []const u8) cli.Reported!struct { rows: []const Hot, total_ns: f64 } {
    const text = Io.Dir.cwd().readFileAlloc(c.io, p, c.arena, .limited(16 << 20)) catch |err|
        return c.fail("cannot read {s}: {s}", .{ p, @errorName(err) });
    const Parsed = struct { total_ns: f64 = 0, functions: []const Hot = &.{} };
    const v = json.parseFromSliceLeaky(Parsed, c.arena, text, .{ .ignore_unknown_fields = true }) catch {
        c.hint("make it with `zig-anything profile <script> --json > {s}`", .{p});
        return c.fail("{s} is not the output of `profile --json`", .{p});
    };
    return .{ .rows = v.functions, .total_ns = v.total_ns };
}

fn hotFor(rows: []const Hot, total_ns: f64, f: []const u8, file: []const u8) ?f64 {
    if (total_ns <= 0) return null;
    for (rows) |r| {
        if (!std.mem.eql(u8, r.function, f)) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(r.file), std.fs.path.basename(file))) continue;
        return r.total_ns / total_ns * 100;
    }
    return null;
}

const Existing = struct { source_abs: []const u8, function: []const u8, status: gate.UnitStatus };

/// Every unit under the configured units directory.
fn existingUnits(c: *cli.Ctx, root: []const u8) []const Existing {
    var list: std.ArrayList(Existing) = .empty;
    var dir = Io.Dir.cwd().openDir(c.io, root, .{ .iterate = true }) catch return &.{};
    defer dir.close(c.io);
    var it = dir.iterate();
    while (it.next(c.io) catch null) |e| {
        if (e.kind != .directory) continue;
        const udir = std.fs.path.join(c.arena, &.{ root, e.name }) catch continue;
        const text = Io.Dir.cwd().readFileAlloc(c.io, std.fs.path.join(c.arena, &.{ udir, unit_mod.manifest_name }) catch continue, c.arena, .limited(1 << 20)) catch continue;
        const m = json.parseFromSliceLeaky(unit_mod.Manifest, c.arena, text, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch continue;
        if (m.kind == .cli) continue;
        const st = gate.inspect(c, udir) orelse continue;
        const src = std.fs.path.resolveAlloc(c.arena, &.{ udir, m.source }) catch continue;
        list.append(c.arena, .{ .source_abs = src, .function = m.function, .status = st }) catch {};
    }
    return list.items;
}

const Step = struct {
    node: *const Node,
    hot: ?f64,
    unit: ?*const Existing,

    fn done(s: Step) bool {
        return if (s.unit) |u| std.mem.eql(u8, u.status.state, "passing") else false;
    }
};

fn lessStep(_: void, x: Step, y: Step) bool {
    if (x.done() != y.done()) return y.done(); // finished work last
    if (x.node.wave != y.node.wave) return x.node.wave < y.node.wave;
    const hx = x.hot orelse -1;
    const hy = y.hot orelse -1;
    if (hx != hy) return hx > hy;
    if (x.node.readiness != y.node.readiness) return @backingInt(x.node.readiness) < @backingInt(y.node.readiness);
    if (x.node.lines != y.node.lines) return x.node.lines < y.node.lines;
    return std.mem.lessThan(u8, x.node.function.name, y.node.function.name);
}

/// The command to run next for a step.
fn nextCommand(a: Allocator, s: Step, file_rel: []const u8) []const u8 {
    if (s.node.readiness == .blocked) return "wrap it in a synchronous function, then scan again";
    if (s.unit) |u| {
        const st = u.status.state;
        const cmd: []const u8 = if (std.mem.eql(u8, st, "passing")) "bridge" else if (std.mem.eql(u8, st, "unrecorded")) "record" else if (std.mem.eql(u8, st, "stub")) "record" else "diff";
        if (std.mem.eql(u8, st, "stub")) return std.fmt.allocPrint(a, "write {s}/src/port.zig", .{u.status.dir}) catch "";
        return std.fmt.allocPrint(a, "zig-anything {s} {s}", .{ cmd, u.status.dir }) catch "";
    }
    return std.fmt.allocPrint(a, "zig-anything init {s} {s}", .{ file_rel, s.node.function.name }) catch "";
}

pub fn run(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const target = c.abs(args.pos(0) orelse ".") catch return c.fail("out of memory", .{});
    var files: std.ArrayList(scan_cmd.FileResult) = .empty;
    const st = Io.Dir.cwd().statFile(c.io, target, .{}) catch return c.fail("cannot open '{s}'", .{args.pos(0) orelse "."});
    if (st.kind == .directory) {
        scan_cmd.collect(c, target, &files) catch |err| return c.fail("cannot scan {s}: {s}", .{ c.rel(target), @errorName(err) });
    } else if (scan_cmd.scanFile(c, target)) |r| {
        files.append(c.arena, r) catch return c.fail("out of memory", .{});
    } else return c.fail("unsupported file type '{s}' (supported: .js .mjs .cjs .jsx .ts .mts .cts .tsx .py)", .{std.fs.path.extension(target)});
    std.mem.sort(scan_cmd.FileResult, files.items, {}, struct {
        fn lt(_: void, x: scan_cmd.FileResult, y: scan_cmd.FileResult) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);

    var sources: std.ArrayList(Source) = .empty;
    for (files.items) |f| {
        const text = Io.Dir.cwd().readFileAlloc(c.io, f.path, c.arena, .limited(scan_cmd.max_source_bytes)) catch continue;
        sources.append(c.arena, .{ .path = f.path, .language = f.language, .text = text, .functions = f.functions }) catch return c.fail("out of memory", .{});
    }
    const nodes = analyze(c.arena, sources.items, args.has("all")) catch return c.fail("out of memory", .{});
    if (nodes.len == 0) {
        c.print("no portable functions found under {s}\n", .{c.rel(target)});
        if (!args.has("all")) c.hint("only exported functions are listed; `--all` includes the rest", .{});
        return 0;
    }

    const hot = if (args.get("hot")) |p| try loadHot(c, p) else null;
    const cfg = try config.load(c, if (st.kind == .directory) target else (std.fs.path.dirname(target) orelse c.cwd));
    const units_root = std.fs.path.join(c.arena, &.{ cfg.root, cfg.config.units_dir }) catch return c.fail("out of memory", .{});
    const existing = existingUnits(c, units_root);

    const steps = c.arena.alloc(Step, nodes.len) catch return c.fail("out of memory", .{});
    for (nodes, steps) |*node, *s| {
        const path = sources.items[node.file].path;
        s.* = .{
            .node = node,
            .hot = if (hot) |h| hotFor(h.rows, h.total_ns, node.function.name, path) else null,
            .unit = null,
        };
        for (existing) |*e| {
            if (std.mem.eql(u8, e.function, node.function.name) and std.mem.eql(u8, e.source_abs, path)) s.unit = e;
        }
    }
    std.mem.sort(Step, steps, {}, lessStep);
    const limit = try cli.parseInt(usize, c, args, "limit", 25);
    const shown = if (limit == 0) steps else steps[0..@min(limit, steps.len)];

    if (args.has("json")) {
        try writeJson(c, target, sources.items, nodes, steps);
        return 0;
    }

    var n_done: usize = 0;
    var n_ready: usize = 0;
    var n_blocked: usize = 0;
    for (steps) |s| {
        if (s.done()) n_done += 1 else switch (s.node.readiness) {
            .ready => n_ready += 1,
            .blocked => n_blocked += 1,
            .review => {},
        }
    }
    c.print("{s}migration plan{s} for {s}: {d} function(s) in {d} file(s); {d} done, {d} ready, {d} to review, {d} blocked\n\n", .{
        c.s(.bold), c.s(.reset), c.rel(target), nodes.len, sources.items.len, n_done, n_ready, nodes.len - n_done - n_ready - n_blocked, n_blocked,
    });
    c.print("{s}{s: >3}  {s: <24} {s: <28} {s: >4} {s: >6} {s: >5}  {s: <8} {s}{s}\n", .{ c.s(.bold), "#", "FUNCTION", "WHERE", "WAVE", "TIME", "LINES", "STATE", "NOTES", c.s(.reset) });
    for (shown, 0..) |s, i| {
        const node = s.node;
        var wb: [64]u8 = undefined;
        const where = std.fmt.bufPrint(&wb, "{s}:{d}", .{ c.rel(sources.items[node.file].path), node.function.line }) catch "?";
        var hb: [16]u8 = undefined;
        const time = if (s.hot) |h| std.fmt.bufPrint(&hb, "{d:.1}%", .{h}) catch "-" else "-";
        const state: []const u8 = if (s.unit) |u| u.status.state else @tagName(node.readiness);
        const color = if (s.done()) c.s(.green) else switch (node.readiness) {
            .ready => c.s(.reset),
            .review => c.s(.yellow),
            .blocked => c.s(.red),
        };
        c.print("{d: >3}  {s: <24} {s: <28} {d: >4} {s: >6} {d: >5}  {s}{s: <8}{s} ", .{ i + 1, node.function.name, where, node.wave, time, node.lines, color, state, c.s(.reset) });
        for (node.notes, 0..) |note, k| c.print("{s}{s}", .{ if (k == 0) "" else "; ", note });
        if (node.calls.len > 0) {
            c.print("{s}calls ", .{if (node.notes.len > 0) "; " else ""});
            for (node.calls, 0..) |callee, k| c.print("{s}{s}", .{ if (k == 0) "" else ", ", nodes[callee].function.name });
        }
        c.print("\n", .{});
    }
    if (shown.len < steps.len) c.print("  ... and {d} more (--limit 0 shows all)\n", .{steps.len - shown.len});
    for (steps) |s| {
        if (s.done() or s.node.readiness == .blocked) continue;
        c.print("\nnext: {s}\n", .{nextCommand(c.arena, s, c.rel(sources.items[s.node.file].path))});
        break;
    }
    if (hot == null) c.hint("add timing with `zig-anything profile <script> --json > hot.json` and `--hot hot.json`", .{});
    return 0;
}

fn writeJson(c: *cli.Ctx, target: []const u8, sources: []const Source, nodes: []const Node, steps: []const Step) !void {
    const w = c.out;
    try w.writeAll("{\"root\":");
    try json.Stringify.value(c.rel(target), .{}, w);
    try w.print(",\"functions\":{d},\"files\":{d},\"steps\":[", .{ nodes.len, sources.len });
    for (steps, 0..) |s, i| {
        if (i != 0) try w.writeByte(',');
        const node = s.node;
        const file = c.rel(sources[node.file].path);
        var calls: std.ArrayList([]const u8) = .empty;
        for (node.calls) |k| try calls.append(c.arena, nodes[k].function.name);
        var callers: std.ArrayList([]const u8) = .empty;
        for (node.called_by) |k| try callers.append(c.arena, nodes[k].function.name);
        try json.Stringify.value(.{
            .order = i + 1,
            .function = node.function.name,
            .file = file,
            .line = node.function.line,
            .wave = node.wave,
            .lines = node.lines,
            .readiness = @tagName(node.readiness),
            .hot_percent = s.hot,
            .unit = if (s.unit) |u| u.status.dir else null,
            .state = if (s.unit) |u| u.status.state else null,
            .calls = calls.items,
            .called_by = callers.items,
            .notes = node.notes,
            .next = nextCommand(c.arena, s, file),
        }, .{}, w);
    }
    try w.writeAll("]}\n");
}

// ---------------------------------------------------------------- tests

const scan = @import("../scan.zig");

fn testSource(a: Allocator, path: []const u8, language: lang.Language, text: []const u8) !Source {
    return .{ .path = path, .language = language, .text = text, .functions = try scan.scanSource(a, language, text) };
}

fn find(nodes: []const Node, name: []const u8) *const Node {
    for (nodes) |*n| if (std.mem.eql(u8, n.function.name, name)) return n;
    @panic("missing node");
}

test "called names skip methods and definitions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const names = try calledNames(arena.allocator(), "function f(x) { return g(x) + s.h(1) + new K(2) + k (3); }");
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("g", names[0]);
    try std.testing.expectEqualStrings("k", names[1]);
}

test "plan orders callees first and flags side effects" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const js = try testSource(a, "a.mjs", .javascript,
        \\export function norm(s) { return clean(s).toLowerCase(); }
        \\export function clean(s) { return s.trim(); }
        \\export function score(q, t) { return norm(q) === norm(t) ? 1 : 0; }
        \\export async function load(url) { return await fetch(url); }
        \\export function report(x) { console.log(x); return load(x); }
        \\
    );
    const py = try testSource(a, "b.py", .python,
        \\def twice(n: int) -> int:
        \\    return n * 2
        \\
        \\def roll(n: int) -> int:
        \\    import random
        \\    return random.randint(0, twice(n))
        \\
    );
    const nodes = try analyze(a, &.{ js, py }, false);
    try std.testing.expectEqual(@as(u32, 0), find(nodes, "clean").wave);
    try std.testing.expectEqual(@as(u32, 1), find(nodes, "norm").wave);
    try std.testing.expectEqual(@as(u32, 2), find(nodes, "score").wave);
    try std.testing.expectEqual(Readiness.blocked, find(nodes, "load").readiness);
    const report = find(nodes, "report");
    try std.testing.expectEqual(Readiness.review, report.readiness);
    try std.testing.expectEqual(@as(usize, 1), report.calls.len);
    try std.testing.expectEqual(Readiness.ready, find(nodes, "twice").readiness);
    const roll = find(nodes, "roll");
    try std.testing.expectEqual(Readiness.review, roll.readiness);
    try std.testing.expectEqual(@as(u32, 1), roll.wave);
    try std.testing.expectEqualStrings("random", roll.notes[0]);
    try std.testing.expectEqual(@as(usize, 1), find(nodes, "clean").called_by.len);
}

test "calls across files need the same language and an import" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try testSource(a, "stats.ts", .typescript,
        \\export function range(xs: number[]): number[] { return xs; }
        \\
    );
    const js = try testSource(a, "app.mjs", .javascript,
        \\import { range } from './stats.ts';
        \\export function spread(xs) { return range(xs); }
        \\
    );
    const py = try testSource(a, "loop.py", .python,
        \\def total(n: int) -> int:
        \\    return sum(range(n))
        \\
    );
    const nodes = try analyze(a, &.{ ts, js, py }, false);
    try std.testing.expectEqual(@as(usize, 1), find(nodes, "spread").calls.len);
    try std.testing.expectEqual(@as(usize, 0), find(nodes, "total").calls.len);
}

test "mutual recursion does not loop" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const js = try testSource(a, "r.mjs", .javascript,
        \\export function isEven(n) { return n === 0 ? true : isOdd(n - 1); }
        \\export function isOdd(n) { return n === 0 ? false : isEven(n - 1); }
        \\
    );
    const nodes = try analyze(a, &.{js}, false);
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expect(find(nodes, "isEven").wave <= 1 and find(nodes, "isOdd").wave <= 1);
}
