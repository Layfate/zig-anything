//! Command-line plumbing: the per-invocation context, styled output,
//! user-facing errors and a small flag parser.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Returned after a user-facing error has already been printed.
pub const Reported = error{Reported};
/// Returned after a usage error has already been printed.
pub const UsageError = error{Usage};

pub const Style = enum { reset, bold, dim, red, green, yellow, cyan };

pub const Ctx = struct {
    io: Io,
    gpa: Allocator,
    /// Lives for the whole invocation; most command data goes here.
    arena: Allocator,
    env: *const std.process.Environ.Map,
    out: *Io.Writer,
    err: *Io.Writer,
    color: bool,
    /// Absolute current working directory.
    cwd: []const u8,
    /// `--no-cache`: always run the compiler.
    no_cache: bool = false,
    /// stdout is an interactive terminal (progress lines are worth printing).
    tty: bool = false,

    pub fn s(c: *const Ctx, st: Style) []const u8 {
        if (!c.color) return "";
        return switch (st) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .cyan => "\x1b[36m",
        };
    }

    /// Prints `error: ...` (plus an optional hint line) and returns
    /// `error.Reported`.
    pub fn fail(c: *Ctx, comptime fmt: []const u8, args: anytype) Reported {
        c.report(fmt, args);
        return error.Reported;
    }

    /// Prints `error: ...` without returning an error (for commands that
    /// choose their own exit code).
    pub fn report(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        c.out.flush() catch {};
        c.err.print("{s}error:{s} " ++ fmt ++ "\n", .{ c.s(.red), c.s(.reset) } ++ args) catch {};
        c.err.flush() catch {};
    }

    pub fn hint(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        c.err.print("{s}hint:{s} " ++ fmt ++ "\n", .{ c.s(.cyan), c.s(.reset) } ++ args) catch {};
        c.err.flush() catch {};
    }

    pub fn warn(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        c.out.flush() catch {};
        c.err.print("{s}warning:{s} " ++ fmt ++ "\n", .{ c.s(.yellow), c.s(.reset) } ++ args) catch {};
        c.err.flush() catch {};
    }

    pub fn print(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        c.out.print(fmt, args) catch {};
    }

    /// Resolves `p` against the current directory.
    pub fn abs(c: *Ctx, p: []const u8) ![]const u8 {
        return std.fs.path.resolveAlloc(c.arena, &.{ c.cwd, p });
    }

    /// Path relative to the cwd for display (falls back to the input).
    pub fn rel(c: *Ctx, p: []const u8) []const u8 {
        const r = std.fs.path.relativeAlloc(c.arena, c.cwd, c.env, c.cwd, p) catch return p;
        if (r.len == 0) return ".";
        return r;
    }
};

pub const Flag = struct {
    name: []const u8,
    /// Placeholder shown in help; null means the flag is a boolean switch.
    value: ?[]const u8 = null,
    help: []const u8,
};

pub const Parsed = struct {
    positional: []const []const u8,
    names: []const []const u8,
    values: []const ?[]const u8,

    pub fn has(p: Parsed, name: []const u8) bool {
        for (p.names) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    pub fn get(p: Parsed, name: []const u8) ?[]const u8 {
        var i = p.names.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, p.names[i], name)) return p.values[i];
        }
        return null;
    }

    pub fn pos(p: Parsed, i: usize) ?[]const u8 {
        return if (i < p.positional.len) p.positional[i] else null;
    }
};

