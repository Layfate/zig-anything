//! `integrate`: wire a finished port into the original source, verified, with
//! rollback.
//!
//!   1. build the bridge and replay every recorded case through it;
//!   2. back up the source file (unit/integration/), then rewrite it so the
//!      function's name is bound to the bridged port and the original is
//!      kept, renamed, as `<name>__original`;
//!   3. replay every recorded case through the rewritten source file, and
//!      run the project's own tests if a command is given after `--`;
//!   4. if anything fails, restore the original file byte for byte.
//!
//! `integrate --rollback` restores the original later. It refuses when the
//! file changed after integrating (that would lose edits) unless `--force`.

const std = @import("std");
const json = std.json;
const cli = @import("../cli.zig");
const lang = @import("../lang.zig");
const proc = @import("../proc.zig");
const hash = @import("../hash.zig");
const cases_mod = @import("../cases.zig");
const runtime = @import("../runtime.zig");
const unit_mod = @import("../unit.zig");
const scan = @import("../scan.zig");
const bridge = @import("bridge.zig");
const diff = @import("diff.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const flags = [_]cli.Flag{
    .{ .name = "rollback", .help = "restore the original source file" },
    .{ .name = "dry-run", .help = "print the rewritten lines and change nothing" },
    .{ .name = "force", .help = "with --rollback: restore even if the file changed after integrating" },
    .{ .name = "no-native", .help = "JS/TS: use only the WebAssembly binding" },
};

pub const record_dir = "integration";
pub const record_name = "integration.json";

/// What `integrate` did, kept in the unit for `--rollback` and `status`.
pub const Record = struct {
    /// Source file, relative to the unit directory, `/`-separated.
    source: []const u8,
    /// Copy of the original source, relative to the unit directory.
    backup: []const u8,
    original_sha256: []const u8,
    integrated_sha256: []const u8,
};

pub const marker = "zig-anything integrate";

// ---------------------------------------------------------------- rewriting

pub const RewriteError = error{ NotFound, CommonJs, Unsupported, OutOfMemory };

fn startsWithWord(s: []const u8, word: []const u8) bool {
    return std.mem.startsWith(u8, s, word) and (s.len == word.len or s[word.len] == ' ' or s[word.len] == '\t');
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}

/// If `line` declares `name` at the top level, returns the byte range of
/// the declaration keywords to drop (`export `, `export default `) and the
/// offset of the name. Recognized: `[export [default]] [async] function[*]
/// name`, `[export] const|let|var name`, `[export] declare function name`.
const Decl = struct { strip_end: usize, name_at: usize, default_export: bool, named_export: bool };

fn jsDecl(line: []const u8, name: []const u8) ?Decl {
    var i: usize = 0;
    var named = false;
    var default = false;
    if (startsWithWord(line, "export")) {
        i = 6;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (startsWithWord(line[i..], "default")) {
            default = true;
            i += 7;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        } else named = true;
    }
    const strip_end = i;
    for ([_][]const u8{ "declare", "async" }) |kw| if (startsWithWord(line[i..], kw)) {
        i += kw.len;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    };
    const kws = [_][]const u8{ "function*", "function", "const", "let", "var" };
    var matched = false;
    for (kws) |kw| if (std.mem.startsWith(u8, line[i..], kw)) {
        const after = i + kw.len;
        if (after < line.len and isIdentChar(line[after])) continue;
        i = after;
        matched = true;
        break;
    };
    if (!matched) return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '*')) i += 1;
    if (!std.mem.startsWith(u8, line[i..], name)) return null;
    const end = i + name.len;
    if (end < line.len and isIdentChar(line[end])) return null;
    return .{ .strip_end = strip_end, .name_at = i, .default_export = default, .named_export = named };
}

fn looksCommonJs(src: []const u8) bool {
    const cjs = std.mem.indexOf(u8, src, "module.exports") != null or std.mem.indexOf(u8, src, "exports.") != null;
    var esm = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (startsWithWord(line, "import") or startsWithWord(line, "export") or std.mem.startsWith(u8, line, "import{") or std.mem.startsWith(u8, line, "export{")) esm = true;
    }
    return cjs and !esm;
}

