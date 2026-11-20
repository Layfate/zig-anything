//! End-to-end tests: drive the real zig-anything binary through complete
//! workflows on fixture projects in JavaScript, TypeScript and Python.
//!
//! usage: e2e <zig-anything-exe> <fixtures-dir> <examples-dir>
//! Requires `node` (22.6+, 23.6+ for TypeScript), Python 3 and `zig` on PATH.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

var gpa_state: std.heap.DebugAllocator(.{}) = .init;

const Ctx = struct {
    io: Io,
    a: Allocator,
    exe: []const u8,
    work: []const u8,
    failures: usize = 0,
    passed: usize = 0,
};

const Result = struct { code: u8, out: []const u8 };

fn cli(c: *Ctx, cwd: []const u8, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ c.exe, "--no-color" });
    try argv.appendSlice(c.a, args);
    const r = try std.process.run(c.a, c.io, .{ .argv = argv.items, .cwd = .{ .path = cwd }, .create_no_window = false });
    const code: u8 = switch (r.term) {
        .exited => |x| x,
        else => 255,
    };
    return .{ .code = code, .out = try std.mem.concat(c.a, u8, &.{ r.stdout, r.stderr }) };
}

fn check(c: *Ctx, name: []const u8, ok: bool, r: ?Result) void {
    if (ok) {
        c.passed += 1;
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        c.failures += 1;
        std.debug.print("  FAIL  {s}\n", .{name});
        if (r) |res| std.debug.print("        exit {d}; output:\n{s}\n", .{ res.code, res.out });
    }
}

fn expect(c: *Ctx, name: []const u8, r: Result, code: u8, needle: ?[]const u8) void {
    const has = if (needle) |n| std.mem.indexOf(u8, r.out, n) != null else true;
    check(c, name, r.code == code and has, r);
}

fn copyTree(io: Io, a: Allocator, src: []const u8, dst: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(a);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        const to = try std.fs.path.join(a, &.{ dst, e.path });
        switch (e.kind) {
            .directory => {
                // Skip build outputs and scratch state from local runs.
                const skip = [_][]const u8{ ".zig-cache", "zig-out", "zig-out-fast", ".za", "node_modules", "__pycache__" };
                var skipped = false;
                for (skip) |name| skipped = skipped or std.mem.eql(u8, e.basename, name);
                if (skipped) continue;
                try cwd.createDirPath(io, to);
                try walker.enter(io, e);
            },
            .file => {
                if (std.fs.path.dirname(to)) |d| try cwd.createDirPath(io, d);
                try Io.Dir.copyFile(dir, e.path, cwd, to, io, .{});
            },
            else => {},
        }
    }
}

fn copyFile(c: *Ctx, from: []const u8, to: []const u8) !void {
    try Io.Dir.copyFile(Io.Dir.cwd(), from, Io.Dir.cwd(), to, c.io, .{});
}

fn join(c: *Ctx, parts: []const []const u8) []const u8 {
    return std.fs.path.join(c.a, parts) catch @panic("OOM");
}

fn countLines(c: *Ctx, path: []const u8) usize {
    const text = Io.Dir.cwd().readFileAlloc(c.io, path, c.a, .unlimited) catch return 0;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |_| n += 1;
    return n;
}

const Scenario = struct {
    label: []const u8,
    source: []const u8,
    function: []const u8,
    solution: []const u8,
};

