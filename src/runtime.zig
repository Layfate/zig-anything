//! Running the original function through its language runtime (Node or
//! Python) via the embedded recorder scripts.

const std = @import("std");
const cli = @import("cli.zig");
const proc = @import("proc.zig");
const unit_mod = @import("unit.zig");
const Io = std.Io;

const js_recorder = @embedFile("assets/record.mjs");
const py_recorder = @embedFile("assets/record.py");

pub const Mode = enum { run, bench };

pub fn runtimeLabel(u: unit_mod.Unit) []const u8 {
    return if (u.manifest.language.isJs()) "node" else "python";
}

/// Runs the recorder for `u` over `cases_path`, writing results to
/// `out_path`. Returns the process result (stderr is useful on failure).
pub fn invoke(c: *cli.Ctx, u: unit_mod.Unit, mode: Mode, cases_path: []const u8, out_path: []const u8, iterations: u64) cli.Reported!proc.Result {
    try u.ensureWorkDir(c);
    const is_js = u.manifest.language.isJs();
    const script_path = u.workPath(c.arena, if (is_js) "record.mjs" else "record.py");
    Io.Dir.cwd().writeFile(c.io, .{ .sub_path = script_path, .data = if (is_js) js_recorder else py_recorder }) catch |err|
        return c.fail("cannot write {s}: {s}", .{ script_path, @errorName(err) });

    Io.Dir.cwd().access(c.io, u.source_abs, .{}) catch
        return c.fail("source file {s} (from unit.json) does not exist", .{c.rel(u.source_abs)});

    const iters = std.fmt.allocPrint(c.arena, "{d}", .{iterations}) catch return c.fail("out of memory", .{});
    const prefix = if (is_js) u.cfg.config.node else u.cfg.config.python;
    const argv = proc.command(c, prefix, &.{ script_path, @tagName(mode), u.source_abs, u.manifest.function, cases_path, out_path, iters });

    var env = c.env.clone(c.arena) catch return c.fail("out of memory", .{});
    if (!is_js) {
        // Stable set/dict ordering, UTF-8 I/O, and no __pycache__ in the user's tree.
        env.put("PYTHONHASHSEED", "0") catch {};
        env.put("PYTHONIOENCODING", "utf-8") catch {};
        env.put("PYTHONUTF8", "1") catch {};
        env.put("PYTHONDONTWRITEBYTECODE", "1") catch {};
    } else {
        env.put("NODE_NO_WARNINGS", "1") catch {};
    }
    return proc.run(c, argv, .{
        .cwd = std.fs.path.dirname(u.source_abs),
        .timeout_s = u.cfg.config.timeout,
        .environ_map = &env,
        .missing_hint = if (is_js)
            "install Node.js 22.6+ (TypeScript needs 23.6+), or set ZIG_ANYTHING_NODE / \"node\" in zig-anything.json"
        else
            "install Python 3.8+, or set ZIG_ANYTHING_PYTHON / \"python\" in zig-anything.json",
    });
}

/// Prints the tail of a failed recorder run and returns error.Reported.
pub fn reportFailure(c: *cli.Ctx, u: unit_mod.Unit, r: proc.Result) cli.Reported {
    const tail_len = @min(r.stderr.len, 4000);
    c.out.flush() catch {};
    c.err.writeAll(r.stderr[r.stderr.len - tail_len ..]) catch {};
    if (tail_len > 0 and r.stderr[r.stderr.len - 1] != '\n') c.err.writeByte('\n') catch {};
    return c.fail("{s} recorder failed (exit code {?d}) for {s}", .{ runtimeLabel(u), r.exit_code, c.rel(u.source_abs) });
}
