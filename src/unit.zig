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
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const manifest_name = "unit.json";
pub const cases_name = "cases.jsonl";
pub const inputs_name = "inputs.jsonl";
pub const work_dir = ".za";
pub const todo_marker = "TODO(zig-anything)";

const rt_source = @embedFile("assets/rt.zig");
const build_template = @embedFile("assets/unit_build.zig");

pub const Manifest = struct {
    schema: u32 = 1,
    name: []const u8,
    language: lang.Language,
    /// Source file, relative to the unit directory, `/`-separated.
    source: []const u8,
    function: []const u8,
    params: []const lang.Param,
    returns: ?lang.ParamType = null,
    is_async: bool = false,
};

pub const Unit = struct {
    dir: []const u8,
    manifest: Manifest,
    source_abs: []const u8,
    cfg: config.Loaded,

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

fn exists(c: *cli.Ctx, p: []const u8) bool {
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
    const source_abs = std.fs.path.resolveAlloc(c.arena, &.{ dir, m.source }) catch return c.fail("out of memory", .{});
    return .{ .dir = dir, .manifest = m, .source_abs = source_abs, .cfg = try config.load(c, dir) };
}

fn writeFile(c: *cli.Ctx, p: []const u8, data: []const u8) cli.Reported!void {
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
    const manifest_json = std.json.Stringify.valueAlloc(a, o.manifest, .{ .whitespace = .indent_2 }) catch return c.fail("out of memory", .{});
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

/// Runs `zig build` for the unit. Prints compiler output and returns false
/// on failure.
pub fn build(c: *cli.Ctx, u: Unit, optimize: Optimize, prefix: []const u8, step: ?[]const u8) cli.Reported!bool {
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
    const text = Io.Dir.cwd().readFileAlloc(c.io, u.path(c.arena, "src/port.zig"), c.arena, .limited(16 << 20)) catch return true;
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
