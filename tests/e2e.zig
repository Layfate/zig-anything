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

    r = try cli(c, c.work, &.{ "bridge", s.function });
    expect(c, "bridge refuses a stub", r, 3, "TODO(zig-anything)");

    try copyFile(c, join(c, &.{ c.work, "solutions", s.solution }), join(c, &.{ c.work, unit, "src", "port.zig" }));
    r = try cli(c, c.work, &.{ "diff", s.function });
    const all = try std.fmt.allocPrint(c.a, "{d}/{d} cases match", .{ n_cases, n_cases });
    expect(c, "diff passes with a correct port", r, 0, all);

    r = try cli(c, c.work, &.{ "gate", s.function });
    expect(c, "gate passes", r, 0, "PASSED");

    r = try cli(c, c.work, &.{ "bridge", s.function });
    const through = try std.fmt.allocPrint(c.a, "{d}/{d} recorded cases match through the bridge", .{ n_cases, n_cases });
    expect(c, "bridge builds and replays every case through the binding", r, 0, through);
    const is_py = std.mem.endsWith(u8, s.source, ".py");
    const binding = join(c, &.{ c.work, unit, "bridge", if (is_py) "port.py" else "index.mjs" });
    check(c, "bridge writes the binding", (Io.Dir.cwd().access(c.io, binding, .{}) catch null) != null, r);
    if (std.mem.endsWith(u8, s.source, ".ts")) {
        const dts = join(c, &.{ c.work, unit, "bridge", "index.d.ts" });
        const text = Io.Dir.cwd().readFileAlloc(c.io, dts, c.a, .limited(1 << 16)) catch "";
        check(c, "bridge writes TypeScript declarations", std.mem.indexOf(u8, text, "export declare function mean(xs: number[]): number;") != null, r);
    }

    // Re-recording with the same seed must be byte-identical.
    const before = try Io.Dir.cwd().readFileAlloc(c.io, cases_path, c.a, .unlimited);
    r = try cli(c, c.work, &.{ "record", s.function });
    const after = try Io.Dir.cwd().readFileAlloc(c.io, cases_path, c.a, .unlimited);
    check(c, "recording is reproducible", r.code == 0 and std.mem.eql(u8, before, after), r);
}

fn programWorkflow(c: *Ctx) !void {
    std.debug.print("program unit: python wc\n", .{});
    var r = try cli(c, c.work, &.{ "init-cli", "wc" });
    expect(c, "init-cli without a command is explained", r, 3, "usage: zig-anything init-cli");
    r = try cli(c, c.work, &.{ "init-cli", "wc", "--cwd", "cli", "--", "python", "wc.py" });
    expect(c, "init-cli creates a program unit", r, 0, "created program unit");
    const unit = join(c, &.{ c.work, "zig-port", "wc" });
    try copyFile(c, join(c, &.{ c.work, "cli", "inputs.jsonl" }), join(c, &.{ unit, "inputs.jsonl" }));
    r = try cli(c, c.work, &.{ "record", "wc" });
    expect(c, "record runs every invocation", r, 0, "recorded 11 run(s)");
    r = try cli(c, c.work, &.{ "diff", "wc" });
    expect(c, "diff fails on the program stub", r, 1, "0/11 cases match");
    r = try cli(c, c.work, &.{ "bridge", "wc" });
    expect(c, "bridge rejects program units", r, 3, "function units");
    try copyFile(c, join(c, &.{ c.work, "solutions", "wc_main.zig" }), join(c, &.{ unit, "src", "main.zig" }));
    r = try cli(c, c.work, &.{ "diff", "wc" });
    expect(c, "diff passes with a correct rewrite", r, 0, "11/11 cases match");
    r = try cli(c, c.work, &.{ "diff", "wc", "--compare-stderr", "--exact-newlines" });
    check(c, "strict comparison flags are accepted", r.code == 0 or r.code == 1, r);
    r = try cli(c, c.work, &.{ "gate", "wc" });
    expect(c, "gate passes for the program", r, 0, "PASSED: wc is a faithful port");
    r = try cli(c, c.work, &.{ "bench", "wc", "--runs", "1" });
    expect(c, "bench times whole processes", r, 0, "verdict:");
}

/// Runs any program (node, python) and returns its exit code and output.
fn runTool(c: *Ctx, cwd: []const u8, argv: []const []const u8) !Result {
    const r = try std.process.run(c.a, c.io, .{ .argv = argv, .cwd = .{ .path = cwd }, .create_no_window = false });
    const code: u8 = switch (r.term) {
        .exited => |x| x,
        else => 255,
    };
    return .{ .code = code, .out = try std.mem.concat(c.a, u8, &.{ r.stdout, r.stderr }) };
}