/// Rewrites an ES module so `name` comes from the bridge at `spec`.
pub fn rewriteJs(a: Allocator, src: []const u8, name: []const u8, spec: []const u8) RewriteError![]u8 {
    if (looksCommonJs(src)) return error.CommonJs;
    const eol = lineEnding(src);
    var out: std.ArrayList(u8) = .empty;
    var named = false;
    var default = false;
    var found = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    var header_done = false;
    while (it.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        // The import goes after a shebang, at the very top otherwise.
        if (!header_done) {
            header_done = true;
            if (std.mem.startsWith(u8, line, "#!")) {
                try out.appendSlice(a, line);
                try out.append(a, '\n');
                try appendImport(a, &out, name, spec);
                continue;
            }
            try appendImport(a, &out, name, spec);
            try out.appendSlice(a, eol);
        }
        if (jsDecl(line, name)) |d| {
            found = true;
            named = named or d.named_export;
            default = default or d.default_export;
            try out.appendSlice(a, line[d.strip_end..d.name_at]);
            try out.appendSlice(a, name);
            try out.appendSlice(a, "__original");
            try out.appendSlice(a, line[d.name_at + name.len ..]);
            continue;
        }
        try out.appendSlice(a, line);
    }
    if (!found) return error.NotFound;
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(a, eol);
    if (named) try out.print(a, "export {{ {s} }}; // {s}{s}", .{ name, marker, eol });
    if (default) try out.print(a, "export default {s}; // {s}{s}", .{ name, marker, eol });
    return out.toOwnedSlice(a);
}

fn appendImport(a: Allocator, out: *std.ArrayList(u8), name: []const u8, spec: []const u8) !void {
    try out.print(a, "import {{ {s} }} from '{s}'; // {s}: runs the Zig port; the original is {s}__original", .{ name, spec, marker, name });
}

/// Rewrites a Python module so `name` is bound to the bridge at
/// `binding_rel` (relative to the module's directory) where it was defined.
pub fn rewritePy(a: Allocator, src: []const u8, name: []const u8, binding_rel: []const u8) RewriteError![]u8 {
    const eol = lineEnding(src);
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| try lines.append(a, line);
    const n = lines.items.len;
    const def = try std.fmt.allocPrint(a, "def {s}(", .{name});
    const async_def = try std.fmt.allocPrint(a, "async def {s}(", .{name});
    var at: ?usize = null;
    for (lines.items, 0..) |line, i| {
        if (std.mem.startsWith(u8, line, async_def)) return error.Unsupported;
        if (std.mem.startsWith(u8, line, def)) {
            at = i;
            break;
        }
    }
    const def_line = at orelse return error.NotFound;
    // The loader goes above the function's decorators, if any.
    var insert = def_line;
    while (insert > 0 and std.mem.startsWith(u8, lines.items[insert - 1], "@")) insert -= 1;
    // The name is bound right after the original's body: before the next
    // top-level statement, above the blank lines that separate them.
    var end = def_line + 1;
    while (end < n) : (end += 1) {
        const l = lines.items[end];
        if (l.len > 0 and l[0] != ' ' and l[0] != '\t' and l[0] != '#' and l[0] != '\r') break;
    }
    var bind_at = end;
    while (bind_at > def_line + 1 and std.mem.trim(u8, lines.items[bind_at - 1], " \t\r").len == 0) bind_at -= 1;

    const loader = try std.fmt.allocPrint(a,
        \\# {s}: `{s}` runs the Zig port; the original is {s}__original.
        \\def _za_load_{s}():
        \\    import importlib.util, os
        \\    spec = importlib.util.spec_from_file_location("_za_{s}", os.path.join(os.path.dirname(os.path.abspath(__file__)), "{s}"))
        \\    module = importlib.util.module_from_spec(spec)
        \\    spec.loader.exec_module(module)
        \\    return module.{s}
        \\
        \\
        \\
    , .{ marker, name, name, name, name, binding_rel, name });
    const binding = try std.fmt.allocPrint(a, "{s} = _za_load_{s}()  # {s}\n", .{ name, name, marker });

    var out: std.ArrayList(u8) = .empty;
    for (lines.items, 0..) |line, i| {
        if (i == insert) try appendLines(a, &out, loader, eol);
        if (i == bind_at) try appendLines(a, &out, binding, eol);
        if (i == def_line) {
            try out.print(a, "def {s}__original(", .{name});
            try out.appendSlice(a, line[def.len..]);
        } else try out.appendSlice(a, line);
        if (i + 1 < n) try out.append(a, '\n');
    }
    if (bind_at >= n) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(a, eol);
        try appendLines(a, &out, binding, eol);
    }
    return out.toOwnedSlice(a);
}

