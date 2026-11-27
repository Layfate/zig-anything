//! Running the original function through its language runtime (Node or
//! Python) via the embedded recorder scripts. Everything language-specific
//! comes from the unit's adapter (adapter.zig).
//!
//! Recorder protocol: `<runtime> <script> <mode> <source> <function> <cases> <out> <iterations>`
//! where mode is `run`, `bench` or `cover`. Optional behavior is switched on
//! with environment variables so the positional protocol never changes:
//!
//!   ZA_SANDBOX=1        block writes outside ZA_WRITABLE, subprocesses and
//!                       network access while user code runs
//!   ZA_WRITABLE=<dir>   the one directory the recorder may write to
//!   ZA_EFFECTS=1        also record argument mutation and printed output

const std = @import("std");
const cli = @import("cli.zig");
const proc = @import("proc.zig");
const adapter = @import("adapter.zig");
const unit_mod = @import("unit.zig");
const Io = std.Io;

pub const Mode = enum { run, bench, cover };

pub const InvokeOptions = struct {
    /// Load the function from this file instead of the unit's source (used to
    /// replay cases through a generated bridge or an integrated source).
    source: ?[]const u8 = null,
    iterations: u64 = 1,
    sandbox: bool = false,
    effects: bool = false,
};

pub fn adapterOf(u: unit_mod.Unit) *const adapter.Adapter {
    return adapter.forLanguage(u.manifest.lang_());
}

pub fn runtimeLabel(u: unit_mod.Unit) []const u8 {
    return adapterOf(u).runtime;
}

/// Writes the embedded recorder into the unit's scratch directory and
/// returns the process job that runs it. Nothing is started yet, so several
/// jobs can be run concurrently with `proc.runMany`.
pub fn prepare(c: *cli.Ctx, u: unit_mod.Unit, mode: Mode, cases_path: []const u8, out_path: []const u8, o: InvokeOptions) cli.Reported!proc.Job {
    try u.ensureWorkDir(c);
    const ad = adapterOf(u);
    const source = o.source orelse u.source_abs;
    const script_path = u.workPath(c.arena, ad.recorder_name);
    // Rewrite only when it changed: concurrent jobs share the file.
    const current = Io.Dir.cwd().readFileAlloc(c.io, script_path, c.arena, .limited(1 << 20)) catch "";
    if (!std.mem.eql(u8, current, ad.recorder)) {
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = script_path, .data = ad.recorder }) catch |err|
            return c.fail("cannot write {s}: {s}", .{ script_path, @errorName(err) });
    }

    Io.Dir.cwd().access(c.io, source, .{}) catch
        return c.fail("source file {s} does not exist", .{c.rel(source)});

    const work = u.path(c.arena, unit_mod.work_dir);
    const iters = std.fmt.allocPrint(c.arena, "{d}", .{o.iterations}) catch return c.fail("out of memory", .{});
    const sandbox_args: []const []const u8 = if (o.sandbox)
        ad.sandbox_args(c.arena, work) catch return c.fail("out of memory", .{})
    else
        &.{};
    const tail = [_][]const u8{ script_path, @tagName(mode), source, u.manifest.function, cases_path, out_path, iters };
    const prefix = ad.command(u.cfg.config);
    const argv = std.mem.concat(c.arena, []const u8, &.{ prefix[0..1], sandbox_args, prefix[1..], &tail }) catch return c.fail("out of memory", .{});

    const env = c.arena.create(std.process.Environ.Map) catch return c.fail("out of memory", .{});
    env.* = c.env.clone(c.arena) catch return c.fail("out of memory", .{});
    for (ad.env) |e| env.put(e.name, e.value) catch {};
    for (u.cfg.config.env.map.keys(), u.cfg.config.env.map.values()) |k, v| env.put(k, v) catch {};
    if (o.sandbox) {
        env.put("ZA_SANDBOX", "1") catch {};
        env.put("ZA_WRITABLE", work) catch {};
    }
    if (o.effects) env.put("ZA_EFFECTS", "1") catch {};
    return .{ .argv = argv, .opts = .{
        .cwd = std.fs.path.dirname(source),
        .timeout_s = u.cfg.config.timeout,
        .environ_map = env,
        .missing_hint = ad.missing_hint,
    } };
}

/// Runs the recorder for `u` over `cases_path`, writing results to
/// `out_path`. Returns the process result (stderr is useful on failure).
pub fn invoke(c: *cli.Ctx, u: unit_mod.Unit, mode: Mode, cases_path: []const u8, out_path: []const u8, o: InvokeOptions) cli.Reported!proc.Result {
    const job = try prepare(c, u, mode, cases_path, out_path, o);
    return proc.run(c, job.argv, job.opts);
}

/// Prints the tail of a failed recorder run and returns error.Reported.
pub fn reportFailure(c: *cli.Ctx, u: unit_mod.Unit, r: proc.Result) cli.Reported {
    const tail_len = @min(r.stderr.len, 4000);
    c.out.flush() catch {};
    c.err.writeAll(r.stderr[r.stderr.len - tail_len ..]) catch {};
    if (tail_len > 0 and r.stderr[r.stderr.len - 1] != '\n') c.err.writeByte('\n') catch {};
    if (std.mem.indexOf(u8, r.stderr, "bad option: --permission") != null or std.mem.indexOf(u8, r.stderr, "--allow-fs-") != null)
        c.hint("the sandbox needs Node.js 22+ (its permission model); upgrade Node or record without --sandbox", .{});
    return c.fail("{s} recorder failed (exit code {?d}) for {s}", .{ runtimeLabel(u), r.exit_code, c.rel(u.source_abs) });
}
