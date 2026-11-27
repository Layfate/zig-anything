//! `mcp`: a Model Context Protocol server over stdio, so coding agents can
//! drive the scan → init → record → diff → gate loop as tools. Each tool call
//! runs this executable as a subprocess and returns its output.

const std = @import("std");
const json = std.json;
const cli = @import("cli.zig");
const jsonx = @import("jsonx.zig");
const proc = @import("proc.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const flags = [_]cli.Flag{
    .{ .name = "print-config", .help = "print a JSON snippet for registering this server with an MCP client" },
};

const Arg = struct {
    /// JSON property name.
    prop: []const u8,
    /// CLI flag ("" = positional).
    flag: []const u8 = "",
    /// `array` (of strings) is passed after `--`, at the end of the command line.
    kind: enum { string, number, boolean, array } = .string,
    required: bool = false,
    /// Passed when the caller leaves the argument out (keeps output short).
    default: ?[]const u8 = null,
    help: []const u8,
};

const Tool = struct {
    name: []const u8,
    command: []const u8,
    description: []const u8,
    args: []const Arg,
};

const unit_arg: Arg = .{ .prop = "unit", .required = true, .help = "Unit directory, or unit name inside the configured units directory" };

// Descriptions are short on purpose: the tool list is sent to the model in
// every session, so each word costs tokens every time.
const tools = [_]Tool{
    .{ .name = "zig_anything_profile", .command = "profile", .description = "Run a JS/TS/Python script under its profiler; rank project functions by time and mark the portable ones.", .args = &.{
        .{ .prop = "script", .required = true, .help = "Script to run" },
        .{ .prop = "args", .kind = .array, .help = "Script arguments" },
        .{ .prop = "top", .flag = "--top", .kind = .number, .help = "Functions to show" },
    } },
    .{ .name = "zig_anything_scan", .command = "scan", .description = "List portable top-level functions with inferred parameter types.", .args = &.{
        .{ .prop = "path", .help = "File or directory (default: .)" },
        .{ .prop = "all", .flag = "--all", .kind = .boolean, .help = "Include unexported functions" },
    } },
    .{ .name = "zig_anything_plan", .command = "plan", .description = "Order a project's migration: callees before callers, hot code first; flags blockers and gives the next command per step.", .args = &.{
        .{ .prop = "path", .help = "File or directory (default: .)" },
        .{ .prop = "hot", .flag = "--hot", .help = "Output of `profile --json`, to weight by time" },
        .{ .prop = "limit", .flag = "--limit", .kind = .number, .default = "10", .help = "Steps to show (default 10, 0 = all)" },
        .{ .prop = "all", .flag = "--all", .kind = .boolean, .help = "Include unexported functions" },
    } },
    .{ .name = "zig_anything_init", .command = "init", .description = "Create a port unit for one function (manifest, port.zig stub, harness).", .args = &.{
        .{ .prop = "file", .required = true, .help = "Source file" },
        .{ .prop = "function", .required = true, .help = "Function name" },
        .{ .prop = "out", .flag = "--out", .help = "Unit directory" },
        .{ .prop = "force", .flag = "--force", .kind = .boolean, .help = "Regenerate manifest/harness; port.zig is kept" },
    } },
    .{ .name = "zig_anything_init_cli", .command = "init-cli", .description = "Create a program unit for a whole command-line program (invocations in inputs.jsonl, rewrite in src/main.zig).", .args = &.{
        .{ .prop = "name", .required = true, .help = "Unit name" },
        .{ .prop = "command", .kind = .array, .required = true, .help = "Original program and leading args, e.g. [\"python\",\"wc.py\"]" },
        .{ .prop = "cwd", .flag = "--cwd", .help = "Working directory for both programs" },
        .{ .prop = "out", .flag = "--out", .help = "Unit directory" },
    } },
    .{ .name = "zig_anything_record", .command = "record", .description = "Run the original on edge cases + inputs.jsonl and save its behavior to cases.jsonl. Runs the original code.", .args = &.{
        unit_arg,
        .{ .prop = "samples", .flag = "--samples", .kind = .number, .help = "Random cases on top of edge cases" },
        .{ .prop = "seed", .flag = "--seed", .kind = .number, .help = "Random seed" },
        .{ .prop = "effects", .flag = "--effects", .kind = .boolean, .help = "Also record argument mutation and printed output" },
        .{ .prop = "sandbox", .flag = "--sandbox", .kind = .boolean, .help = "Block file writes, subprocesses and network" },
        .{ .prop = "check", .flag = "--check", .kind = .boolean, .help = "Fail if re-recording would change cases.jsonl (writes nothing)" },
    } },
    .{ .name = "zig_anything_fuzz", .command = "fuzz", .description = "Coverage-guided: mutate inputs, keep those reaching new code in the original (inputs.fuzz.jsonl); record again after.", .args = &.{
        unit_arg,
        .{ .prop = "rounds", .flag = "--rounds", .kind = .number, .help = "Mutation rounds (default 20)" },
        .{ .prop = "sandbox", .flag = "--sandbox", .kind = .boolean, .help = "Block file writes, subprocesses and network" },
    } },
    .{ .name = "zig_anything_build", .command = "build", .description = "Compile the unit's port and harness.", .args = &.{
        unit_arg,
        .{ .prop = "optimize", .flag = "--optimize", .help = "debug, safe, fast or small" },
    } },
    .{ .name = "zig_anything_diff", .command = "diff", .description = "Build the port and replay every recorded case; shows mismatches (args, expected, got).", .args = &.{
        unit_arg,
        .{ .prop = "limit", .flag = "--limit", .kind = .number, .default = "3", .help = "Mismatches to show (default 3)" },
        .{ .prop = "case", .flag = "--case", .help = "Only these case ids, e.g. \"3,17\"" },
        .{ .prop = "tolerance", .flag = "--tolerance", .kind = .number, .help = "Float tolerance" },
        .{ .prop = "strict_errors", .flag = "--strict-errors", .kind = .boolean, .help = "Error names must match" },
    } },
    .{ .name = "zig_anything_bench", .command = "bench", .description = "Time the original against the optimized port on recorded inputs; gives a verdict.", .args = &.{
        unit_arg,
        .{ .prop = "runs", .flag = "--runs", .kind = .number, .help = "Measured runs per side" },
    } },
    .{ .name = "zig_anything_bridge", .command = "bridge", .description = "Make a finished port callable from the original code (native Node addon + WebAssembly, or a native library for Python) and replay every case through it.", .args = &.{
        unit_arg,
        .{ .prop = "no_native", .flag = "--no-native", .kind = .boolean, .help = "JS/TS: WebAssembly only" },
    } },
    .{ .name = "zig_anything_integrate", .command = "integrate", .description = "Rewrite the original source to call the port; verified by replaying every case (and optional tests), rolled back automatically on failure.", .args = &.{
        unit_arg,
        .{ .prop = "rollback", .flag = "--rollback", .kind = .boolean, .help = "Restore the original source" },
        .{ .prop = "dry_run", .flag = "--dry-run", .kind = .boolean, .help = "Show the rewrite, change nothing" },
        .{ .prop = "force", .flag = "--force", .kind = .boolean, .help = "With rollback: discard later edits" },
        .{ .prop = "test_command", .kind = .array, .help = "Project tests to run after rewriting, e.g. [\"npm\",\"test\"]" },
    } },
    .{ .name = "zig_anything_gate", .command = "gate", .description = "Definition of done: port written, cases recorded, builds, tests pass, every case matches.", .args = &.{
        unit_arg,
        .{ .prop = "bench", .flag = "--bench", .kind = .boolean, .help = "Also require the port to be at least as fast" },
    } },
    .{ .name = "zig_anything_status", .command = "status", .description = "Every unit with its state, cases, last diff, speedup and integration.", .args = &.{
        .{ .prop = "path", .help = "Directory (default: units directory)" },
    } },
};