/// "\r\n" when the file uses Windows line endings, "\n" otherwise.
fn lineEnding(src: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, src, "\r\n") != null) "\r\n" else "\n";
}

/// Appends `text` (lines ending in "\n") using `eol` as the line ending.
fn appendLines(a: Allocator, out: *std.ArrayList(u8), text: []const u8, eol: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.appendSlice(a, eol);
        first = false;
        try out.appendSlice(a, line);
    }
}

// ---------------------------------------------------------------- the command

fn writeFile(c: *cli.Ctx, p: []const u8, data: []const u8) cli.Reported!void {
    Io.Dir.cwd().writeFile(c.io, .{ .sub_path = p, .data = data }) catch |err|
        return c.fail("cannot write {s}: {s}", .{ c.rel(p), @errorName(err) });
}

fn loadRecord(c: *cli.Ctx, u: unit_mod.Unit) ?Record {
    const text = Io.Dir.cwd().readFileAlloc(c.io, u.path(c.arena, record_dir ++ "/" ++ record_name), c.arena, .limited(1 << 20)) catch return null;
    return json.parseFromSliceLeaky(Record, c.arena, text, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null;
}

/// True when the unit's source is currently integrated.
pub fn isIntegrated(c: *cli.Ctx, unit_dir: []const u8) bool {
    Io.Dir.cwd().access(c.io, std.fs.path.join(c.arena, &.{ unit_dir, record_dir, record_name }) catch return false, .{}) catch return false;
    return true;
}

/// Fails when `u` is integrated: its source now calls the port, so anything
/// that runs "the original" (record, fuzz, bench) would run the port and,
/// for `record`, overwrite the spec with the port's own behavior.
pub fn refuseIfIntegrated(c: *cli.Ctx, u: unit_mod.Unit, what: []const u8) cli.Reported!void {
    if (!isIntegrated(c, u.dir)) return;
    c.hint("roll back first with `zig-anything integrate --rollback {s}`, then integrate again", .{c.rel(u.dir)});
    return c.fail("{s} is integrated into {s}, so {s} would run the Zig port instead of the original", .{ u.manifest.function, c.rel(u.source_abs), what });
}

/// Prints the lines of `after` that differ from `before` (a compact diff:
/// changed regions with a line of context are enough to review a rewrite).
fn printChanges(c: *cli.Ctx, before: []const u8, after: []const u8) void {
    var old_lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, before, '\n');
    while (it.next()) |l| old_lines.append(c.arena, l) catch return;
    var it2 = std.mem.splitScalar(u8, after, '\n');
    var n: usize = 0;
    while (it2.next()) |l| {
        n += 1;
        var present = false;
        for (old_lines.items) |o| if (std.mem.eql(u8, o, l)) {
            present = true;
            break;
        };
        if (!present) c.print("{s}+ {s}{s}\n", .{ c.s(.green), l, c.s(.reset) });
    }
    var new_lines: std.ArrayList([]const u8) = .empty;
    var it3 = std.mem.splitScalar(u8, after, '\n');
    while (it3.next()) |l| new_lines.append(c.arena, l) catch return;
    for (old_lines.items) |o| {
        var present = false;
        for (new_lines.items) |l| if (std.mem.eql(u8, o, l)) {
            present = true;
            break;
        };
        if (!present) c.print("{s}- {s}{s}\n", .{ c.s(.red), o, c.s(.reset) });
    }
}