fn findFlag(spec: []const Flag, name: []const u8) ?Flag {
    for (spec) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

pub const ParseError = error{ UnknownFlag, MissingValue, OutOfMemory };

/// Parses `--name`, `--name value`, `--name=value`, positional arguments and
/// `--` (everything after it is positional). On error, `bad` names the
/// offending flag.
pub fn parse(a: Allocator, argv: []const []const u8, spec: []const Flag, bad: *[]const u8) ParseError!Parsed {
    var positional: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(?[]const u8) = .empty;
    var i: usize = 0;
    var rest_positional = false;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (rest_positional or arg.len < 2 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            try positional.append(a, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            rest_positional = true;
            continue;
        }
        var name = std.mem.trimStart(u8, arg, "-");
        var inline_value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
            inline_value = name[eq + 1 ..];
            name = name[0..eq];
        }
        const f = findFlag(spec, name) orelse {
            bad.* = arg;
            return error.UnknownFlag;
        };
        try names.append(a, f.name);
        if (f.value == null) {
            try values.append(a, null);
            continue;
        }
        if (inline_value) |v| {
            try values.append(a, v);
        } else if (i + 1 < argv.len) {
            i += 1;
            try values.append(a, argv[i]);
        } else {
            bad.* = arg;
            return error.MissingValue;
        }
    }
    return .{ .positional = positional.items, .names = names.items, .values = values.items };
}

/// Levenshtein distance, for "did you mean" suggestions.
pub fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return @max(a.len, b.len);
    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            cur[j + 1] = @min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// Returns the closest candidate within a reasonable distance.
pub fn suggest(word: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = std.math.maxInt(usize);
    for (candidates) |cand| {
        const d = editDistance(word, cand);
        if (d < best_d) {
            best_d = d;
            best = cand;
        }
    }
    if (best_d <= @max(2, word.len / 3)) return best;
    return null;
}

pub fn parseInt(comptime T: type, c: *Ctx, p: Parsed, name: []const u8, default: T) Reported!T {
    const v = p.get(name) orelse return default;
    return std.fmt.parseInt(T, v, 10) catch c.fail("--{s} expects a whole number, got '{s}'", .{ name, v });
}

pub fn parseFloat(c: *Ctx, p: Parsed, name: []const u8, default: f64) Reported!f64 {
    const v = p.get(name) orelse return default;
    const f = std.fmt.parseFloat(f64, v) catch return c.fail("--{s} expects a number, got '{s}'", .{ name, v });
    if (!std.math.isFinite(f) or f < 0) return c.fail("--{s} must be a finite, non-negative number", .{name});
    return f;
}

/// Worker count for parallel work: `--jobs N`, else the configured value,
/// else one per CPU core. Never less than 1.
pub fn jobCount(c: *Ctx, p: Parsed, configured: u32) Reported!usize {
    const n = try parseInt(u32, c, p, "jobs", configured);
    if (n > 0) return n;
    return std.Thread.getCpuCount() catch 1;
}

test "parse flags and positionals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const spec = [_]Flag{
        .{ .name = "json", .help = "" },
        .{ .name = "samples", .value = "N", .help = "" },
    };
    var bad: []const u8 = "";
    const p = try parse(arena.allocator(), &.{ "unit", "--samples", "5", "--json", "--samples=7", "--", "--x" }, &spec, &bad);
    try std.testing.expectEqual(@as(usize, 2), p.positional.len);
    try std.testing.expectEqualStrings("--x", p.positional[1]);
    try std.testing.expect(p.has("json"));
    try std.testing.expectEqualStrings("7", p.get("samples").?);
    try std.testing.expectError(error.UnknownFlag, parse(arena.allocator(), &.{"--nope"}, &spec, &bad));
    try std.testing.expectEqualStrings("--nope", bad);
    try std.testing.expectError(error.MissingValue, parse(arena.allocator(), &.{"--samples"}, &spec, &bad));
}

test "suggestions" {
    try std.testing.expectEqual(@as(usize, 2), editDistance("recrod", "record"));
    try std.testing.expectEqual(@as(usize, 0), editDistance("Diff", "diff"));
    try std.testing.expectEqualStrings("record", suggest("recrod", &.{ "scan", "record", "diff" }).?);
    try std.testing.expectEqual(@as(?[]const u8, null), suggest("zzzzzz", &.{ "scan", "diff" }));
}