fn writeToolList(w: *Io.Writer) !void {
    try w.writeAll("{\"tools\":[");
    for (tools, 0..) |t, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try jsonx.writeString(w, t.name);
        try w.writeAll(",\"description\":");
        try jsonx.writeString(w, t.description);
        try w.writeAll(",\"inputSchema\":{\"type\":\"object\",\"properties\":{");
        for (t.args, 0..) |a, j| {
            if (j != 0) try w.writeByte(',');
            try jsonx.writeString(w, a.prop);
            if (a.kind == .array) {
                try w.writeAll(":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":");
            } else try w.print(":{{\"type\":\"{s}\",\"description\":", .{@tagName(a.kind)});
            try jsonx.writeString(w, a.help);
            try w.writeByte('}');
        }
        if (t.args.len > 0) try w.writeByte(',');
        try w.writeAll("\"verbose\":{\"type\":\"boolean\",\"description\":\"Full output instead of a compact one\"}");
        try w.writeAll("},\"required\":[");
        var first = true;
        for (t.args) |a| {
            if (!a.required) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try jsonx.writeString(w, a.prop);
        }
        try w.writeAll("]}}");
    }
    try w.writeAll("]}");
}

fn findTool(name: []const u8) ?Tool {
    for (tools) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// Builds CLI arguments for a tool call. Returns an error message on bad input.
fn toolArgv(a: Allocator, self_exe: []const u8, t: Tool, arguments: ?json.Value, err_msg: *[]const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ self_exe, "--no-color", t.command });
    const obj: ?json.ObjectMap = if (arguments) |v| (if (v == .object) v.object else null) else null;
    var tail: std.ArrayList([]const u8) = .empty;
    for (t.args) |arg| {
        const v = if (obj) |o| o.get(arg.prop) else null;
        if (v == null or v.? == .null) {
            if (arg.required) {
                err_msg.* = try std.fmt.allocPrint(a, "missing required argument '{s}'", .{arg.prop});
                return error.BadArguments;
            }
            if (arg.default) |d| try argv.appendSlice(a, &.{ arg.flag, d });
            continue;
        }
        if (arg.kind == .array) {
            if (v.? != .array or v.?.array.items.len == 0) {
                err_msg.* = try std.fmt.allocPrint(a, "argument '{s}' must be a non-empty array of strings", .{arg.prop});
                return error.BadArguments;
            }
            for (v.?.array.items) |item| {
                if (item != .string) {
                    err_msg.* = try std.fmt.allocPrint(a, "argument '{s}' must contain only strings", .{arg.prop});
                    return error.BadArguments;
                }
                try tail.append(a, item.string);
            }
            continue;
        }
        const text: []const u8 = switch (v.?) {
            .string => |s| s,
            .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
            .number_string => |s| s,
            .bool => |b| if (b) "true" else "false",
            else => {
                err_msg.* = try std.fmt.allocPrint(a, "argument '{s}' has the wrong type", .{arg.prop});
                return error.BadArguments;
            },
        };
        if (arg.kind == .boolean) {
            if (v.? != .bool) {
                err_msg.* = try std.fmt.allocPrint(a, "argument '{s}' must be a boolean", .{arg.prop});
                return error.BadArguments;
            }
            if (v.?.bool) try argv.append(a, arg.flag);
            continue;
        }
        if (arg.flag.len == 0) {
            try argv.append(a, text);
        } else try argv.appendSlice(a, &.{ arg.flag, text });
    }
    if (tail.items.len > 0) {
        try argv.append(a, "--");
        try argv.appendSlice(a, tail.items);
    }
    return argv.items;
}