fn workflow(c: *Ctx, s: Scenario) !void {
    std.debug.print("{s}\n", .{s.label});
    const unit = join(c, &.{ "zig-port", s.function });
    var r = try cli(c, c.work, &.{ "init", s.source, s.function });
    expect(c, "init creates the unit", r, 0, "created");
    r = try cli(c, c.work, &.{ "init", s.source, s.function });
    expect(c, "init refuses to overwrite", r, 3, "already exists");

    r = try cli(c, c.work, &.{ "record", s.function });
    expect(c, "record succeeds", r, 0, "recorded");
    const cases_path = join(c, &.{ c.work, unit, "cases.jsonl" });
    const n_cases = countLines(c, cases_path);
    check(c, "cases.jsonl has cases", n_cases > 10, null);

    r = try cli(c, c.work, &.{ "diff", s.function });
    // The stub returns error.NotImplemented, so only throwing cases match.
    expect(c, "diff fails on the stub", r, 1, "cases match");

    r = try cli(c, c.work, &.{ "gate", s.function });
    expect(c, "gate fails on the stub", r, 1, "NOT DONE");

    try copyFile(c, join(c, &.{ c.work, "solutions", s.solution }), join(c, &.{ c.work, unit, "src", "port.zig" }));
    r = try cli(c, c.work, &.{ "diff", s.function });
    const all = try std.fmt.allocPrint(c.a, "{d}/{d} cases match", .{ n_cases, n_cases });
    expect(c, "diff passes with a correct port", r, 0, all);

    r = try cli(c, c.work, &.{ "gate", s.function });
    expect(c, "gate passes", r, 0, "PASSED");

    // Re-recording with the same seed must be byte-identical.
    const before = try Io.Dir.cwd().readFileAlloc(c.io, cases_path, c.a, .unlimited);
    r = try cli(c, c.work, &.{ "record", s.function });
    const after = try Io.Dir.cwd().readFileAlloc(c.io, cases_path, c.a, .unlimited);
    check(c, "recording is reproducible", r.code == 0 and std.mem.eql(u8, before, after), r);
}

