//! Port units: a directory holding one function's Zig port, its manifest
//! (`unit.json`), recorded cases and generated build files.
//!
//!   <unit>/unit.json        what is being ported and from where
//!   <unit>/cases.jsonl      recorded behavior of the original (commit this)
//!   <unit>/inputs.jsonl     optional extra inputs you add by hand
//!   <unit>/src/port.zig     the port — yours to write
//!   <unit>/src/harness.zig  generated; feeds cases to the port
//!   <unit>/src/rt.zig       generated runtime
//!   <unit>/build.zig        generated once; safe to extend
//!   <unit>/.za/             scratch files (ignored)

const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const lang = @import("lang.zig");
const proc = @import("proc.zig");
const hash = @import("hash.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const manifest_name = "unit.json";
pub const cases_name = "cases.jsonl";
pub const inputs_name = "inputs.jsonl";
/// Inputs found by `zig-anything fuzz`; recorded like inputs.jsonl.
pub const fuzz_inputs_name = "inputs.fuzz.jsonl";
pub const work_dir = ".za";
pub const todo_marker = "TODO(zig-anything)";

const rt_source = @embedFile("assets/rt.zig");
const build_template = @embedFile("assets/unit_build.zig");

pub const Kind = enum {
    /// One function, called in-process with JSON arguments.
    function,
    /// A whole command-line program: arguments + stdin in, stdout + exit code out.
    cli,
};

pub const Manifest = struct {
    schema: u32 = 1,
    kind: Kind = .function,
    name: []const u8,
    // ---- function units
    language: ?lang.Language = null,
    /// Source file, relative to the unit directory, `/`-separated.
    source: []const u8 = "",
    function: []const u8 = "",
    params: []const lang.Param = &.{},
    returns: ?lang.ParamType = null,
    is_async: bool = false,
    // ---- cli units
    /// The original program and any leading arguments.
    command: []const []const u8 = &.{},
    /// Working directory for both programs, relative to the unit directory.
    cwd: []const u8 = ".",

    pub fn lang_(m: Manifest) lang.Language {
        return m.language orelse .javascript;
    }
};

pub const Unit = struct {
    dir: []const u8,
    manifest: Manifest,
    source_abs: []const u8,
    /// cli units: absolute working directory for both programs.
    cwd_abs: []const u8,
    cfg: config.Loaded,

    pub fn isCli(u: Unit) bool {
        return u.manifest.kind == .cli;
    }

    /// The file the user writes: src/port.zig or, for programs, src/main.zig.
    pub fn portFile(u: Unit) []const u8 {
        return if (u.isCli()) "src/main.zig" else "src/port.zig";
    }

    pub fn path(u: Unit, a: Allocator, rel: []const u8) []const u8 {
        return std.fs.path.join(a, &.{ u.dir, rel }) catch rel;
    }

    pub fn workPath(u: Unit, a: Allocator, name: []const u8) []const u8 {
        return std.fs.path.join(a, &.{ u.dir, work_dir, name }) catch name;
    }

    pub fn ensureWorkDir(u: Unit, c: *cli.Ctx) cli.Reported!void {
        Io.Dir.cwd().createDirPath(c.io, u.path(c.arena, work_dir)) catch |err|
            return c.fail("cannot create {s}: {s}", .{ u.path(c.arena, work_dir), @errorName(err) });
    }

    pub fn harnessExe(u: Unit, a: Allocator, prefix: []const u8) []const u8 {
        return std.fs.path.join(a, &.{ u.dir, prefix, "bin", "harness" ++ proc.exe_suffix }) catch prefix;
    }
};

pub fn exists(c: *cli.Ctx, p: []const u8) bool {
    Io.Dir.cwd().access(c.io, p, .{}) catch return false;
    return true;
}

/// Resolves a unit argument: a unit directory, a path to unit.json, or a
/// unit name inside the configured units directory.
pub fn load(c: *cli.Ctx, arg: ?[]const u8) cli.Reported!Unit {
    const given = arg orelse return c.fail("missing <unit> argument (a unit directory or name)", .{});
    var dir = c.abs(given) catch return c.fail("out of memory", .{});
    if (std.mem.eql(u8, std.fs.path.basename(dir), manifest_name)) dir = std.fs.path.dirname(dir) orelse dir;
    var manifest_path = std.fs.path.join(c.arena, &.{ dir, manifest_name }) catch return c.fail("out of memory", .{});
    if (!exists(c, manifest_path)) {
        const cfg = try config.load(c, c.cwd);
        const alt = std.fs.path.join(c.arena, &.{ cfg.root, cfg.config.units_dir, given }) catch return c.fail("out of memory", .{});
        const alt_manifest = std.fs.path.join(c.arena, &.{ alt, manifest_name }) catch return c.fail("out of memory", .{});
        if (!exists(c, alt_manifest)) {
            c.hint("create one with `zig-anything init <source-file> <function>`", .{});
            return c.fail("no port unit at '{s}' (looked for {s})", .{ given, c.rel(manifest_path) });
        }
        dir = alt;
        manifest_path = alt_manifest;
    }
    const text = Io.Dir.cwd().readFileAlloc(c.io, manifest_path, c.arena, .limited(1 << 20)) catch |err|
        return c.fail("cannot read {s}: {s}", .{ manifest_path, @errorName(err) });
    const m = std.json.parseFromSliceLeaky(Manifest, c.arena, text, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err|
        return c.fail("{s} is not a valid unit manifest ({s})", .{ c.rel(manifest_path), @errorName(err) });
    if (m.schema != 1) return c.fail("{s}: unsupported schema {d}; upgrade zig-anything", .{ c.rel(manifest_path), m.schema });
    switch (m.kind) {
        .function => if (m.language == null or m.function.len == 0 or m.source.len == 0)
            return c.fail("{s}: function units need \"language\", \"source\" and \"function\"", .{c.rel(manifest_path)}),
        .cli => if (m.command.len == 0)
            return c.fail("{s}: cli units need a non-empty \"command\"", .{c.rel(manifest_path)}),
    }
    const source_abs = std.fs.path.resolveAlloc(c.arena, &.{ dir, m.source }) catch return c.fail("out of memory", .{});
    const cwd_abs = std.fs.path.resolveAlloc(c.arena, &.{ dir, m.cwd }) catch return c.fail("out of memory", .{});
    return .{ .dir = dir, .manifest = m, .source_abs = source_abs, .cwd_abs = cwd_abs, .cfg = try config.load(c, dir) };
}

pub fn writeFile(c: *cli.Ctx, p: []const u8, data: []const u8) cli.Reported!void {
    if (std.fs.path.dirname(p)) |d| Io.Dir.cwd().createDirPath(c.io, d) catch {};
    Io.Dir.cwd().writeFile(c.io, .{ .sub_path = p, .data = data }) catch |err|
        return c.fail("cannot write {s}: {s}", .{ p, @errorName(err) });
}

pub fn renderHarness(a: Allocator, function: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.writeAll(
        \\// Generated by zig-anything. Do not edit: `zig-anything init --force` rewrites it.
        \\const std = @import("std");
        \\const rt = @import("rt.zig");
        \\const port = @import("port.zig");
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    return rt.harnessMain(init, port.
    );
    try lang.writeZigIdent(w, function);
    try w.writeAll(");\n}\n");
    return aw.toOwnedSlice();
}

pub fn renderPortStub(a: Allocator, m: Manifest, source_display: []const u8, line: u32) ![]u8 {
    var aw: Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print(
        \\//! Zig port of `{s}` ({s}:{d}).
        \\//!
        \\//! Implement the function below, then:
        \\//!   zig-anything diff <unit>   compare against the recorded behavior
        \\//!   zig-anything gate <unit>   every check must pass
        \\//!
        \\//! Parameter types were inferred from the source; change them freely, the
        \\//! harness adapts to whatever signature you write. A `std.mem.Allocator`
        \\//! parameter receives a per-call arena that is reset after every call.
        \\//! Returning an error matches a recorded throw/raise.
        \\
        \\const std = @import("std");
        \\
        \\// {s}: port this function, then delete this line.
        \\pub fn
    , .{ m.function, source_display, line, todo_marker });
    try w.writeByte(' ');
    try lang.writeZigIdent(w, m.function);
    try w.writeAll("(allocator: std.mem.Allocator");
    for (m.params) |p| {
        try w.writeAll(", ");
        try lang.writeZigIdent(w, p.name);
        try w.writeAll(": ");
        if (p.optional) try w.writeByte('?');
        try w.writeAll(p.type.zigType());
    }
    try w.writeAll(") !");
    try w.writeAll(if (m.returns) |r| r.zigType() else "std.json.Value");
    try w.writeAll(" {\n    _ = allocator;\n");
    for (m.params) |p| {
        try w.writeAll("    _ = ");
        try lang.writeZigIdent(w, p.name);
        try w.writeAll(";\n");
    }
    try w.writeAll("    return error.NotImplemented;\n}\n");
    if (m.returns == null) {
        try w.writeAll("\n// The return type is unknown until `zig-anything record` runs; its summary\n// lists the observed result types. Replace std.json.Value with a concrete type.\n");
    }
    return aw.toOwnedSlice();
}

pub const ScaffoldOptions = struct {
    dir: []const u8,
    manifest: Manifest,
    source_display: []const u8,
    line: u32,
    force: bool,
};

/// Creates or refreshes a unit directory. Never overwrites an existing
/// `src/port.zig` or `build.zig`; regenerates the runtime and harness.
pub fn scaffold(c: *cli.Ctx, o: ScaffoldOptions) cli.Reported!struct { port_created: bool } {
    const a = c.arena;
    const manifest_path = std.fs.path.join(a, &.{ o.dir, manifest_name }) catch return c.fail("out of memory", .{});
    if (exists(c, manifest_path) and !o.force) {
        c.hint("pass --force to regenerate its manifest and harness (your port.zig is kept)", .{});
        return c.fail("a unit already exists at {s}", .{c.rel(o.dir)});
    }
    const manifest_json = std.json.Stringify.valueAlloc(a, o.manifest, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }) catch return c.fail("out of memory", .{});
    try writeFile(c, manifest_path, std.mem.concat(a, u8, &.{ manifest_json, "\n" }) catch return c.fail("out of memory", .{}));

    const j = struct {
        fn f(cc: *cli.Ctx, parts: []const []const u8) cli.Reported![]const u8 {
            return std.fs.path.join(cc.arena, parts) catch cc.fail("out of memory", .{});
        }
    }.f;
    try writeFile(c, try j(c, &.{ o.dir, "src", "rt.zig" }), rt_source);
    try writeFile(c, try j(c, &.{ o.dir, "src", "harness.zig" }), renderHarness(a, o.manifest.function) catch return c.fail("out of memory", .{}));
    const build_path = try j(c, &.{ o.dir, "build.zig" });
    if (!exists(c, build_path)) try writeFile(c, build_path, build_template);
    const gi = try j(c, &.{ o.dir, ".gitignore" });
    if (!exists(c, gi)) try writeFile(c, gi, "zig-out/\nzig-out-fast/\n.zig-cache/\n.za/\n");
    const port_path = try j(c, &.{ o.dir, "src", "port.zig" });
    var port_created = false;
    if (!exists(c, port_path)) {
        try writeFile(c, port_path, renderPortStub(a, o.manifest, o.source_display, o.line) catch return c.fail("out of memory", .{}));
        port_created = true;
    }
    return .{ .port_created = port_created };
}

/// Zig optimization modes, as accepted by `zig build -Doptimize=`.
pub const Optimize = enum {
    debug,
    safe,
    fast,
    small,

    /// Accepts the mode names and the older ReleaseSafe-style spellings.
    pub fn parse(s: []const u8) ?Optimize {
        if (std.meta.stringToEnum(Optimize, s)) |m| return m;
        const legacy = .{ .{ "Debug", Optimize.debug }, .{ "ReleaseSafe", Optimize.safe }, .{ "ReleaseFast", Optimize.fast }, .{ "ReleaseSmall", Optimize.small } };
        inline for (legacy) |e| if (std.ascii.eqlIgnoreCase(s, e[0])) return e[1];
        return null;
    }
};

/// Rewrites the unit's generated runtime when it differs from the version
/// embedded in this binary, so upgrading zig-anything upgrades every unit.
pub fn refreshRuntime(c: *cli.Ctx, u: Unit) cli.Reported!void {
    if (u.isCli()) return; // programs have no generated runtime
    const p = u.path(c.arena, "src/rt.zig");
    const current = Io.Dir.cwd().readFileAlloc(c.io, p, c.arena, .limited(4 << 20)) catch "";
    if (std.mem.eql(u8, current, rt_source)) return;
    try writeFile(c, p, rt_source);
}

// ---------------------------------------------------------------- build cache

const skip_dirs = std.StaticStringMap(void).initComptime(.{
    .{"zig-out"}, .{"zig-out-fast"}, .{".zig-cache"}, .{work_dir}, .{"bridge"}, .{"node_modules"}, .{".git"},
});

/// Adds every `@import("x.zig")` / `@embedFile("x")` path in `text` that
/// leaves `unit_dir` to `out` (resolved against `file_dir`).
fn escapingRefs(c: *cli.Ctx, unit_dir: []const u8, file_dir: []const u8, text: []const u8, out: *std.ArrayList([]const u8)) void {
    for ([_][]const u8{ "@import(\"", "@embedFile(\"" }) |needle| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, needle)) |i| {
            at = i + needle.len;
            const end = std.mem.indexOfScalarPos(u8, text, at, '"') orelse break;
            const ref = text[at..end];
            if (std.mem.eql(u8, needle, "@import(\"") and !std.mem.endsWith(u8, ref, ".zig")) continue; // a module, e.g. "std"
            const full = std.fs.path.resolveAlloc(c.arena, &.{ file_dir, ref }) catch continue;
            const rel_path = std.fs.path.relativeAlloc(c.arena, c.cwd, c.env, unit_dir, full) catch continue;
            if (!std.mem.startsWith(u8, rel_path, "..")) continue; // already hashed with the unit
            for (out.items) |seen| {
                if (std.mem.eql(u8, seen, full)) break;
            } else out.append(c.arena, full) catch {};
        }
    }
}