/// Longest tool result returned without `verbose`, in bytes (~1,500 tokens).
const max_result_bytes = 6000;

/// Makes command output cheap for a model to read: progress lines that were
/// overwritten with `\r` keep only their final state, and long output keeps
/// its first and last lines (where commands put the summary and the next
/// step) with a note of what was left out.
pub fn compact(a: Allocator, text: []const u8, max: usize) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.lastIndexOfScalar(u8, line, '\r')) |cr| line = line[cr + 1 ..];
        try lines.append(a, std.mem.trimEnd(u8, line, " "));
    }
    while (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    const joined = try std.mem.join(a, "\n", lines.items);
    if (joined.len <= max) return joined;
    // Keep a head and a tail of whole lines, about a third and two thirds.
    var head: usize = 0;
    var used: usize = 0;
    while (head < lines.items.len and used + lines.items[head].len + 1 <= max / 3) : (head += 1) used += lines.items[head].len + 1;
    var tail = lines.items.len;
    while (tail > head and used + lines.items[tail - 1].len + 1 <= max - 80) : (tail -= 1) used += lines.items[tail - 1].len + 1;
    var out: std.ArrayList(u8) = .empty;
    for (lines.items[0..head]) |l| {
        try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    try out.print(a, "[... {d} lines left out; call again with \"verbose\": true for everything ...]\n", .{tail - head});
    for (lines.items[tail..], 0..) |l, i| {
        if (i != 0) try out.append(a, '\n');
        try out.appendSlice(a, l);
    }
    return out.items;
}

fn writeResponseStart(w: *Io.Writer, id: json.Value) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try json.Stringify.value(id, .{}, w);
}