pub fn run(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const u = try unit_mod.load(c, args.pos(0));
    if (u.isCli()) return c.fail("integrate is for function units; a ported program replaces the original by itself", .{});
    if (args.has("rollback")) return rollback(c, u, args.has("force"));
    const m = u.manifest;
    if (isIntegrated(c, u.dir)) {
        c.hint("roll back first with `zig-anything integrate --rollback {s}`", .{c.rel(u.dir)});
        return c.fail("{s} is already integrated into {s}", .{ m.function, c.rel(u.source_abs) });
    }
    const original = Io.Dir.cwd().readFileAlloc(c.io, u.source_abs, c.arena, .limited(16 << 20)) catch |err|
        return c.fail("cannot read {s}: {s}", .{ c.rel(u.source_abs), @errorName(err) });
    const js = runtime.adapterOf(u).bridge == .node;

    // Where the binding is, as the source file would import it.
    const binding_abs = u.path(c.arena, if (js) "bridge/index.mjs" else "bridge/port.py");
    const src_dir = std.fs.path.dirname(u.source_abs) orelse ".";
    const rel = std.fs.path.relativeAlloc(c.arena, c.cwd, c.env, src_dir, binding_abs) catch return c.fail("out of memory", .{});
    std.mem.replaceScalar(u8, rel, '\\', '/');
    const spec = if (std.mem.startsWith(u8, rel, ".")) rel else std.fmt.allocPrint(c.arena, "./{s}", .{rel}) catch return c.fail("out of memory", .{});

    const rewritten = (if (js) rewriteJs(c.arena, original, m.function, spec) else rewritePy(c.arena, original, m.function, rel)) catch |err| switch (err) {
        error.NotFound => return c.fail("cannot find the top-level definition of {s} in {s}", .{ m.function, c.rel(u.source_abs) }),
        error.CommonJs => {
            c.hint("the bridge is an ES module; import it from an ES module, or call it from CommonJS with `await import()`", .{});
            return c.fail("{s} is CommonJS, which integrate does not rewrite", .{c.rel(u.source_abs)});
        },
        error.Unsupported => return c.fail("{s} is async; only synchronous functions can be integrated", .{m.function}),
        error.OutOfMemory => return c.fail("out of memory", .{}),
    };

    if (args.has("dry-run")) {
        c.print("{s} would change like this:\n", .{c.rel(u.source_abs)});
        printChanges(c, original, rewritten);
        return 0;
    }

    // 1. The bridge must reproduce every recorded case on its own.
    const effects = diff.effectsWanted(c, u, args);
    const built = (try bridge.buildAndVerify(c, u, .{ .native = !args.has("no-native"), .effects = effects })) orelse return 1;
    if (!built.verified) {
        c.report("not integrating: the bridge does not reproduce every recorded case", .{});
        return 1;
    }

    // 2. Back up, then rewrite.
    const backup_rel = std.fmt.allocPrint(c.arena, "{s}/original{s}", .{ record_dir, std.fs.path.extension(u.source_abs) }) catch return c.fail("out of memory", .{});
    Io.Dir.cwd().createDirPath(c.io, u.path(c.arena, record_dir)) catch |err| return c.fail("cannot create {s}: {s}", .{ c.rel(u.path(c.arena, record_dir)), @errorName(err) });
    try writeFile(c, u.path(c.arena, backup_rel), original);
    try writeFile(c, u.source_abs, rewritten);

    // 3. Verify through the rewritten source.
    const failure = try verify(c, u, effects, args.positional[@min(1, args.positional.len)..]);
    if (failure) |why| {
        // 4. Roll back on any failure.
        try writeFile(c, u.source_abs, original);
        Io.Dir.cwd().deleteTree(c.io, u.path(c.arena, record_dir)) catch {};
        c.report("{s}; rolled back {s} to the original", .{ why, c.rel(u.source_abs) });
        return 1;
    }
    const rec: Record = .{
        .source = m.source,
        .backup = backup_rel,
        .original_sha256 = &hash.of(original),
        .integrated_sha256 = &hash.of(rewritten),
    };
    var aw: Io.Writer.Allocating = .init(c.arena);
    json.Stringify.value(rec, .{ .whitespace = .indent_2 }, &aw.writer) catch return c.fail("out of memory", .{});
    aw.writer.writeByte('\n') catch return c.fail("out of memory", .{});
    try writeFile(c, u.path(c.arena, record_dir ++ "/" ++ record_name), aw.written());
    c.print("{s}integrated{s} {s} into {s}: callers now run the Zig port{s}\n", .{ c.s(.green), c.s(.reset), m.function, c.rel(u.source_abs), if (js and !args.has("no-native")) " (native addon, WebAssembly fallback)" else "" });
    c.print("  original kept as {s}__original; undo with: zig-anything integrate --rollback {s}\n", .{ m.function, c.rel(u.dir) });
    return 0;
}

