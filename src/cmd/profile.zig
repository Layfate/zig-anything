//! `profile`: run a script under its runtime's profiler and rank the
//! functions in your own code by time, marking which ones can become port
//! units, so you port what actually matters first.
//!
//!   JavaScript / TypeScript   node --cpu-prof  (sampling, V8's own profiler)
//!   Python                    cProfile         (deterministic)

const std = @import("std");
const json = std.json;
const cli = @import("../cli.zig");
const config = @import("../config.zig");
const lang = @import("../lang.zig");
const adapter = @import("../adapter.zig");
const proc = @import("../proc.zig");
const scan = @import("../scan.zig");
const Io = std.Io;

const py_helper = @embedFile("../assets/profile.py");

pub const flags = [_]cli.Flag{
    .{ .name = "top", .value = "N", .help = "functions to show (default 15)" },
    .{ .name = "all", .help = "include functions outside the current directory (libraries, runtime)" },
    .{ .name = "json", .help = "machine-readable output" },
};

const Row = struct {
    function: []const u8,
    file: []const u8,
    line: u32,
    self_ns: f64,
    total_ns: f64,
    /// Python only (cProfile counts calls; V8 samples).
    calls: ?u64 = null,
    portable: bool = false,
};

fn lessByTotal(_: void, a: Row, b: Row) bool {
    if (a.total_ns != b.total_ns) return a.total_ns > b.total_ns;
    return a.self_ns > b.self_ns;
}

/// Converts a V8 `file://` URL to a filesystem path.
pub fn urlToPath(a: std.mem.Allocator, url: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, url, "file://")) return url;
    var rest = url["file://".len..];
    // file:///C:/x -> C:/x on Windows; file:///home/x -> /home/x elsewhere.
    if (rest.len >= 4 and rest[0] == '/' and std.ascii.isAlphabetic(rest[1]) and rest[2] == ':') rest = rest[1..];
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |b| {
                try out.append(a, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(a, rest[i]);
    }
    return out.items;
}

fn num(v: ?json.Value) f64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

/// Aggregates a V8 .cpuprofile into per-function self and inclusive time.
/// Inclusive time counts each sample once per function on its stack, so
/// recursion is not double counted.
pub fn parseCpuProfile(a: std.mem.Allocator, text: []const u8) !struct { rows: []Row, total_ns: f64 } {
    const root = try json.parseFromSliceLeaky(json.Value, a, text, .{});
    if (root != .object) return error.BadProfile;
    const nodes = (root.object.get("nodes") orelse return error.BadProfile).array.items;
    const samples = (root.object.get("samples") orelse return error.BadProfile).array.items;
    const deltas = (root.object.get("timeDeltas") orelse return error.BadProfile).array.items;

    // node id -> index, parent index, function key index
    var index: std.AutoHashMapUnmanaged(i64, usize) = .empty;
    for (nodes, 0..) |n, i| try index.put(a, n.object.get("id").?.integer, i);
    const parent = try a.alloc(?usize, nodes.len);
    @memset(parent, null);
    var keys: std.StringArrayHashMapUnmanaged(Row) = .empty;
    const key_of = try a.alloc(usize, nodes.len);
    for (nodes, 0..) |n, i| {
        if (n.object.get("children")) |ch| for (ch.array.items) |cid| {
            if (index.get(cid.integer)) |ci| parent[ci] = i;
        };
        const cf = n.object.get("callFrame").?.object;
        const name_raw = cf.get("functionName").?.string;
        const url = cf.get("url").?.string;
        const line: u32 = @intCast(@max(0, @as(i64, @intFromFloat(num(cf.get("lineNumber"))))) + 1);
        const name = if (name_raw.len == 0) "(anonymous)" else name_raw;
        const key = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{d}", .{ name, url, line });
        const gop = try keys.getOrPut(a, key);
        if (!gop.found_existing) gop.value_ptr.* = .{ .function = name, .file = try urlToPath(a, url), .line = line, .self_ns = 0, .total_ns = 0 };
        key_of[i] = gop.index;
    }
    const seen = try a.alloc(u32, keys.count());
    @memset(seen, 0);
    var total: f64 = 0;
    for (samples, 0..) |sid, s| {
        // Weight a sample by the time until the next one (µs -> ns).
        const w = if (s + 1 < deltas.len) num(deltas[s + 1]) * 1000 else 0;
        total += w;
        const leaf = index.get(sid.integer) orelse continue;
        keys.values()[key_of[leaf]].self_ns += w;
        var cur: ?usize = leaf;
        const stamp: u32 = @intCast(s + 1);
        while (cur) |ni| : (cur = parent[ni]) {
            const k = key_of[ni];
            if (seen[k] == stamp) continue;
            seen[k] = stamp;
            keys.values()[k].total_ns += w;
        }
    }
    return .{ .rows = keys.values(), .total_ns = total };
}

