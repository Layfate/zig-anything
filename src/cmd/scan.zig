//! `scan` lists portable functions; `init` creates a port unit for one.

const std = @import("std");
const cli = @import("../cli.zig");
const config = @import("../config.zig");
const lang = @import("../lang.zig");
const scan = @import("../scan.zig");
const unit_mod = @import("../unit.zig");
const jsonx = @import("../jsonx.zig");
const Io = std.Io;

pub const scan_flags = [_]cli.Flag{
    .{ .name = "json", .help = "machine-readable output" },
    .{ .name = "all", .help = "include functions that are not exported" },
};

pub const init_flags = [_]cli.Flag{
    .{ .name = "out", .value = "DIR", .help = "unit directory (default: <units_dir>/<function>)" },
    .{ .name = "force", .help = "regenerate manifest and harness of an existing unit (port.zig is kept)" },
};

const ignored_dirs = std.StaticStringMap(void).initComptime(.{
    .{"node_modules"},  .{".git"},     .{".hg"},        .{".svn"},        .{"__pycache__"},
    .{".venv"},         .{"venv"},     .{"env"},        .{".tox"},        .{"dist"},
    .{"build"},         .{"zig-out"},  .{".zig-cache"}, .{"zig-port"},    .{"target"},
    .{".next"},         .{"coverage"}, .{".za"},        .{".mypy_cache"}, .{".pytest_cache"},
    .{"site-packages"},
});

const max_source_bytes = 2 << 20;

const FileResult = struct {
    path: []const u8,
    language: lang.Language,
    functions: []const lang.Function,
};

fn skipFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".d.ts") or std.mem.endsWith(u8, name, ".min.js") or
        std.mem.endsWith(u8, name, ".bundle.js");
}

fn scanFile(c: *cli.Ctx, path: []const u8) ?FileResult {
    const language = lang.Language.fromPath(path) orelse return null;
    const text = Io.Dir.cwd().readFileAlloc(c.io, path, c.arena, .limited(max_source_bytes)) catch return null;
    const fns = scan.scanSource(c.arena, language, text) catch return null;
    return .{ .path = path, .language = language, .functions = fns };
}

fn collect(c: *cli.Ctx, root: []const u8, out: *std.ArrayList(FileResult)) !void {
    var dir = try Io.Dir.cwd().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walkSelectively(c.gpa);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (ignored_dirs.has(entry.basename) or entry.basename[0] == '.') continue;
                try walker.enter(c.io, entry);
            },
            .file => {
                if (skipFile(entry.basename)) continue;
                if (lang.Language.fromPath(entry.basename) == null) continue;
                const full = try std.fs.path.join(c.arena, &.{ root, entry.path });
                if (scanFile(c, full)) |r| {
                    if (r.functions.len > 0) try out.append(c.arena, r);
                }
            },
            else => {},
        }
    }
}

fn writeSignature(w: *Io.Writer, f: lang.Function) !void {
    try w.print("{s}(", .{f.name});
    for (f.params, 0..) |p, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{s}{s}: {s}", .{ p.name, if (p.optional) "?" else "", @tagName(p.type) });
    }
    if (f.variadic) try w.writeAll(if (f.params.len > 0) ", ..." else "...");
    try w.writeByte(')');
    if (f.returns) |r| try w.print(" -> {s}", .{@tagName(r)});
}

