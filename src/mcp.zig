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
    kind: enum { string, number, boolean } = .string,
    required: bool = false,
    help: []const u8,
};

const Tool = struct {
    name: []const u8,
    command: []const u8,
    description: []const u8,
    args: []const Arg,
};

const unit_arg: Arg = .{ .prop = "unit", .required = true, .help = "Unit directory, or unit name inside the configured units directory" };

const tools = [_]Tool{
    .{ .name = "zig_anything_scan", .command = "scan", .description = "List top-level functions (with inferred parameter types) in a JS/TS/Python file or project that can be ported to Zig.", .args = &.{
        .{ .prop = "path", .help = "File or directory to scan (default: current directory)" },
        .{ .prop = "all", .flag = "--all", .kind = .boolean, .help = "Include functions that are not exported" },
    } },
    .{ .name = "zig_anything_init", .command = "init", .description = "Create a port unit for one function: manifest, Zig port stub, harness and build files.", .args = &.{
        .{ .prop = "file", .required = true, .help = "Source file containing the function" },
        .{ .prop = "function", .required = true, .help = "Function name" },
        .{ .prop = "out", .flag = "--out", .help = "Unit directory (optional)" },
        .{ .prop = "force", .flag = "--force", .kind = .boolean, .help = "Regenerate manifest/harness of an existing unit; port.zig is kept" },
    } },
    .{ .name = "zig_anything_record", .command = "record", .description = "Run the original function on generated edge cases plus inputs.jsonl and save its behavior to cases.jsonl. Runs the original code.", .args = &.{
        unit_arg,
        .{ .prop = "samples", .flag = "--samples", .kind = .number, .help = "Random cases on top of edge cases" },
        .{ .prop = "seed", .flag = "--seed", .kind = .number, .help = "Random seed" },
    } },
    .{ .name = "zig_anything_build", .command = "build", .description = "Compile the unit's Zig port and harness.", .args = &.{
        unit_arg,
        .{ .prop = "optimize", .flag = "--optimize", .help = "debug, safe, fast or small" },
    } },
    .{ .name = "zig_anything_diff", .command = "diff", .description = "Build the port and replay every recorded case against it; lists mismatches with arguments, expected and actual results.", .args = &.{
        unit_arg,
        .{ .prop = "tolerance", .flag = "--tolerance", .kind = .number, .help = "Float tolerance" },
        .{ .prop = "strict_errors", .flag = "--strict-errors", .kind = .boolean, .help = "Error names must match exactly" },
        .{ .prop = "limit", .flag = "--limit", .kind = .number, .help = "Mismatches to show" },
    } },
    .{ .name = "zig_anything_bench", .command = "bench", .description = "Benchmark the original against the optimized Zig port on recorded inputs and report a verdict.", .args = &.{
        unit_arg,
        .{ .prop = "runs", .flag = "--runs", .kind = .number, .help = "Measured runs per side" },
    } },
    .{ .name = "zig_anything_gate", .command = "gate", .description = "Definition of done: port written, cases recorded, builds, port tests pass, every case matches (optionally not slower).", .args = &.{
        unit_arg,
        .{ .prop = "bench", .flag = "--bench", .kind = .boolean, .help = "Also require the port to be at least as fast" },
    } },
    .{ .name = "zig_anything_status", .command = "status", .description = "Show every port unit with its state, case count, last diff and speedup.", .args = &.{
        .{ .prop = "path", .help = "Directory to search (default: configured units directory)" },
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
            try w.print(":{{\"type\":\"{s}\",\"description\":", .{@tagName(a.kind)});
            try jsonx.writeString(w, a.help);
            try w.writeByte('}');
        }
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
    for (t.args) |arg| {
        const v = if (obj) |o| o.get(arg.prop) else null;
        if (v == null or v.? == .null) {
            if (arg.required) {
                err_msg.* = try std.fmt.allocPrint(a, "missing required argument '{s}'", .{arg.prop});
                return error.BadArguments;
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
    return argv.items;
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
            try w.writeAll("},\"instructions\":\"Port JS/TS/Python functions to Zig one at a time: scan, init, record, implement src/port.zig, diff until every case matches, then gate.\"}}\n");
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
            const result = std.process.run(a, io, .{ .argv = argv }) catch |err| {
                try sendToolText(w, req_id, @errorName(err), true);
                continue;
            };
            const text = try std.mem.concat(a, u8, &.{ result.stdout, if (result.stderr.len > 0 and result.stdout.len > 0) "\n" else "", result.stderr });
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