fn isInternal(r: Row) bool {
    return r.file.len == 0 or std.mem.startsWith(u8, r.file, "node:") or r.function[0] == '(' and r.file.len == 0;
}

fn underDir(file: []const u8, dir: []const u8) bool {
    if (file.len <= dir.len) return false;
    for (file[0..dir.len], dir) |x, y| {
        const nx = if (x == '\\') '/' else std.ascii.toLower(x);
        const ny = if (y == '\\') '/' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    const sep = file[dir.len];
    if (sep != '/' and sep != '\\') return false;
    return std.mem.indexOf(u8, file, "node_modules") == null and std.mem.indexOf(u8, file, "site-packages") == null;
}

/// Marks rows that are top-level functions the scanner can turn into units.
fn markPortable(c: *cli.Ctx, rows: []Row) void {
    var cache: std.StringHashMapUnmanaged([]const lang.Function) = .empty;
    for (rows) |*r| {
        const language = lang.Language.fromPath(r.file) orelse continue;
        const gop = cache.getOrPut(c.arena, r.file) catch continue;
        if (!gop.found_existing) {
            const text = Io.Dir.cwd().readFileAlloc(c.io, r.file, c.arena, .limited(2 << 20)) catch "";
            gop.value_ptr.* = scan.scanSource(c.arena, language, text) catch &.{};
        }
        for (gop.value_ptr.*) |f| {
            if (std.mem.eql(u8, f.name, r.function) and (f.exported or !adapter.forLanguage(language).requires_export)) {
                r.portable = true;
                break;
            }
        }
    }
}

pub fn run(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const script_arg = args.pos(0) orelse return c.fail("usage: zig-anything profile <script> [-- args...]", .{});
    const script = c.abs(script_arg) catch return c.fail("out of memory", .{});
    const language = lang.Language.fromPath(script) orelse
        return c.fail("cannot profile '{s}': supported scripts are .js .mjs .cjs .ts .mts .cts .py", .{script_arg});
    Io.Dir.cwd().access(c.io, script, .{}) catch return c.fail("{s} does not exist", .{script_arg});
    const top = try cli.parseInt(usize, c, args, "top", 15);
    const cfg = (try config.load(c, c.cwd)).config;
    const work = std.fs.path.join(c.arena, &.{ c.cwd, ".za-profile" }) catch return c.fail("out of memory", .{});
    Io.Dir.cwd().createDirPath(c.io, work) catch |err| return c.fail("cannot create {s}: {s}", .{ work, @errorName(err) });
    defer Io.Dir.cwd().deleteTree(c.io, work) catch {};
    const script_args = args.positional[1..];

    var rows: []Row = &.{};
    var total_ns: f64 = 0;
    var wall_ns: u64 = 0;
    if (adapter.forLanguage(language).bridge == .node) {
        const extra = std.mem.concat(c.arena, []const u8, &.{
            &.{ "--cpu-prof", "--cpu-prof-dir", work, "--cpu-prof-name", "profile.cpuprofile", script },
            script_args,
        }) catch return c.fail("out of memory", .{});
        if (!args.has("json")) c.print("profiling {s} with node --cpu-prof...\n", .{c.rel(script)});
        c.out.flush() catch {};
        const r = try proc.run(c, proc.command(c, cfg.node, extra), .{ .timeout_s = cfg.timeout, .missing_hint = "install Node.js or set \"node\" in zig-anything.json" });
        wall_ns = r.ns;
        if (!r.ok) c.warn("the script exited with code {?d}; profiling what ran", .{r.exit_code});
        const prof_path = std.fs.path.join(c.arena, &.{ work, "profile.cpuprofile" }) catch return c.fail("out of memory", .{});
        const text = Io.Dir.cwd().readFileAlloc(c.io, prof_path, c.arena, .unlimited) catch
            return c.fail("node wrote no profile (does this Node support --cpu-prof?)", .{});
        const parsed = parseCpuProfile(c.arena, text) catch return c.fail("could not read the CPU profile", .{});
        rows = parsed.rows;
        total_ns = parsed.total_ns;
    } else {
        const helper = std.fs.path.join(c.arena, &.{ work, "za_profiler.py" }) catch return c.fail("out of memory", .{});
        const out = std.fs.path.join(c.arena, &.{ work, "profile.json" }) catch return c.fail("out of memory", .{});
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = helper, .data = py_helper }) catch |err| return c.fail("cannot write {s}: {s}", .{ helper, @errorName(err) });
        const extra = std.mem.concat(c.arena, []const u8, &.{ &.{ helper, out, script }, script_args }) catch return c.fail("out of memory", .{});
        if (!args.has("json")) c.print("profiling {s} with cProfile...\n", .{c.rel(script)});
        c.out.flush() catch {};
        const r = try proc.run(c, proc.command(c, cfg.python, extra), .{ .timeout_s = cfg.timeout, .missing_hint = "install Python 3 or set \"python\" in zig-anything.json" });
        wall_ns = r.ns;
        const text = Io.Dir.cwd().readFileAlloc(c.io, out, c.arena, .unlimited) catch {
            c.err.writeAll(r.stderr) catch {};
            return c.fail("the profiler produced no data", .{});
        };
        if (!r.ok) c.warn("the script exited with code {?d}; profiling what ran", .{r.exit_code});
        const v = json.parseFromSliceLeaky(json.Value, c.arena, text, .{}) catch return c.fail("could not read the profile", .{});
        total_ns = num(v.object.get("total_s")) * 1e9;
        var list: std.ArrayList(Row) = .empty;
        for (v.object.get("functions").?.array.items) |f| {
            const o = f.object;
            const name = o.get("function").?.string;
            list.append(c.arena, .{
                .function = name,
                .file = o.get("file").?.string,
                .line = @intCast(@max(0, @as(i64, @intFromFloat(num(o.get("line")))))),
                .self_ns = num(o.get("self_s")) * 1e9,
                .total_ns = num(o.get("total_s")) * 1e9,
                .calls = @intFromFloat(@max(0, num(o.get("calls")))),
            }) catch {};
        }
        rows = list.items;
    }

    // Keep the user's own code unless --all.
    var kept: std.ArrayList(Row) = .empty;
    for (rows) |r| {
        if (r.total_ns <= 0) continue;
        if (!args.has("all") and (isInternal(r) or !underDir(r.file, c.cwd) or std.mem.indexOf(u8, r.file, ".za-profile") != null)) continue;
        if (std.mem.eql(u8, r.function, "<module>") or std.mem.eql(u8, r.function, "(anonymous)") or std.mem.eql(u8, r.function, "(root)")) continue;
        kept.append(c.arena, r) catch {};
    }
    std.mem.sort(Row, kept.items, {}, lessByTotal);
    markPortable(c, kept.items);
    const shown = kept.items[0..@min(top, kept.items.len)];

    if (args.has("json")) {
        std.json.Stringify.value(.{ .total_ns = total_ns, .functions = shown }, .{}, c.out) catch {};
        c.print("\n", .{});
        return 0;
    }
    var b: [32]u8 = undefined;
    c.print("{s}profile {s}{s}  ({s}, {s} profiled)\n", .{ c.s(.bold), c.rel(script), c.s(.reset), adapter.forLanguage(language).runtime, proc.fmtNs(&b, total_ns) });
    if (shown.len == 0) {
        c.print("no functions from files under {s} took measurable time\n", .{c.rel(c.cwd)});
        c.hint("pass --all to include libraries and runtime internals", .{});
        return 0;
    }
    c.print("{s}{s: >6}  {s: >6}  {s: >9}  {s: <28} {s}{s}\n", .{ c.s(.dim), "TOTAL", "SELF", "CALLS", "FUNCTION", "LOCATION", c.s(.reset) });
    var first_portable: ?Row = null;
    for (shown) |r| {
        const tp = if (total_ns > 0) r.total_ns / total_ns * 100 else 0;
        const sp = if (total_ns > 0) r.self_ns / total_ns * 100 else 0;
        var cb: [24]u8 = undefined;
        const calls = if (r.calls) |n| std.fmt.bufPrint(&cb, "{d}", .{n}) catch "-" else "-";
        const loc = std.fmt.allocPrint(c.arena, "{s}:{d}", .{ c.rel(r.file), r.line }) catch r.file;
        c.print("{d: >5.1}%  {d: >5.1}%  {s: >9}  {s: <28} {s}", .{ tp, sp, calls, r.function, loc });
        if (r.portable) {
            c.print("  {s}portable{s}", .{ c.s(.green), c.s(.reset) });
            if (first_portable == null) first_portable = r;
        }
        c.print("\n", .{});
    }
    if (first_portable) |r| {
        c.print("\nhottest portable function: {s}{s}{s}\nnext: {s}zig-anything init {s} {s}{s}\n", .{ c.s(.bold), r.function, c.s(.reset), c.s(.cyan), c.rel(r.file), r.function, c.s(.reset) });
    }
    return 0;
}