/// A key for everything `zig build` reads for this unit: build files, all of
/// src/, files outside the unit that the sources import or embed, the
/// compiler binary, the mode and the step. Null when the unit cannot be read.
fn buildKey(c: *cli.Ctx, u: Unit, optimize: Optimize, prefix: []const u8, step: ?[]const u8) ?hash.Hex {
    var h: hash.Builder = .{};
    h.add("mode", @tagName(optimize));
    h.add("prefix", prefix);
    h.add("step", step orelse "install");
    h.add("zig", u.cfg.config.zig);
    // The compiler itself: identify it by size and mtime (cheap, and changes
    // whenever Zig is upgraded in place).
    if (proc.findExecutable(c, u.cfg.config.zig)) |zig_path| {
        if (Io.Dir.cwd().statFile(c.io, zig_path, .{})) |st| {
            var buf: [64]u8 = undefined;
            h.add("zig-stat", std.fmt.bufPrint(&buf, "{d}:{d}", .{ st.size, st.mtime.nanoseconds }) catch "");
        } else |_| {}
    }
    var files: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "build.zig", "build.zig.zon" }) |name| files.append(c.arena, u.path(c.arena, name)) catch return null;
    {
        const src_dir = u.path(c.arena, "src");
        var dir = Io.Dir.cwd().openDir(c.io, src_dir, .{ .iterate = true }) catch return null;
        defer dir.close(c.io);
        var walker = dir.walkSelectively(c.gpa) catch return null;
        defer walker.deinit();
        while (walker.next(c.io) catch return null) |entry| {
            if (entry.kind == .directory) {
                if (!skip_dirs.has(entry.basename) and entry.basename[0] != '.') walker.enter(c.io, entry) catch return null;
                continue;
            }
            files.append(c.arena, std.fs.path.join(c.arena, &.{ src_dir, entry.path }) catch return null) catch return null;
        }
    }
    // Sorted, so the key does not depend on directory iteration order.
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var i: usize = 0;
    while (i < files.items.len) : (i += 1) {
        const f = files.items[i];
        const text = Io.Dir.cwd().readFileAlloc(c.io, f, c.arena, .limited(64 << 20)) catch |err| switch (err) {
            error.FileNotFound => {
                h.add(f, "<missing>");
                continue;
            },
            else => return null,
        };
        const rel_name = std.fs.path.relativeAlloc(c.arena, c.cwd, c.env, u.dir, f) catch f;
        h.add(rel_name, text);
        if (std.mem.endsWith(u8, f, ".zig")) {
            var extra: std.ArrayList([]const u8) = .empty;
            escapingRefs(c, u.dir, std.fs.path.dirname(f) orelse u.dir, text, &extra);
            for (extra.items) |e| {
                for (files.items) |known| {
                    if (std.mem.eql(u8, known, e)) break;
                } else files.append(c.arena, e) catch return null;
            }
        }
    }
    return h.final();
}