/// Replays the recording through the rewritten source and runs the user's
/// test command. Returns why it failed, or null.
fn verify(c: *cli.Ctx, u: unit_mod.Unit, effects: bool, test_cmd: []const []const u8) cli.Reported!?[]const u8 {
    const cs = try cases_mod.load(c, u);
    const out_name = "integrated.jsonl";
    const r = try runtime.invoke(c, u, .run, u.path(c.arena, unit_mod.cases_name), u.workPath(c.arena, out_name), .{ .effects = effects });
    if (!r.ok) {
        c.out.flush() catch {};
        c.err.writeAll(r.stderr[r.stderr.len - @min(r.stderr.len, 2000) ..]) catch {};
        return "the rewritten source does not load";
    }
    const v = bridge.compareReplay(c, u, cs, out_name, effects);
    const ok = v.compared > 0 and v.matched == v.compared;
    c.print("{s}{d}/{d}{s} recorded cases match through the integrated {s}\n", .{ if (ok) c.s(.green) else c.s(.red), v.matched, v.compared, c.s(.reset), c.rel(u.source_abs) });
    if (!ok) return "the integrated source does not reproduce every recorded case";
    if (test_cmd.len > 0) {
        c.print("running {s}...\n", .{std.mem.join(c.arena, " ", test_cmd) catch "the tests"});
        c.out.flush() catch {};
        // Run where the user ran `integrate`, like they would run the tests.
        const t = try proc.run(c, test_cmd, .{ .timeout_s = u.cfg.config.timeout });
        if (!t.ok) {
            c.out.flush() catch {};
            c.err.writeAll(t.stdout[t.stdout.len - @min(t.stdout.len, 3000) ..]) catch {};
            c.err.writeAll(t.stderr[t.stderr.len - @min(t.stderr.len, 3000) ..]) catch {};
            return "the project's tests failed";
        }
        c.print("{s}tests passed{s}\n", .{ c.s(.green), c.s(.reset) });
    }
    return null;
}

fn rollback(c: *cli.Ctx, u: unit_mod.Unit, force: bool) !u8 {
    const rec = loadRecord(c, u) orelse return c.fail("{s} is not integrated (no {s}/{s})", .{ u.manifest.function, record_dir, record_name });
    const original = Io.Dir.cwd().readFileAlloc(c.io, u.path(c.arena, rec.backup), c.arena, .limited(16 << 20)) catch |err|
        return c.fail("cannot read the backup {s}: {s}", .{ c.rel(u.path(c.arena, rec.backup)), @errorName(err) });
    if (!std.mem.eql(u8, &hash.of(original), rec.original_sha256)) return c.fail("the backup {s} is damaged (its hash changed); restore from version control", .{c.rel(u.path(c.arena, rec.backup))});
    const current = Io.Dir.cwd().readFileAlloc(c.io, u.source_abs, c.arena, .limited(16 << 20)) catch "";
    if (!std.mem.eql(u8, &hash.of(current), rec.integrated_sha256) and !force) {
        c.hint("rolling back would discard those edits; pass --force to restore the original anyway", .{});
        return c.fail("{s} changed after it was integrated", .{c.rel(u.source_abs)});
    }
    try writeFile(c, u.source_abs, original);
    Io.Dir.cwd().deleteTree(c.io, u.path(c.arena, record_dir)) catch {};
    c.print("{s}rolled back{s} {s}: {s} runs the original again\n", .{ c.s(.green), c.s(.reset), c.rel(u.source_abs), u.manifest.function });
    return 0;
}

// ---------------------------------------------------------------- tests