pub fn runScan(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const target = c.abs(args.pos(0) orelse ".") catch return c.fail("out of memory", .{});
    var results: std.ArrayList(FileResult) = .empty;
    const st = Io.Dir.cwd().statFile(c.io, target, .{}) catch return c.fail("cannot open '{s}'", .{args.pos(0) orelse "."});
    if (st.kind == .directory) {
        collect(c, target, &results) catch |err| return c.fail("cannot scan {s}: {s}", .{ c.rel(target), @errorName(err) });
    } else {
        if (lang.Language.fromPath(target) == null)
            return c.fail("unsupported file type '{s}' (supported: .js .mjs .cjs .jsx .ts .mts .cts .tsx .py)", .{std.fs.path.extension(target)});
        if (scanFile(c, target)) |r| try results.append(c.arena, r);
    }
    std.mem.sort(FileResult, results.items, {}, struct {
        fn lt(_: void, a: FileResult, b: FileResult) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    const show_all = args.has("all");

    if (args.has("json")) {
        const w = c.out;
        try w.writeByte('[');
        var first_file = true;
        for (results.items) |r| {
            if (!first_file) try w.writeByte(',');
            first_file = false;
            try w.writeAll("{\"file\":");
            try jsonx.writeString(w, c.rel(r.path));
            try w.print(",\"language\":\"{s}\",\"functions\":[", .{@tagName(r.language)});
            var first = true;
            for (r.functions) |f| {
                if (!f.exported and !show_all) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try std.json.Stringify.value(f, .{}, w);
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]\n");
        return 0;
    }

    var total: usize = 0;
    var hidden: usize = 0;
    var first_suggestion: ?struct { []const u8, []const u8 } = null;
    for (results.items) |r| {
        var shown: usize = 0;
        for (r.functions) |f| {
            if (f.exported or show_all) shown += 1 else hidden += 1;
        }
        if (shown == 0) continue;
        c.print("{s}{s}{s}  {s}({s}){s}\n", .{ c.s(.bold), c.rel(r.path), c.s(.reset), c.s(.dim), @tagName(r.language), c.s(.reset) });
        for (r.functions) |f| {
            if (!f.exported and !show_all) continue;
            total += 1;
            c.print("  {s}{d: >5}{s}  ", .{ c.s(.dim), f.line, c.s(.reset) });
            try writeSignature(c.out, f);
            if (!f.exported) c.print("  {s}[not exported]{s}", .{ c.s(.yellow), c.s(.reset) });
            if (f.is_async) c.print("  {s}[async]{s}", .{ c.s(.dim), c.s(.reset) });
            c.print("\n", .{});
            if (first_suggestion == null and f.exported) first_suggestion = .{ r.path, f.name };
        }
    }
    if (total == 0) {
        c.print("no portable functions found in {s}\n", .{c.rel(target)});
        if (hidden > 0) c.print("({d} functions are not exported; pass --all to list them)\n", .{hidden});
        return 0;
    }
    c.print("\n{d} function(s) in {d} file(s)", .{ total, results.items.len });
    if (hidden > 0) c.print(", {d} not exported (--all)", .{hidden});
    c.print("\n", .{});
    if (first_suggestion) |sug| {
        c.print("next: {s}zig-anything init {s} {s}{s}\n", .{ c.s(.cyan), c.rel(sug[0]), sug[1], c.s(.reset) });
    }
    return 0;
}

pub fn runInit(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const file_arg = args.pos(0) orelse return c.fail("usage: zig-anything init <source-file> <function>", .{});
    const fn_name = args.pos(1) orelse return c.fail("usage: zig-anything init <source-file> <function>", .{});
    const source_abs = c.abs(file_arg) catch return c.fail("out of memory", .{});
    const language = lang.Language.fromPath(source_abs) orelse
        return c.fail("unsupported file type '{s}' (supported: .js .mjs .cjs .jsx .ts .mts .cts .tsx .py)", .{std.fs.path.extension(source_abs)});
    const text = Io.Dir.cwd().readFileAlloc(c.io, source_abs, c.arena, .limited(max_source_bytes)) catch |err|
        return c.fail("cannot read {s}: {s}", .{ file_arg, @errorName(err) });
    const fns = scan.scanSource(c.arena, language, text) catch return c.fail("out of memory", .{});

    var found: ?lang.Function = null;
    for (fns) |f| {
        if (!std.mem.eql(u8, f.name, fn_name)) continue;
        if (found == null or (f.exported and !found.?.exported)) found = f;
    }
    const f = found orelse {
        var names: std.ArrayList([]const u8) = .empty;
        for (fns) |g| names.append(c.arena, g.name) catch {};
        if (cli.suggest(fn_name, names.items)) |s| c.hint("did you mean `{s}`?", .{s});
        if (names.items.len > 0) c.hint("run `zig-anything scan {s}` to list functions", .{file_arg});
        return c.fail("no top-level function '{s}' in {s}", .{ fn_name, file_arg });
    };
    if (language.isJs() and !f.exported) {
        c.hint("the recorder imports the module, so add `export` to `{s}` (or list it in module.exports)", .{fn_name});
        return c.fail("'{s}' is not exported from {s}", .{ fn_name, file_arg });
    }
    if (f.variadic) c.warn("'{s}' takes rest/variadic parameters; the recorder only passes the named ones", .{fn_name});

    const cfg = try config.load(c, c.cwd);
    const dir = if (args.get("out")) |o|
        c.abs(o) catch return c.fail("out of memory", .{})
    else
        std.fs.path.join(c.arena, &.{ cfg.root, cfg.config.units_dir, fn_name }) catch return c.fail("out of memory", .{});

    const manifest: unit_mod.Manifest = .{
        .name = fn_name,
        .language = language,
        .source = try unit_mod.relativeSource(c, dir, source_abs),
        .function = fn_name,
        .params = f.params,
        .returns = f.returns,
        .is_async = f.is_async,
    };
    const res = try unit_mod.scaffold(c, .{
        .dir = dir,
        .manifest = manifest,
        .source_display = blk: {
            const shown = c.arena.dupe(u8, c.rel(source_abs)) catch break :blk source_abs;
            std.mem.replaceScalar(u8, shown, '\\', '/');
            break :blk shown;
        },
        .line = f.line,
        .force = args.has("force"),
    });
    const rel_dir = c.rel(dir);
    c.print("{s}created{s} unit {s}{s}{s} for {s}:{d} ({s})\n", .{ c.s(.green), c.s(.reset), c.s(.bold), rel_dir, c.s(.reset), c.rel(source_abs), f.line, @tagName(language) });
    c.print("  signature  ", .{});
    try writeSignature(c.out, f);
    c.print("\n  port       {s}{s}\n", .{ rel_dir, if (res.port_created) "/src/port.zig (new stub)" else "/src/port.zig (kept)" });
    c.print("\nnext:\n  zig-anything record {s}\n  # implement src/port.zig\n  zig-anything diff {s}\n  zig-anything gate {s}\n", .{ rel_dir, rel_dir, rel_dir });
    return 0;
}