fn sendError(w: *Io.Writer, id: json.Value, code: i32, msg: []const u8) !void {
    try writeResponseStart(w, id);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try jsonx.writeString(w, msg);
    try w.writeAll("}}\n");
    try w.flush();
}

fn sendToolText(w: *Io.Writer, id: json.Value, text: []const u8, is_error: bool) !void {
    try writeResponseStart(w, id);
    try w.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try jsonx.writeString(w, text);
    try w.print("}}],\"isError\":{}}}}}\n", .{is_error});
    try w.flush();
}

pub fn printConfig(c: *cli.Ctx) !u8 {
    const self_exe = std.process.executablePathAlloc(c.io, c.arena) catch "zig-anything";
    c.print("{{\n  \"mcpServers\": {{\n    \"zig-anything\": {{\n      \"command\": ", .{});
    try jsonx.writeString(c.out, self_exe);
    c.print(",\n      \"args\": [\"mcp\"]\n    }}\n  }}\n}}\n", .{});
    return 0;
}

pub fn serve(c: *cli.Ctx, version: []const u8) !u8 {
    const io = c.io;
    const self_exe = std.process.executablePathAlloc(io, c.arena) catch return c.fail("cannot locate own executable", .{});
    const in_buf = try c.gpa.alloc(u8, 4 << 20);
    defer c.gpa.free(in_buf);
    var fr: Io.File.Reader = .initStreaming(.stdin(), io, in_buf);
    const r = &fr.interface;
    const w = c.out;

    while (true) {
        const line_opt = r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Drop the oversized message and keep serving.
                _ = r.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            else => break,
        };
        const raw = line_opt orelse break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const msg = json.parseFromSliceLeaky(json.Value, a, line, .{}) catch {
            try sendError(w, .null, -32700, "parse error");
            continue;
        };
        if (msg != .object) {
            try sendError(w, .null, -32600, "invalid request");
            continue;
        }
        const id = msg.object.get("id");
        const method_v = msg.object.get("method") orelse continue; // a response; ignore
        if (method_v != .string) continue;
        const method = method_v.string;
        const params = msg.object.get("params");
        const req_id = id orelse continue; // notifications need no reply

        if (std.mem.eql(u8, method, "initialize")) {
            var proto: []const u8 = "2025-06-18";
            if (params) |p| if (p == .object) if (p.object.get("protocolVersion")) |pv| if (pv == .string) {
                proto = pv.string;
            };
            try writeResponseStart(w, req_id);
            try w.writeAll(",\"result\":{\"protocolVersion\":");
            try jsonx.writeString(w, proto);
            try w.writeAll(",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"zig-anything\",\"version\":");
            try jsonx.writeString(w, version);
            try w.writeAll("},\"instructions\":\"Port JS/TS/Python functions to Zig one at a time, in the order plan gives: init, record (fuzz to find more inputs), write src/port.zig, diff until every case matches, gate, then bridge and integrate. Results are compact; pass verbose: true for full output.\"}}\n");
            try w.flush();
        } else if (std.mem.eql(u8, method, "ping")) {
            try writeResponseStart(w, req_id);
            try w.writeAll(",\"result\":{}}\n");
            try w.flush();
        } else if (std.mem.eql(u8, method, "tools/list")) {
            try writeResponseStart(w, req_id);
            try w.writeAll(",\"result\":");
            try writeToolList(w);
            try w.writeAll("}\n");
            try w.flush();
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const p = params orelse {
                try sendError(w, req_id, -32602, "missing params");
                continue;
            };
            const name = if (p == .object) p.object.get("name") else null;
            if (name == null or name.? != .string) {
                try sendError(w, req_id, -32602, "missing tool name");
                continue;
            }
            const tool = findTool(name.?.string) orelse {
                try sendError(w, req_id, -32602, "unknown tool");
                continue;
            };
            var err_msg: []const u8 = "";
            const argv = toolArgv(a, self_exe, tool, p.object.get("arguments"), &err_msg) catch {
                try sendToolText(w, req_id, err_msg, true);
                continue;
            };
            const result = std.process.run(a, io, .{ .argv = argv, .create_no_window = false }) catch |err| {
                try sendToolText(w, req_id, @errorName(err), true);
                continue;
            };
            const full = try std.mem.concat(a, u8, &.{ result.stdout, if (result.stderr.len > 0 and result.stdout.len > 0) "\n" else "", result.stderr });
            const verbose = if (p.object.get("arguments")) |av| (av == .object and if (av.object.get("verbose")) |vb| vb == .bool and vb.bool else false) else false;
            const text = if (verbose) full else try compact(a, full, max_result_bytes);
            try sendToolText(w, req_id, text, !result.term.success());
        } else {
            try sendError(w, req_id, -32601, "method not found");
        }
    }
    return 0;
}

