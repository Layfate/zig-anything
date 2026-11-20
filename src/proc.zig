//! Child-process helpers with friendly errors for missing tools.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const Io = std.Io;

pub const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

pub const Result = struct {
    ok: bool,
    exit_code: ?u8,
    stdout: []u8,
    stderr: []u8,
    /// Wall-clock nanoseconds from spawn to exit.
    ns: u64,
};

pub const Options = struct {
    cwd: ?[]const u8 = null,
    timeout_s: u32 = 300,
    environ_map: ?*const std.process.Environ.Map = null,
    /// What to tell the user if the executable cannot be started.
    missing_hint: ?[]const u8 = null,
};

/// Runs `argv` to completion and captures its output. Failing to start the
/// process (missing executable, timeout) is reported as a user-facing error.
pub fn run(c: *cli.Ctx, argv: []const []const u8, opts: Options) cli.Reported!Result {
    const start = Io.Timestamp.now(c.io, .awake);
    const r = std.process.run(c.arena, c.io, .{
        .argv = argv,
        .cwd = if (opts.cwd) |d| .{ .path = d } else .inherit,
        .environ_map = opts.environ_map,
        // The default (true) makes Windows start a hidden console host for
        // every child, which costs ~9 ms per process and skews `bench`.
        .create_no_window = false,
        .timeout = if (opts.timeout_s == 0) .none else .{ .duration = .{
            .raw = .fromSeconds(opts.timeout_s),
            .clock = .awake,
        } },
    }) catch |err| switch (err) {
        error.FileNotFound, error.InvalidExe => {
            if (opts.missing_hint) |h| c.hint("{s}", .{h});
            return c.fail("could not start `{s}`: not found on PATH", .{argv[0]});
        },
        error.Timeout => return c.fail("`{s}` did not finish within {d}s (raise \"timeout\" in zig-anything.json)", .{ argv[0], opts.timeout_s }),
        else => return c.fail("could not run `{s}`: {s}", .{ argv[0], @errorName(err) }),
    };
    const ns: u64 = @intCast(@max(0, start.durationTo(Io.Timestamp.now(c.io, .awake)).nanoseconds));
    return .{
        .ok = r.term.success(),
        .exit_code = switch (r.term) {
            .exited => |code| code,
            else => null,
        },
        .stdout = r.stdout,
        .stderr = r.stderr,
        .ns = ns,
    };
}

/// Appends `extra` to a configured command prefix.
pub fn command(c: *cli.Ctx, prefix: []const []const u8, extra: []const []const u8) []const []const u8 {
    const out = c.arena.alloc([]const u8, prefix.len + extra.len) catch return extra;
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..], extra);
    return out;
}

/// Formats a duration in nanoseconds with a sensible unit.
pub fn fmtNs(buf: []u8, ns: f64) []const u8 {
    if (ns < 1_000) return std.fmt.bufPrint(buf, "{d:.1} ns", .{ns}) catch "?";
    if (ns < 1_000_000) return std.fmt.bufPrint(buf, "{d:.2} µs", .{ns / 1_000}) catch "?";
    if (ns < 1_000_000_000) return std.fmt.bufPrint(buf, "{d:.2} ms", .{ns / 1_000_000}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.2} s", .{ns / 1_000_000_000}) catch "?";
}

test "fmtNs picks units" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12.0 ns", fmtNs(&buf, 12));
    try std.testing.expectEqualStrings("1.50 µs", fmtNs(&buf, 1500));
    try std.testing.expectEqualStrings("2.00 ms", fmtNs(&buf, 2_000_000));
}