fn regressions(c: *Ctx) !void {
    std.debug.print("regressions and error handling\n", .{});
    const unit_src = join(c, &.{ c.work, "zig-port", "slugify", "src", "port.zig" });

    try copyFile(c, join(c, &.{ c.work, "solutions", "slugify_wrong.zig" }), unit_src);
    var r = try cli(c, c.work, &.{ "diff", "slugify", "--limit", "1" });
    expect(c, "a wrong port is caught", r, 1, "different value");
    check(c, "mismatch report shows expected and actual", std.mem.indexOf(u8, r.out, "expected") != null and std.mem.indexOf(u8, r.out, "got") != null, r);

    r = try cli(c, c.work, &.{ "diff", "slugify", "--json", "--limit", "1" });
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, c.a, std.mem.trim(u8, r.out, " \r\n"), .{}) catch null;
    check(c, "diff --json is valid JSON", r.code == 1 and parsed != null and parsed.? == .object and parsed.?.object.get("passed").?.bool == false, r);

    try copyFile(c, join(c, &.{ c.work, "solutions", "slugify_crash.zig" }), unit_src);
    r = try cli(c, c.work, &.{ "diff", "slugify", "--optimize", "safe" });
    expect(c, "a crashing port is reported", r, 1, "crashed");

    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = unit_src, .data = "pub fn slugify(x: []const u8) []const u8 { return x + 1; }\n" });
    r = try cli(c, c.work, &.{ "diff", "slugify" });
    expect(c, "compile errors are shown", r, 1, "build failed");

    try copyFile(c, join(c, &.{ c.work, "solutions", "slugify.zig" }), unit_src);

    // User-provided inputs are recorded alongside generated ones.
    const inputs = join(c, &.{ c.work, "zig-port", "slugify", "inputs.jsonl" });
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = inputs, .data = "[\"Custom Input 42\"]\n{\"args\": [\"__x__\"]}\n" });
    r = try cli(c, c.work, &.{ "record", "slugify", "--no-generate", "--no-verify" });
    expect(c, "record --no-generate uses inputs.jsonl", r, 0, "2 inputs (2 from inputs.jsonl, 0 generated)");
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = inputs, .data = "[1, 2]\n" });
    r = try cli(c, c.work, &.{ "record", "slugify", "--no-generate" });
    expect(c, "arity errors in inputs.jsonl are explained", r, 3, "takes 1");
    try Io.Dir.cwd().deleteFile(c.io, inputs);
    r = try cli(c, c.work, &.{ "record", "slugify" });
    expect(c, "re-record after inputs change", r, 0, "recorded");

    r = try cli(c, c.work, &.{"frobnicate"});
    expect(c, "unknown command is a usage error", r, 2, "unknown command");
    r = try cli(c, c.work, &.{"recrod"});
    expect(c, "typos get a suggestion", r, 2, "did you mean `record`");
    r = try cli(c, c.work, &.{ "diff", "slugify", "--tolerence", "1" });
    expect(c, "unknown flags get a suggestion", r, 2, "did you mean `--tolerance`");
    r = try cli(c, c.work, &.{ "diff", "nope" });
    expect(c, "missing units are explained", r, 3, "no port unit");
    r = try cli(c, c.work, &.{ "init", "js/textutil.mjs", "slugifyy" });
    expect(c, "unknown functions get a suggestion", r, 3, "did you mean `slugify`");
    r = try cli(c, c.work, &.{ "init", "js/textutil.mjs", "slugify", "--out", "zig-port/other" });
    expect(c, "init --out picks the directory", r, 0, "created");
    r = try cli(c, c.work, &.{ "record", "slugify", "--samples", "lots" });
    expect(c, "bad numbers are rejected", r, 3, "whole number");
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = join(c, &.{ c.work, "zig-anything.json" }), .data = "{\"sampels\": 3}" });
    r = try cli(c, c.work, &.{"status"});
    expect(c, "config typos are rejected", r, 3, "unknown field");
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = join(c, &.{ c.work, "zig-anything.json" }), .data = "{\"samples\": 3}" });

    r = try cli(c, c.work, &.{ "scan", ".", "--json" });
    const scan_json = std.json.parseFromSliceLeaky(std.json.Value, c.a, std.mem.trim(u8, r.out, " \r\n"), .{}) catch null;
    check(c, "scan --json is valid JSON", r.code == 0 and scan_json != null and scan_json.? == .array and scan_json.?.array.items.len >= 3, r);

    r = try cli(c, c.work, &.{ "status", "--json" });
    const status_json = std.json.parseFromSliceLeaky(std.json.Value, c.a, std.mem.trim(u8, r.out, " \r\n"), .{}) catch null;
    var passing: usize = 0;
    if (status_json) |sj| if (sj == .array) for (sj.array.items) |u| {
        if (std.mem.eql(u8, u.object.get("state").?.string, "passing")) passing += 1;
    };
    check(c, "status lists passing units", r.code == 0 and passing >= 2, r);

    r = try cli(c, c.work, &.{"--version"});
    expect(c, "--version", r, 0, "zig-anything ");
    r = try cli(c, c.work, &.{ "help", "diff" });
    expect(c, "help <command>", r, 0, "--strict-errors");
}

