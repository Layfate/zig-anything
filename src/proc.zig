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
    /// File to feed to the child's stdin (default: no stdin).
    stdin_path: ?[]const u8 = null,
};

const Captured = struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8 };

/// std.process.run, plus an optional stdin file.
fn spawnCapture(c: *cli.Ctx, argv: []const []const u8, opts: Options) SpawnError!Captured {
    const io = c.io;
    var stdin_file: ?Io.File = null;
    if (opts.stdin_path) |p| stdin_file = try Io.Dir.cwd().openFile(io, p, .{});
    defer if (stdin_file) |f| f.close(io);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (opts.cwd) |d| .{ .path = d } else .inherit,
        .environ_map = opts.environ_map,
        // The default for std.process.run (true) makes Windows start a
        // hidden console host for every child: ~9 ms per process.
        .create_no_window = false,
        .stdin = if (stdin_file) |f| .{ .file = f } else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    var buffers: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(c.arena, io, buffers.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    const timeout: Io.Timeout = if (opts.timeout_s == 0) .none else .{ .duration = .{
        .raw = .fromSeconds(opts.timeout_s),
        .clock = .awake,
    } };
    const deadline: Io.Timeout = if (timeout.toTimestamp(io)) |d| .{ .deadline = d } else .none;
    while (mr.fill(4096, deadline)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try mr.checkAnyError();
    const term = try child.wait(io);
    return .{ .term = term, .stdout = try mr.toOwnedSlice(0), .stderr = try mr.toOwnedSlice(1) };
}

pub const RunError = SpawnError;
const SpawnError = std.process.SpawnError || Io.File.MultiReader.UnendingError || Io.Timeout.Error ||
    Io.File.OpenError || error{StreamTooLong};

/// Runs `argv` to completion without printing anything. Safe to call from
/// concurrent tasks (the arena and the Io implementation are threadsafe).
pub fn runQuiet(c: *cli.Ctx, argv: []const []const u8, opts: Options) RunError!Result {
    const start = Io.Timestamp.now(c.io, .awake);
    const r = try spawnCapture(c, argv, opts);
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

/// Turns a failure to start or finish a process into a user-facing error.
pub fn reportRunError(c: *cli.Ctx, argv: []const []const u8, opts: Options, err: RunError) cli.Reported {
    switch (err) {
        error.FileNotFound, error.InvalidExe => {
            if (opts.stdin_path) |p| Io.Dir.cwd().access(c.io, p, .{}) catch return c.fail("cannot open stdin file {s}", .{p});
            if (opts.missing_hint) |h| c.hint("{s}", .{h});
            return c.fail("could not start `{s}`: not found on PATH", .{argv[0]});
        },
        error.Timeout => return c.fail("`{s}` did not finish within {d}s (raise \"timeout\" in zig-anything.json)", .{ argv[0], opts.timeout_s }),
        else => return c.fail("could not run `{s}`: {s}", .{ argv[0], @errorName(err) }),
    }
}

/// Runs `argv` to completion and captures its output. Failing to start the
/// process (missing executable, timeout) is reported as a user-facing error.
pub fn run(c: *cli.Ctx, argv: []const []const u8, opts: Options) cli.Reported!Result {
    return runQuiet(c, argv, opts) catch |err| reportRunError(c, argv, opts, err);
}

pub const Job = struct {
    argv: []const []const u8,
    opts: Options,
};

/// Runs every job concurrently and returns each job's own result or error,
/// without printing anything.
pub fn runManyQuiet(c: *cli.Ctx, jobs: []const Job) cli.Reported![]RunError!Result {
    const results = c.arena.alloc(RunError!Result, jobs.len) catch return c.fail("out of memory", .{});
    const Task = struct {
        fn go(cc: *cli.Ctx, job: Job, slot: *(RunError!Result)) void {
            slot.* = runQuiet(cc, job.argv, job.opts);
        }
    };
    var group: Io.Group = .init;
    for (jobs, results) |job, *slot| {
        group.concurrent(c.io, Task.go, .{ c, job, slot }) catch Task.go(c, job, slot);
    }
    group.await(c.io) catch return c.fail("interrupted", .{});
    return results;
}

/// Runs every job concurrently (falling back to one at a time when the Io
/// implementation cannot run tasks concurrently) and waits for all of them.
/// The first job that could not be run is reported as a user-facing error.
pub fn runMany(c: *cli.Ctx, jobs: []const Job) cli.Reported![]Result {
    const results = try runManyQuiet(c, jobs);
    const out = c.arena.alloc(Result, jobs.len) catch return c.fail("out of memory", .{});
    for (results, jobs, out) |r, job, *o| {
        o.* = r catch |err| return reportRunError(c, job.argv, job.opts, err);
    }
    return out;
}

/// Finds `name` the way a shell would: as given when it contains a path
/// separator, else in each PATH directory (with PATHEXT on Windows).
pub fn findExecutable(c: *cli.Ctx, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return name;
    const path_var = c.env.get("PATH") orelse c.env.get("Path") orelse return null;
    const exts: []const []const u8 = if (builtin.os.tag == .windows) &.{ ".exe", ".cmd", ".bat", "" } else &.{""};
    var it = std.mem.tokenizeScalar(u8, path_var, std.fs.path.delimiter);
    while (it.next()) |dir| {
        for (exts) |ext| {
            const full = std.fmt.allocPrint(c.arena, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, name, ext }) catch return null;
            Io.Dir.cwd().access(c.io, full, .{}) catch continue;
            return full;
        }
    }
    return null;
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