fn cachePath(c: *cli.Ctx, u: Unit, optimize: Optimize, prefix: []const u8, step: ?[]const u8) []const u8 {
    return u.workPath(c.arena, std.fmt.allocPrint(c.arena, "build.{s}.{s}.{s}.key", .{ prefix, step orelse "install", @tagName(optimize) }) catch "build.key");
}

/// The stamp stored with a key: the build output's size and mtime, so a
/// binary replaced behind our back invalidates the cache.
fn outputStamp(c: *cli.Ctx, u: Unit, prefix: []const u8, step: ?[]const u8) []const u8 {
    if (step != null) return "-";
    const exe = u.harnessExe(c.arena, prefix);
    const exe_path = if (u.isCli()) std.fs.path.join(c.arena, &.{ u.dir, prefix, "bin", "port" ++ proc.exe_suffix }) catch exe else exe;
    const st = Io.Dir.cwd().statFile(c.io, exe_path, .{}) catch return "<missing>";
    return std.fmt.allocPrint(c.arena, "{d}:{d}", .{ st.size, st.mtime.nanoseconds }) catch "?";
}

/// Runs `zig build` for the unit. Prints compiler output and returns false
/// on failure. Skips the compiler entirely when nothing it reads changed
/// since the last successful build with the same mode and step.
pub fn build(c: *cli.Ctx, u: Unit, optimize: Optimize, prefix: []const u8, step: ?[]const u8) cli.Reported!bool {
    try refreshRuntime(c, u);
    const use_cache = u.cfg.config.cache and !c.no_cache;
    const key: ?hash.Hex = if (use_cache) buildKey(c, u, optimize, prefix, step) else null;
    const key_path = cachePath(c, u, optimize, prefix, step);
    if (key) |k| {
        const saved = Io.Dir.cwd().readFileAlloc(c.io, key_path, c.arena, .limited(4096)) catch "";
        const want = std.fmt.allocPrint(c.arena, "{s} {s}", .{ &k, outputStamp(c, u, prefix, step) }) catch "";
        if (want.len > 0 and std.mem.eql(u8, std.mem.trim(u8, saved, " \r\n"), want)) return true;
    }
    const ok = try buildUncached(c, u, optimize, prefix, step);
    if (ok) {
        if (key) |k| {
            u.ensureWorkDir(c) catch {};
            const line = std.fmt.allocPrint(c.arena, "{s} {s}\n", .{ &k, outputStamp(c, u, prefix, step) }) catch "";
            Io.Dir.cwd().writeFile(c.io, .{ .sub_path = key_path, .data = line }) catch {};
        }
    } else Io.Dir.cwd().deleteFile(c.io, key_path) catch {};
    return ok;
}