test "tool argv mapping" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try json.parseFromSliceLeaky(json.Value, a, "{\"unit\":\"u\",\"samples\":5,\"seed\":null}", .{});
    var err: []const u8 = "";
    const argv = try toolArgv(a, "za", findTool("zig_anything_record").?, args, &err);
    try std.testing.expectEqual(@as(usize, 6), argv.len);
    try std.testing.expectEqualStrings("record", argv[2]);
    try std.testing.expectEqualStrings("u", argv[3]);
    try std.testing.expectEqualStrings("5", argv[5]);
    try std.testing.expectError(error.BadArguments, toolArgv(a, "za", findTool("zig_anything_diff").?, null, &err));
    const b = try json.parseFromSliceLeaky(json.Value, a, "{\"unit\":\"u\",\"bench\":true}", .{});
    const argv2 = try toolArgv(a, "za", findTool("zig_anything_gate").?, b, &err);
    try std.testing.expectEqualStrings("--bench", argv2[4]);
}

test "tool list is valid JSON" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeToolList(&aw.writer);
    const parsed = try json.parseFromSlice(json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(tools.len, parsed.value.object.get("tools").?.array.items.len);
}

test "array arguments go after --" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try json.parseFromSliceLeaky(json.Value, a, "{\"name\":\"wc\",\"command\":[\"python\",\"wc.py\"],\"cwd\":\"cli\"}", .{});
    var err: []const u8 = "";
    const argv = try toolArgv(a, "za", findTool("zig_anything_init_cli").?, args, &err);
    const want = [_][]const u8{ "za", "--no-color", "init-cli", "wc", "--cwd", "cli", "--", "python", "wc.py" };
    try std.testing.expectEqual(want.len, argv.len);
    for (want, argv) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "defaults keep results short unless overridden" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err: []const u8 = "";
    const d = try json.parseFromSliceLeaky(json.Value, a, "{\"unit\":\"u\"}", .{});
    const argv = try toolArgv(a, "za", findTool("zig_anything_diff").?, d, &err);
    const want = [_][]const u8{ "za", "--no-color", "diff", "u", "--limit", "3" };
    try std.testing.expectEqual(want.len, argv.len);
    for (want, argv) |x, y| try std.testing.expectEqualStrings(x, y);
    const e = try json.parseFromSliceLeaky(json.Value, a, "{\"unit\":\"u\",\"limit\":50,\"verbose\":true}", .{});
    const argv2 = try toolArgv(a, "za", findTool("zig_anything_diff").?, e, &err);
    try std.testing.expectEqualStrings("50", argv2[5]);
    try std.testing.expectEqual(@as(usize, 6), argv2.len); // verbose is not a CLI flag
    const i = try json.parseFromSliceLeaky(json.Value, a, "{\"unit\":\"u\",\"test_command\":[\"npm\",\"test\"]}", .{});
    const argv3 = try toolArgv(a, "za", findTool("zig_anything_integrate").?, i, &err);
    try std.testing.expectEqualStrings("--", argv3[4]);
    try std.testing.expectEqualStrings("test", argv3[6]);
}

test "compact output" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Progress overwritten with \r keeps its last state; trailing blanks go.
    try std.testing.expectEqualStrings("done 3/3\nok", try compact(a, "step 1/3\rstep 2/3\rdone 3/3\r\nok\n\n", 1000));
    var long: std.ArrayList(u8) = .empty;
    for (0..500) |n| try long.print(a, "line {d}\n", .{n});
    const out = try compact(a, long.items, 600);
    try std.testing.expect(out.len <= 700);
    try std.testing.expect(std.mem.startsWith(u8, out, "line 0\n"));
    try std.testing.expect(std.mem.endsWith(u8, out, "line 499"));
    try std.testing.expect(std.mem.indexOf(u8, out, "lines left out") != null);
}
