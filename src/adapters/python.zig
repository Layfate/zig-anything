//! Python, run by CPython 3.8+.

const std = @import("std");
const adapter_mod = @import("../adapter.zig");
const config = @import("../config.zig");
const scan = @import("../scan.zig");
const lang = @import("../lang.zig");
const Allocator = std.mem.Allocator;

fn command(cfg: config.Config) []const []const u8 {
    return cfg.python;
}

fn scanPy(a: Allocator, src: []const u8) anyerror![]lang.Function {
    return scan.scanSource(a, .python, src);
}

/// The Python guard is an audit hook installed by the recorder itself
/// (see assets/record.py); no interpreter flags are needed.
fn sandboxArgs(_: Allocator, _: []const u8) anyerror![]const []const u8 {
    return &.{};
}

pub const adapter: adapter_mod.Adapter = .{
    .runtime = "python",
    .recorder_name = "record.py",
    .recorder = @embedFile("../assets/record.py"),
    .command = command,
    // Stable set/dict ordering, UTF-8 I/O, and no __pycache__ in the user's tree.
    .env = &.{
        .{ .name = "PYTHONHASHSEED", .value = "0" },
        .{ .name = "PYTHONIOENCODING", .value = "utf-8" },
        .{ .name = "PYTHONUTF8", .value = "1" },
        .{ .name = "PYTHONDONTWRITEBYTECODE", .value = "1" },
    },
    .missing_hint = "install Python 3.8+, or set ZIG_ANYTHING_PYTHON / \"python\" in zig-anything.json",
    .scan = scanPy,
    .requires_export = false,
    .bridge = .python,
    .numbers_are_doubles = false,
    .sandbox_args = sandboxArgs,
};