test "file URLs become paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("C:/All Projects/x.mjs", try urlToPath(a, "file:///C:/All%20Projects/x.mjs"));
    try std.testing.expectEqualStrings("/home/u/x.js", try urlToPath(a, "file:///home/u/x.js"));
    try std.testing.expectEqualStrings("node:internal/x", try urlToPath(a, "node:internal/x"));
}

test "cpuprofile aggregation counts recursion once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // root -> f -> f (recursive) ; samples: f(inner), f(inner), root
    const text =
        \\{"nodes":[
        \\ {"id":1,"callFrame":{"functionName":"(root)","url":"","lineNumber":-1},"children":[2]},
        \\ {"id":2,"callFrame":{"functionName":"f","url":"file:///a.js","lineNumber":0},"children":[3]},
        \\ {"id":3,"callFrame":{"functionName":"f","url":"file:///a.js","lineNumber":0},"children":[]}],
        \\ "samples":[3,3,1],"timeDeltas":[0,10,10,10]}
    ;
    const p = try parseCpuProfile(arena.allocator(), text);
    var f_row: ?Row = null;
    for (p.rows) |r| if (std.mem.eql(u8, r.function, "f")) {
        f_row = r;
    };
    try std.testing.expectEqual(@as(f64, 20_000), f_row.?.total_ns);
    try std.testing.expectEqual(@as(f64, 20_000), f_row.?.self_ns);
}

test "underDir ignores case and separators but not dependencies" {
    try std.testing.expect(underDir("C:/Proj/src/a.js", "c:\\proj"));
    try std.testing.expect(!underDir("C:/Proj2/a.js", "C:/Proj"));
    try std.testing.expect(!underDir("C:/Proj/node_modules/x/a.js", "C:/Proj"));
}