fn buildUncached(c: *cli.Ctx, u: Unit, optimize: Optimize, prefix: []const u8, step: ?[]const u8) cli.Reported!bool {
    const opt_arg = std.fmt.allocPrint(c.arena, "-Doptimize={s}", .{@tagName(optimize)}) catch return c.fail("out of memory", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(c.arena, &.{ u.cfg.config.zig, "build" }) catch return c.fail("out of memory", .{});
    if (step) |st| argv.append(c.arena, st) catch {};
    argv.appendSlice(c.arena, &.{ opt_arg, "--prefix", prefix }) catch return c.fail("out of memory", .{});
    const r = try proc.run(c, argv.items, .{
        .cwd = u.dir,
        .timeout_s = u.cfg.config.timeout,
        .missing_hint = "install Zig from https://ziglang.org/download/ or set ZIG / \"zig\" in zig-anything.json",
    });
    if (!r.ok) {
        c.out.flush() catch {};
        c.err.writeAll(r.stderr) catch {};
        c.err.writeAll(r.stdout) catch {};
        c.err.flush() catch {};
        return false;
    }
    return true;
}

/// True when the port still carries the scaffold's TODO marker.
pub fn portIsStub(c: *cli.Ctx, u: Unit) bool {
    const text = Io.Dir.cwd().readFileAlloc(c.io, u.path(c.arena, u.portFile()), c.arena, .limited(16 << 20)) catch return true;
    return std.mem.indexOf(u8, text, todo_marker) != null;
}

/// Source path relative to the unit directory, with `/` separators.
pub fn relativeSource(c: *cli.Ctx, unit_dir: []const u8, source_abs: []const u8) cli.Reported![]const u8 {
    const r = std.fs.path.relativeAlloc(c.arena, c.cwd, c.env, unit_dir, source_abs) catch return c.fail("out of memory", .{});
    std.mem.replaceScalar(u8, r, '\\', '/');
    return r;
}

test "port stub and harness render valid-looking Zig" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m: Manifest = .{
        .name = "slug",
        .language = .typescript,
        .source = "../../src/slug.ts",
        .function = "slugify",
        .params = &.{ .{ .name = "text", .type = .string }, .{ .name = "type", .type = .int, .optional = true } },
        .returns = .string,
    };
    const stub = try renderPortStub(a, m, "src/slug.ts", 3);
    try std.testing.expect(std.mem.indexOf(u8, stub, "pub fn slugify(allocator: std.mem.Allocator, text: []const u8, @\"type\": ?i64) ![]const u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub, todo_marker) != null);
    const h = try renderHarness(a, "slugify");
    try std.testing.expect(std.mem.indexOf(u8, h, "rt.harnessMain(init, port.slugify);") != null);
}