const python_exe = if (builtin.os.tag == .windows) "python" else "python3";

/// Names of the files in `dir`, sorted, ignoring __pycache__.
fn listing(c: *Ctx, dir_path: []const u8) []const u8 {
    var dir = Io.Dir.cwd().openDir(c.io, dir_path, .{ .iterate = true }) catch return "";
    defer dir.close(c.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(c.io) catch null) |e| {
        if (std.mem.eql(u8, e.name, "__pycache__")) continue;
        names.append(c.a, c.a.dupe(u8, e.name) catch @panic("OOM")) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return std.mem.join(c.a, ",", names.items) catch @panic("OOM");
}

/// Side effects, the native bridge, the sandbox and reproducibility.
fn advanced(c: *Ctx) !void {
    std.debug.print("side effects and the native bridge\n", .{});
    var r = try cli(c, c.work, &.{ "init", "js/vec.mjs", "scaleInPlace" });
    expect(c, "init a function that mutates its argument", r, 0, "created");
    r = try cli(c, c.work, &.{ "record", "scaleInPlace", "--effects" });
    expect(c, "record --effects", r, 0, "recorded");
    const cases_text = Io.Dir.cwd().readFileAlloc(c.io, join(c, &.{ c.work, "zig-port", "scaleInPlace", "cases.jsonl" }), c.a, .unlimited) catch "";
    check(c, "recorded cases include argument mutation", std.mem.indexOf(u8, cases_text, "\"mut\":") != null, r);
    const port_path = join(c, &.{ c.work, "zig-port", "scaleInPlace", "src", "port.zig" });
    try copyFile(c, join(c, &.{ c.work, "solutions", "scale_no_mutation.zig" }), port_path);
    r = try cli(c, c.work, &.{ "diff", "scaleInPlace", "--limit", "1" });
    expect(c, "diff catches a port that forgets to mutate", r, 1, "arguments differ after the call");
    try copyFile(c, join(c, &.{ c.work, "solutions", "scale_in_place.zig" }), port_path);
    r = try cli(c, c.work, &.{ "diff", "scaleInPlace" });
    expect(c, "diff compares mutation and passes", r, 0, "cases match");
    r = try cli(c, c.work, &.{ "bridge", "scaleInPlace" });
    expect(c, "bridge builds and verifies the native addon", r, 0, "recorded cases match through the bridge (native addon)");
    check(c, "bridge also verifies the WebAssembly fallback", r.code == 0 and std.mem.indexOf(u8, r.out, "(WebAssembly)") != null, r);
    for ([_][]const u8{ "native", "wasm" }) |backend| {
        r = try runTool(c, c.work, &.{ "node", "js/bridge_check.mjs", backend });
        const want = try std.fmt.allocPrint(c.a, "{{\"backend\":\"{s}\",\"n\":3,\"plain\":[2,4,6],\"typed\":[2,4,6],\"ints\":[2,4,6],\"inBatch\":[15],\"batch\":[1,0],\"badArg\":\"threw\"}}", .{backend});
        const label = try std.fmt.allocPrint(c.a, "{s} bridge: mutation reaches arrays and typed arrays; bad arguments throw", .{backend});
        expect(c, label, r, 0, want);
    }
    r = try cli(c, c.work, &.{ "bridge", "scaleInPlace", "--no-native" });
    check(c, "bridge --no-native builds only WebAssembly", r.code == 0 and std.mem.indexOf(u8, r.out, "(native addon)") == null and
        (Io.Dir.cwd().access(c.io, join(c, &.{ c.work, "zig-port", "scaleInPlace", "bridge", "port.node" }), .{}) catch null) == null, r);

    r = try cli(c, c.work, &.{ "init", "py/effects.py", "scale_in_place" });
    expect(c, "python: init a mutating function", r, 0, "created");
    r = try cli(c, c.work, &.{ "record", "scale_in_place", "--effects" });
    expect(c, "python: record --effects", r, 0, "recorded");
    try copyFile(c, join(c, &.{ c.work, "solutions", "scale_in_place_py.zig" }), join(c, &.{ c.work, "zig-port", "scale_in_place", "src", "port.zig" }));
    r = try cli(c, c.work, &.{ "gate", "scale_in_place" });
    expect(c, "python: gate passes with mutation compared", r, 0, "PASSED");
    r = try cli(c, c.work, &.{ "bridge", "scale_in_place" });
    expect(c, "python: bridge verifies mutation", r, 0, "recorded cases match through the bridge");
    r = try runTool(c, c.work, &.{ python_exe, "py/bridge_check.py" });
    expect(c, "python bridge: mutation reaches lists and floats stay floats", r, 0, "{\"n\": 3, \"xs\": [2.0, 4.0, 6.0], \"ys\": [15.0], \"floats\": true}");

    std.debug.print("sandbox\n", .{});
    const js_dir = join(c, &.{ c.work, "js" });
    const py_dir = join(c, &.{ c.work, "py" });
    const js_before = listing(c, js_dir);
    const py_before = listing(c, py_dir);
    r = try cli(c, c.work, &.{ "init", "js/vec.mjs", "saveNote" });
    r = try cli(c, c.work, &.{ "record", "saveNote", "--sandbox", "--samples", "4" });
    expect(c, "record --sandbox reports blocked writes (node)", r, 0, "the sandbox blocked");
    check(c, "the sandbox kept node from writing files", std.mem.eql(u8, js_before, listing(c, js_dir)), r);
    r = try cli(c, c.work, &.{ "init", "py/effects.py", "save_note" });
    r = try cli(c, c.work, &.{ "record", "save_note", "--sandbox", "--samples", "4" });
    expect(c, "record --sandbox reports blocked writes (python)", r, 0, "the sandbox blocked");
    check(c, "the sandbox kept python from writing files", std.mem.eql(u8, py_before, listing(c, py_dir)), r);

    std.debug.print("reproducibility\n", .{});
    r = try cli(c, c.work, &.{ "record", "slugify", "--check" });
    expect(c, "record --check confirms a reproducible recording", r, 0, "reproducible");
    check(c, "record writes recording.json", (Io.Dir.cwd().access(c.io, join(c, &.{ c.work, "zig-port", "slugify", "recording.json" }), .{}) catch null) != null, r);
    const slug_cases = join(c, &.{ c.work, "zig-port", "slugify", "cases.jsonl" });
    const original = try Io.Dir.cwd().readFileAlloc(c.io, slug_cases, c.a, .unlimited);
    const first_nl = std.mem.indexOfScalar(u8, original, '\n').?;
    const tampered = try std.mem.concat(c.a, u8, &.{ "{\"id\":1,\"args\":[\"x\"],\"expect\":{\"ok\":\"tampered\"}}", original[first_nl..] });
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = slug_cases, .data = tampered });
    r = try cli(c, c.work, &.{ "record", "slugify", "--check" });
    expect(c, "record --check catches a changed recording", r, 1, "not reproducible");
    const after_check = try Io.Dir.cwd().readFileAlloc(c.io, slug_cases, c.a, .unlimited);
    check(c, "record --check writes nothing", std.mem.eql(u8, after_check, tampered), r);
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = slug_cases, .data = original });
    r = try cli(c, c.work, &.{ "diff", "slugify", "--case", "3,5" });
    expect(c, "diff --case replays chosen cases", r, 0, "2/2 cases match");

    std.debug.print("plan\n", .{});
    r = try cli(c, c.work, &.{ "plan", "." });
    expect(c, "plan lists the project's functions", r, 0, "migration plan");
    r = try cli(c, c.work, &.{ "plan", ".", "--json", "--limit", "0" });
    const plan_json = std.json.parseFromSliceLeaky(std.json.Value, c.a, std.mem.trim(u8, r.out, " \r\n"), .{}) catch null;
    var count_at: ?usize = null;
    var main_at: ?usize = null;
    var slugify_state: []const u8 = "";
    if (plan_json) |pj| if (pj == .object) if (pj.object.get("steps")) |steps| for (steps.array.items, 0..) |step, i| {
        const name = step.object.get("function").?.string;
        if (std.mem.eql(u8, name, "count")) count_at = i;
        if (std.mem.eql(u8, name, "main")) main_at = i;
        if (std.mem.eql(u8, name, "slugify")) if (step.object.get("state")) |st| if (st == .string) {
            slugify_state = st.string;
        };
    };
    check(c, "plan --json is valid JSON", plan_json != null, r);
    check(c, "plan puts a callee before its caller", count_at != null and main_at != null and count_at.? < main_at.?, r);
    check(c, "plan shows the state of existing units", slugify_state.len > 0, r);

    std.debug.print("integrate\n", .{});
    const textutil = join(c, &.{ c.work, "js", "textutil.mjs" });
    const js_original = try Io.Dir.cwd().readFileAlloc(c.io, textutil, c.a, .unlimited);
    r = try cli(c, c.work, &.{ "integrate", "slugify", "--dry-run" });
    expect(c, "integrate --dry-run shows the rewrite", r, 0, "+ import { slugify } from '../zig-port/slugify/bridge/index.mjs'");
    const unchanged = try Io.Dir.cwd().readFileAlloc(c.io, textutil, c.a, .unlimited);
    check(c, "integrate --dry-run changes nothing", std.mem.eql(u8, js_original, unchanged), r);
    r = try cli(c, c.work, &.{ "integrate", "slugify", "--", "node", "-e", "process.exit(3)" });
    expect(c, "integrate rolls back when the project's tests fail", r, 1, "rolled back");
    const after_fail = try Io.Dir.cwd().readFileAlloc(c.io, textutil, c.a, .unlimited);
    check(c, "the rollback restores the source byte for byte", std.mem.eql(u8, js_original, after_fail), r);
    r = try cli(c, c.work, &.{ "integrate", "slugify", "--", "node", "-e", "import('./js/textutil.mjs').then((m) => process.exit(m.slugify('Hello World!') === 'hello-world' ? 0 : 1))" });
    expect(c, "integrate wires the port into the source and verifies it", r, 0, "recorded cases match through the integrated");
    r = try runTool(c, c.work, &.{ "node", "-e", "import('./js/textutil.mjs').then((m) => console.log(m.slugify('A B'), m.wordCount('a b c'), typeof m.slugify__original))" });
    expect(c, "callers run the port; other functions are untouched", r, 0, "a-b 3 undefined");
    r = try cli(c, c.work, &.{"status"});
    check(c, "status marks the unit integrated", std.mem.indexOf(u8, r.out, "integrated") != null, r);
    r = try cli(c, c.work, &.{ "integrate", "slugify" });
    expect(c, "integrating twice is refused", r, 3, "already integrated");
    r = try cli(c, c.work, &.{ "integrate", "--rollback", "slugify" });
    expect(c, "integrate --rollback", r, 0, "rolled back");
    const after_rollback = try Io.Dir.cwd().readFileAlloc(c.io, textutil, c.a, .unlimited);
    check(c, "rollback restores the original source", std.mem.eql(u8, js_original, after_rollback), r);

    const mathutil = join(c, &.{ c.work, "py", "mathutil.py" });
    const py_original = try Io.Dir.cwd().readFileAlloc(c.io, mathutil, c.a, .unlimited);
    r = try cli(c, c.work, &.{ "integrate", "digit_sum", "--", python_exe, "-c", "import sys; sys.path.insert(0, 'py'); import mathutil; sys.exit(0 if mathutil.digit_sum(12345) == 15 and mathutil.fizzbuzz(15) == 'FizzBuzz' else 1)" });
    expect(c, "python: integrate verifies through the rewritten module", r, 0, "integrated digit_sum");
    r = try cli(c, c.work, &.{ "record", "digit_sum" });
    expect(c, "record refuses an integrated unit (it would record the port)", r, 3, "is integrated");
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = mathutil, .data = try std.mem.concat(c.a, u8, &.{ try Io.Dir.cwd().readFileAlloc(c.io, mathutil, c.a, .unlimited), "# a later edit\n" }) });
    r = try cli(c, c.work, &.{ "integrate", "--rollback", "digit_sum" });
    expect(c, "rollback refuses to discard later edits", r, 3, "changed after it was integrated");
    r = try cli(c, c.work, &.{ "integrate", "--rollback", "digit_sum", "--force" });
    const py_after = try Io.Dir.cwd().readFileAlloc(c.io, mathutil, c.a, .unlimited);
    check(c, "rollback --force restores the original", r.code == 0 and std.mem.eql(u8, py_original, py_after), r);
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

    r = try cli(c, c.work, &.{ "profile", "js/app.mjs" });
    expect(c, "profile ranks JavaScript hot spots", r, 0, "next: zig-anything init");
    check(c, "profile finds slugify and marks it portable", std.mem.indexOf(u8, r.out, "slugify") != null and std.mem.indexOf(u8, r.out, "portable") != null, r);
    r = try cli(c, c.work, &.{ "profile", "py/app.py", "--json" });
    const prof_json = std.json.parseFromSliceLeaky(std.json.Value, c.a, std.mem.trim(u8, r.out, " \r\n"), .{}) catch null;
    check(c, "profile --json ranks Python hot spots", r.code == 0 and prof_json != null and std.mem.indexOf(u8, r.out, "digit_sum") != null, r);
    r = try cli(c, c.work, &.{ "profile", "nope.rb" });
    expect(c, "profile rejects unsupported scripts", r, 3, "supported scripts");

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
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"zig_anything_plan","arguments":{"path":"."}}}
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

    var ids: [7]bool = @splat(false);
    var plan_text: []const u8 = "";
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
            6 => plan_text = result.?.object.get("content").?.array.items[0].object.get("text").?.string,
            else => {},
        }
    }
    check(c, "every response is JSON", all_valid, .{ .code = 0, .out = out });
    check(c, "initialize answered", ids[1], .{ .code = 0, .out = out });
    check(c, "tools/list returns 14 tools", tool_count == 14, .{ .code = 0, .out = out });
    check(c, "tools/call runs a command", status_ok, .{ .code = 0, .out = out });
    check(c, "missing tool arguments are tool errors", diff_is_error, .{ .code = 0, .out = out });
    check(c, "unknown methods are rejected", method_not_found, .{ .code = 0, .out = out });
    check(c, "malformed JSON gets a parse error", parse_error, .{ .code = 0, .out = out });
    check(c, "the plan tool returns a compact plan", std.mem.indexOf(u8, plan_text, "migration plan") != null and plan_text.len <= 6200, .{ .code = 0, .out = plan_text });

    std.debug.print("agent setup\n", .{});
    const mcp_json = join(c, &.{ c.work, ".mcp.json" });
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = mcp_json, .data = "{\"mcpServers\":{\"other\":{\"command\":\"x\"}}}" });
    var r = try cli(c, c.work, &.{ "setup-agent", "--agents-md" });
    expect(c, "setup-agent writes the client configs", r, 0, ".vscode/mcp.json");
    const merged = Io.Dir.cwd().readFileAlloc(c.io, mcp_json, c.a, .limited(1 << 16)) catch "";
    const mv = std.json.parseFromSliceLeaky(std.json.Value, c.a, merged, .{}) catch null;
    const servers = if (mv) |v| v.object.get("mcpServers") else null;
    check(c, "setup-agent keeps the other servers", servers != null and servers.?.object.get("other") != null and servers.?.object.get("zig-anything") != null, r);
    r = try cli(c, c.work, &.{ "setup-agent", "--agents-md" });
    expect(c, "setup-agent is idempotent", r, 0, "already set up");
    const agents_md = Io.Dir.cwd().readFileAlloc(c.io, join(c, &.{ c.work, "AGENTS.md" }), c.a, .limited(1 << 16)) catch "";
    check(c, "AGENTS.md gets the workflow once", std.mem.count(u8, agents_md, "zig-anything:begin") == 1, r);
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

    // Coverage-guided fuzzing finds inputs the recording missed, record
    // picks them up, and the finished port still passes.
    const fuzzy = join(c, &.{ c.work, "examples", "fuzzy-js" });
    var r = try cli(c, fuzzy, &.{ "fuzz", "fuzzyScore", "--rounds", "4", "--batch", "100" });
    expect(c, "fuzz keeps inputs that reach new code", r, 0, "kept");
    const kept = countLines(c, join(c, &.{ fuzzy, "zig-port", "fuzzyScore", "inputs.fuzz.jsonl" }));
    check(c, "fuzz writes inputs.fuzz.jsonl", kept > 0, r);
    r = try cli(c, fuzzy, &.{ "fuzz", "fuzzyScore", "--rounds", "1", "--batch", "20", "--json" });
    const fz = std.json.parseFromSliceLeaky(std.json.Value, c.a, std.mem.trim(u8, r.out, " \r\n"), .{}) catch null;
    check(c, "fuzz --json is valid JSON", r.code == 0 and fz != null and fz.? == .object and fz.?.object.get("features_after") != null, r);
    const before = countLines(c, join(c, &.{ fuzzy, "zig-port", "fuzzyScore", "cases.jsonl" }));
    r = try cli(c, fuzzy, &.{ "record", "fuzzyScore" });
    const after = countLines(c, join(c, &.{ fuzzy, "zig-port", "fuzzyScore", "cases.jsonl" }));
    check(c, "record adds the fuzzed inputs", r.code == 0 and after > before, r);
    r = try cli(c, fuzzy, &.{ "gate", "fuzzyScore" });
    expect(c, "the port still passes on the fuzzed inputs", r, 0, "PASSED");
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
    try programWorkflow(&c);
    try advanced(&c);
    try regressions(&c);
    try mcp(&c);
    try examples(&c, examples_dir);

    std.debug.print("\n{d} passed, {d} failed\n", .{ c.passed, c.failures });
    if (c.failures == 0) Io.Dir.cwd().deleteTree(io, work) catch {};
    return if (c.failures == 0) 0 else 1;
}