fn mcp(c: *Ctx) !void {
    std.debug.print("mcp server\n", .{});
    var child = try std.process.spawn(c.io, .{
        .argv = &.{ c.exe, "mcp" },
        .cwd = .{ .path = c.work },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(c.io);
    const requests =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"zig_anything_status","arguments":{}}}
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"zig_anything_diff","arguments":{}}}
        \\{"jsonrpc":"2.0","id":5,"method":"nope"}
        \\not json
        \\
    ;
    try child.stdin.?.writeStreamingAll(c.io, requests);
    child.stdin.?.close(c.io);
    child.stdin = null;
    var buf: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(c.io, &buf);
    const out = try reader.interface.allocRemaining(c.a, .unlimited);
    _ = try child.wait(c.io);

    var ids: [6]bool = @splat(false);
    var it = std.mem.tokenizeScalar(u8, out, '\n');
    var all_valid = true;
    var tool_count: usize = 0;
    var status_ok = false;
    var diff_is_error = false;
    var method_not_found = false;
    var parse_error = false;
    while (it.next()) |line| {
        const v = std.json.parseFromSliceLeaky(std.json.Value, c.a, line, .{}) catch {
            all_valid = false;
            continue;
        };
        const id = v.object.get("id") orelse continue;
        if (id == .null) {
            parse_error = v.object.get("error") != null;
            continue;
        }
        const n: usize = @intCast(id.integer);
        if (n < ids.len) ids[n] = true;
        const result = v.object.get("result");
        switch (n) {
            2 => tool_count = result.?.object.get("tools").?.array.items.len,
            3 => status_ok = !result.?.object.get("isError").?.bool,
            4 => diff_is_error = result.?.object.get("isError").?.bool,
            5 => method_not_found = v.object.get("error").?.object.get("code").?.integer == -32601,
            else => {},
        }
    }
    check(c, "every response is JSON", all_valid, .{ .code = 0, .out = out });
    check(c, "initialize answered", ids[1], .{ .code = 0, .out = out });
    check(c, "tools/list returns 8 tools", tool_count == 8, .{ .code = 0, .out = out });
    check(c, "tools/call runs a command", status_ok, .{ .code = 0, .out = out });
    check(c, "missing tool arguments are tool errors", diff_is_error, .{ .code = 0, .out = out });
    check(c, "unknown methods are rejected", method_not_found, .{ .code = 0, .out = out });
    check(c, "malformed JSON gets a parse error", parse_error, .{ .code = 0, .out = out });
}

fn examples(c: *Ctx, examples_dir: []const u8) !void {
    std.debug.print("examples\n", .{});
    var dir = Io.Dir.cwd().openDir(c.io, examples_dir, .{ .iterate = true }) catch return;
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |e| {
        if (e.kind != .directory) continue;
        const dst = join(c, &.{ c.work, "examples", e.name });
        try copyTree(c.io, c.a, join(c, &.{ examples_dir, e.name }), dst);
        // Every unit committed in an example must pass its gate as shipped.
        const units_root = join(c, &.{ dst, "zig-port" });
        var ud = Io.Dir.cwd().openDir(c.io, units_root, .{ .iterate = true }) catch continue;
        defer ud.close(c.io);
        var uit = ud.iterate();
        while (try uit.next(c.io)) |u| {
            if (u.kind != .directory) continue;
            const r = try cli(c, dst, &.{ "gate", u.name });
            const label = try std.fmt.allocPrint(c.a, "example {s}/{s} passes its gate", .{ e.name, u.name });
            expect(c, label, r, 0, "PASSED");
        }
    }
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 4) {
        std.debug.print("usage: e2e <zig-anything-exe> <fixtures-dir> <examples-dir>\n", .{});
        return 2;
    }
    const cwd = try std.process.currentPathAlloc(io, a);
    const exe = try std.fs.path.resolveAlloc(a, &.{ cwd, args[1] });
    const fixtures = try std.fs.path.resolveAlloc(a, &.{ cwd, args[2] });
    const examples_dir = try std.fs.path.resolveAlloc(a, &.{ cwd, args[3] });
    const work = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "e2e-work" });
    Io.Dir.cwd().deleteTree(io, work) catch {};
    try Io.Dir.cwd().createDirPath(io, work);
    try copyTree(io, a, fixtures, work);

    var c: Ctx = .{ .io = io, .a = a, .exe = exe, .work = work };
    try workflow(&c, .{ .label = "javascript: slugify", .source = "js/textutil.mjs", .function = "slugify", .solution = "slugify.zig" });
    try workflow(&c, .{ .label = "typescript: mean", .source = "ts/stats.ts", .function = "mean", .solution = "mean.zig" });
    try workflow(&c, .{ .label = "python: digit_sum", .source = "py/mathutil.py", .function = "digit_sum", .solution = "digit_sum.zig" });
    try regressions(&c);
    try mcp(&c);
    try examples(&c, examples_dir);

    std.debug.print("\n{d} passed, {d} failed\n", .{ c.passed, c.failures });
    if (c.failures == 0) Io.Dir.cwd().deleteTree(io, work) catch {};
    return if (c.failures == 0) 0 else 1;
}
