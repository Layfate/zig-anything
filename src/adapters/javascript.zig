//! JavaScript and TypeScript, run by Node.js.

const std = @import("std");
const adapter_mod = @import("../adapter.zig");
const config = @import("../config.zig");
const scan = @import("../scan.zig");
const lang = @import("../lang.zig");
const Allocator = std.mem.Allocator;

fn command(cfg: config.Config) []const []const u8 {
    return cfg.node;
}

fn scanJs(a: Allocator, src: []const u8) anyerror![]lang.Function {
    return scan.scanSource(a, .javascript, src);
}

/// Node's permission model: reads are allowed, writes only to the recorder's
/// scratch directory; child processes, workers, addons and WASI are denied.
fn sandboxArgs(a: Allocator, writable_dir: []const u8) anyerror![]const []const u8 {
    const out = try a.alloc([]const u8, 3);
    out[0] = "--permission";
    out[1] = "--allow-fs-read=*";
    out[2] = try std.fmt.allocPrint(a, "--allow-fs-write={s}", .{writable_dir});
    return out;
}

pub const adapter: adapter_mod.Adapter = .{
    .runtime = "node",
    .recorder_name = "record.mjs",
    .recorder = @embedFile("../assets/record.mjs"),
    .command = command,
    .env = &.{.{ .name = "NODE_NO_WARNINGS", .value = "1" }},
    .missing_hint = "install Node.js 22.6+ (TypeScript needs 23.6+), or set ZIG_ANYTHING_NODE / \"node\" in zig-anything.json",
    .scan = scanJs,
    .requires_export = true,
    .bridge = .node,
    .numbers_are_doubles = true,
    .sandbox_args = sandboxArgs,
};