test "rewrite an ES module" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\// helpers
        \\export function slugify(text) {
        \\  return text.toLowerCase();
        \\}
        \\export function title(t) { return slugify(t).toUpperCase(); }
        \\
    ;
    const out = try rewriteJs(a, src, "slugify", "../zig-port/slugify/bridge/index.mjs");
    try std.testing.expect(std.mem.startsWith(u8, out, "import { slugify } from '../zig-port/slugify/bridge/index.mjs';"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\nfunction slugify__original(text) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "export function title(t) { return slugify(t)") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "export { slugify }; // zig-anything integrate\n"));
    // Arrow functions, defaults and TypeScript overloads.
    const ts = try rewriteJs(a, "export const f = (x: number): number => x;\nexport default function g(x) { return x; }\n", "f", "./b.mjs");
    try std.testing.expect(std.mem.indexOf(u8, ts, "\nconst f__original = (x: number)") != null);
    const d = try rewriteJs(a, "export default function g(x) { return x; }\n", "g", "./b.mjs");
    try std.testing.expect(std.mem.indexOf(u8, d, "\nfunction g__original(x)") != null);
    try std.testing.expect(std.mem.endsWith(u8, d, "export default g; // zig-anything integrate\n"));
    try std.testing.expectError(error.NotFound, rewriteJs(a, src, "missing", "./b.mjs"));
    try std.testing.expectError(error.CommonJs, rewriteJs(a, "function f() {}\nmodule.exports = { f };\n", "f", "./b.mjs"));
    // A shebang stays first.
    const sb = try rewriteJs(a, "#!/usr/bin/env node\nexport function f() {}\n", "f", "./b.mjs");
    try std.testing.expect(std.mem.startsWith(u8, sb, "#!/usr/bin/env node\nimport { f }"));
    // A name that only starts like the function is left alone.
    const pre = try rewriteJs(a, "export function fx() {}\nexport function f() {}\n", "f", "./b.mjs");
    try std.testing.expect(std.mem.indexOf(u8, pre, "export function fx() {}") != null);
}

test "rewrite a Python module" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\import math
        \\
        \\@cache
        \\def dist(a: str, b: str) -> int:
        \\    return abs(len(a) - len(b))
        \\
        \\
        \\def near(a: str, b: str) -> bool:
        \\    return dist(a, b) < 2
        \\
    ;
    const out = try rewritePy(a, src, "dist", "../zig-port/dist/bridge/port.py");
    // The loader goes above the decorator, the original is renamed, and the
    // name is bound right after the original's body.
    const loader = std.mem.indexOf(u8, out, "def _za_load_dist():").?;
    const deco = std.mem.indexOf(u8, out, "@cache\ndef dist__original(a: str, b: str) -> int:").?;
    const bind = std.mem.indexOf(u8, out, "dist = _za_load_dist()  # zig-anything integrate\n").?;
    const near = std.mem.indexOf(u8, out, "def near(").?;
    try std.testing.expect(loader < deco and deco < bind and bind < near);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"../zig-port/dist/bridge/port.py\"") != null);
    try std.testing.expectError(error.NotFound, rewritePy(a, src, "missing", "x"));
    try std.testing.expectError(error.Unsupported, rewritePy(a, "async def f(x):\n    return x\n", "f", "x"));
    // Windows line endings are kept.
    const crlf = try rewritePy(a, "def f(x):\r\n    return x\r\n\r\nprint(f(1))\r\n", "f", "p.py");
    try std.testing.expect(std.mem.indexOf(u8, crlf, "f = _za_load_f()  # zig-anything integrate\r\n\r\nprint(f(1))") != null);
    try std.testing.expect(std.mem.indexOf(u8, crlf, "\r\r") == null);
    for (crlf, 0..) |ch, i| if (ch == '\n') try std.testing.expect(i > 0 and crlf[i - 1] == '\r');
    const crlf_js = try rewriteJs(a, "export function f(x) {\r\n  return x;\r\n}\r\n", "f", "./b.mjs");
    for (crlf_js, 0..) |ch, i| if (ch == '\n') try std.testing.expect(i > 0 and crlf_js[i - 1] == '\r');
    // At the end of a file without a trailing newline.
    const tail = try rewritePy(a, "def f(x):\n    return x", "f", "p.py");
    try std.testing.expect(std.mem.endsWith(u8, tail, "    return x\nf = _za_load_f()  # zig-anything integrate\n"));
}
