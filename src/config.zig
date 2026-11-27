//! `zig-anything.json`: optional project configuration, found by walking up
//! from the directory a command operates on. Environment variables override
//! runtime commands: ZIG_ANYTHING_NODE, ZIG_ANYTHING_PYTHON, ZIG.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const file_name = "zig-anything.json";

const default_python: []const []const u8 = if (builtin.os.tag == .windows) &.{"python"} else &.{"python3"};

pub const Config = struct {
    /// Where `init` creates port units, relative to the config file.
    units_dir: []const u8 = "zig-port",
    /// Command (and leading arguments) used to run JavaScript/TypeScript.
    node: []const []const u8 = &.{"node"},
    /// Command (and leading arguments) used to run Python.
    python: []const []const u8 = default_python,
    /// The Zig compiler used to build port units.
    zig: []const u8 = "zig",
    /// Random cases generated on top of edge cases by `record`.
    samples: u32 = 64,
    /// Seed for random case generation (recordings are reproducible).
    seed: u64 = 1,
    /// Upper bound on generated cases per unit.
    max_cases: u32 = 2000,
    /// Seconds before a runtime or build process is stopped.
    timeout: u32 = 300,
    /// Float tolerance used by `diff` (0 = exact).
    tolerance: f64 = 0,
    /// Run the original with the side-effect guard on (see `record --sandbox`).
    sandbox: bool = false,
    /// Record argument mutation and printed output, and make `diff` compare
    /// them (see `record --effects`).
    effects: bool = false,
    /// Parallel processes for recording and replay (0 = one per CPU core).
    jobs: u32 = 0,
    /// Skip `zig build` when nothing it reads has changed.
    cache: bool = true,
    /// Extra environment variables for the original, e.g. {"TZ": "UTC"}.
    env: std.json.ArrayHashMap([]const u8) = .{},
};

pub const Loaded = struct {
    config: Config,
    /// Directory containing zig-anything.json, or the start directory.
    root: []const u8,
    /// Absolute path of the config file, if one was found.
    path: ?[]const u8,
};

/// Finds and parses the nearest zig-anything.json at or above `start_dir`.
pub fn load(c: *cli.Ctx, start_dir: []const u8) cli.Reported!Loaded {
    var dir: []const u8 = start_dir;
    while (true) {
        const candidate = std.fs.path.join(c.arena, &.{ dir, file_name }) catch return c.fail("out of memory", .{});
        if (Io.Dir.cwd().readFileAlloc(c.io, candidate, c.arena, .limited(1 << 20))) |text| {
            const cfg = parse(c.arena, text) catch |err| {
                return c.fail("{s}: {s}", .{ candidate, switch (err) {
                    error.UnknownField => "unknown field (see `zig-anything help config`)",
                    error.OutOfMemory => "out of memory",
                    else => "invalid JSON or wrong value type",
                } });
            };
            return .{ .config = applyEnv(c, cfg), .root = dir, .path = candidate };
        } else |_| {}
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return .{ .config = applyEnv(c, .{}), .root = start_dir, .path = null };
}

pub fn parse(a: Allocator, text: []const u8) !Config {
    return std.json.parseFromSliceLeaky(Config, a, text, .{ .allocate = .alloc_always });
}

fn splitCommand(a: Allocator, s: []const u8) []const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |p| parts.append(a, p) catch return &.{s};
    return parts.items;
}

fn applyEnv(c: *cli.Ctx, cfg_in: Config) Config {
    var cfg = cfg_in;
    if (c.env.get("ZIG_ANYTHING_NODE")) |v| if (v.len > 0) {
        cfg.node = splitCommand(c.arena, v);
    };
    if (c.env.get("ZIG_ANYTHING_PYTHON")) |v| if (v.len > 0) {
        cfg.python = splitCommand(c.arena, v);
    };
    if (c.env.get("ZIG")) |v| if (v.len > 0) {
        cfg.zig = v;
    };
    return cfg;
}

test "parse config with defaults and overrides" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), "{\"samples\": 10, \"node\": [\"node\", \"--import\", \"tsx\"]}");
    try std.testing.expectEqual(@as(u32, 10), cfg.samples);
    try std.testing.expectEqual(@as(usize, 3), cfg.node.len);
    try std.testing.expectEqualStrings("zig-port", cfg.units_dir);
    try std.testing.expectError(error.UnknownField, parse(arena.allocator(), "{\"sample\": 10}"));
    const env = try parse(arena.allocator(), "{\"env\": {\"TZ\": \"UTC\"}, \"sandbox\": true, \"jobs\": 2}");
    try std.testing.expectEqualStrings("UTC", env.env.map.get("TZ").?);
    try std.testing.expect(env.sandbox and env.jobs == 2 and env.cache);
}
