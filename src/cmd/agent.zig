//! `setup-agent`: register the MCP server with coding agents in this project.
//!
//! Writes project-level MCP configuration for each client, merging into an
//! existing file (other servers and settings are kept):
//!
//!   claude   .mcp.json           {"mcpServers": {"zig-anything": {...}}}
//!   cursor   .cursor/mcp.json    {"mcpServers": {"zig-anything": {...}}}
//!   vscode   .vscode/mcp.json    {"servers": {"zig-anything": {"type": "stdio", ...}}}
//!
//! `--agents-md` also adds a short workflow section to AGENTS.md, between
//! markers, so running it again updates the section instead of repeating it.

const std = @import("std");
const json = std.json;
const cli = @import("../cli.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const flags = [_]cli.Flag{
    .{ .name = "client", .value = "NAME", .help = "claude, cursor, vscode or all (default: all)" },
    .{ .name = "command", .value = "PATH", .help = "how clients start zig-anything (default: this executable's path)" },
    .{ .name = "agents-md", .help = "also add the workflow to AGENTS.md" },
    .{ .name = "dry-run", .help = "print what would be written and change nothing" },
};

const Client = struct {
    name: []const u8,
    path: []const u8,
    /// Top-level key that holds the servers.
    key: []const u8,
    /// VS Code wants `"type": "stdio"` on each server.
    typed: bool = false,
};

const clients = [_]Client{
    .{ .name = "claude", .path = ".mcp.json", .key = "mcpServers" },
    .{ .name = "cursor", .path = ".cursor/mcp.json", .key = "mcpServers" },
    .{ .name = "vscode", .path = ".vscode/mcp.json", .key = "servers", .typed = true },
};

pub const server_name = "zig-anything";

/// Returns `existing` (JSON text, possibly empty) with the zig-anything
/// server added or replaced under `client.key`. Fails on JSON that is not an
/// object, rather than overwriting the user's file.
pub fn merge(a: Allocator, existing: []const u8, client: Client, command: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, existing, " \t\r\n");
    var root: json.Value = if (trimmed.len == 0)
        .{ .object = .empty }
    else
        try json.parseFromSliceLeaky(json.Value, a, trimmed, .{});
    if (root != .object) return error.NotAnObject;
    const servers_ptr = blk: {
        const gop = try root.object.getOrPut(a, client.key);
        if (!gop.found_existing) gop.value_ptr.* = .{ .object = .empty };
        if (gop.value_ptr.* != .object) return error.NotAnObject;
        break :blk gop.value_ptr;
    };
    var server: json.ObjectMap = .empty;
    if (client.typed) try server.put(a, "type", .{ .string = "stdio" });
    try server.put(a, "command", .{ .string = command });
    var args = json.Array.init(a);
    try args.append(.{ .string = "mcp" });
    try server.put(a, "args", .{ .array = args });
    try servers_ptr.object.put(a, server_name, .{ .object = server });
    var aw: Io.Writer.Allocating = .init(a);
    try json.Stringify.value(root, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    return aw.toOwnedSlice();
}

const md_begin = "<!-- zig-anything:begin -->";
const md_end = "<!-- zig-anything:end -->";

const md_section = md_begin ++
    \\
    \\## Porting to Zig with zig-anything
    \\
    \\The `zig-anything` MCP server (or CLI) ports functions to Zig one at a time and
    \\proves each port against the original's recorded behavior.
    \\
    \\1. `plan` gives the order (callees first, hot code first) and the next command.
    \\2. `init <file> <function>`, then `record <unit>`; `fuzz <unit>` finds more inputs.
    \\3. Write `zig-port/<unit>/src/port.zig`; run `diff <unit>` until every case matches.
    \\4. `gate <unit>` must pass. Do not edit `cases.jsonl` to make a port pass.
    \\5. `bridge <unit>`, then `integrate <unit> -- <test command>` to switch callers to
    \\   the port; it rolls back by itself if anything fails.
    \\
++ md_end ++ "\n";

/// Returns AGENTS.md text with the zig-anything section added or replaced.
pub fn mergeAgentsMd(a: Allocator, existing: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, existing, md_begin)) |b| {
        if (std.mem.indexOfPos(u8, existing, b, md_end)) |e| {
            var end = e + md_end.len;
            if (end < existing.len and existing[end] == '\n') end += 1;
            return std.mem.concat(a, u8, &.{ existing[0..b], md_section, existing[end..] });
        }
    }
    if (existing.len == 0) return std.mem.concat(a, u8, &.{ "# Agent instructions\n\n", md_section });
    const sep: []const u8 = if (std.mem.endsWith(u8, existing, "\n\n")) "" else if (std.mem.endsWith(u8, existing, "\n")) "\n" else "\n\n";
    return std.mem.concat(a, u8, &.{ existing, sep, md_section });
}

fn writeFile(c: *cli.Ctx, p: []const u8, data: []const u8) cli.Reported!void {
    if (std.fs.path.dirname(p)) |d| Io.Dir.cwd().createDirPath(c.io, d) catch |err| return c.fail("cannot create {s}: {s}", .{ d, @errorName(err) });
    Io.Dir.cwd().writeFile(c.io, .{ .sub_path = p, .data = data }) catch |err| return c.fail("cannot write {s}: {s}", .{ p, @errorName(err) });
}

pub fn run(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const which = args.get("client") orelse "all";
    var any = false;
    for (clients) |cl| any = any or std.mem.eql(u8, cl.name, which);
    if (!any and !std.mem.eql(u8, which, "all")) return c.fail("--client must be claude, cursor, vscode or all (got '{s}')", .{which});
    const command = args.get("command") orelse (std.process.executablePathAlloc(c.io, c.arena) catch "zig-anything");
    const dry = args.has("dry-run");

    for (clients) |cl| {
        if (!std.mem.eql(u8, which, "all") and !std.mem.eql(u8, which, cl.name)) continue;
        const existing = Io.Dir.cwd().readFileAlloc(c.io, cl.path, c.arena, .limited(4 << 20)) catch "";
        const merged = merge(c.arena, existing, cl, command) catch {
            c.warn("{s} is not a JSON object; left it alone", .{cl.path});
            continue;
        };
        if (std.mem.eql(u8, existing, merged)) {
            c.print("{s: <18} already set up ({s})\n", .{ cl.path, cl.name });
            continue;
        }
        if (dry) {
            c.print("{s} ({s}) would become:\n{s}", .{ cl.path, cl.name, merged });
            continue;
        }
        try writeFile(c, cl.path, merged);
        c.print("{s}{s: <18}{s} {s} for {s}\n", .{ c.s(.green), cl.path, c.s(.reset), if (existing.len == 0) "created" else "updated", cl.name });
    }
    if (args.has("agents-md")) {
        const existing = Io.Dir.cwd().readFileAlloc(c.io, "AGENTS.md", c.arena, .limited(4 << 20)) catch "";
        const merged = mergeAgentsMd(c.arena, existing) catch return c.fail("out of memory", .{});
        if (dry) {
            c.print("AGENTS.md would get:\n{s}", .{md_section});
        } else if (!std.mem.eql(u8, existing, merged)) {
            try writeFile(c, "AGENTS.md", merged);
            c.print("{s}{s: <18}{s} workflow section {s}\n", .{ c.s(.green), "AGENTS.md", c.s(.reset), if (existing.len == 0) "created" else "updated" });
        } else c.print("{s: <18} already has the workflow\n", .{"AGENTS.md"});
    }
    if (!dry) c.print("\nrestart or reload the agent to pick up the `{s}` MCP server.\n", .{server_name});
    return 0;
}

test "merge keeps other servers and settings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fresh = try merge(a, "", clients[0], "/bin/za");
    const v = try json.parseFromSliceLeaky(json.Value, a, fresh, .{});
    try std.testing.expectEqualStrings("/bin/za", v.object.get("mcpServers").?.object.get("zig-anything").?.object.get("command").?.string);
    const other = try merge(a, "{\"mcpServers\":{\"db\":{\"command\":\"x\"}},\"theme\":1}", clients[0], "/bin/za");
    const w = try json.parseFromSliceLeaky(json.Value, a, other, .{});
    try std.testing.expect(w.object.get("mcpServers").?.object.get("db") != null);
    try std.testing.expect(w.object.get("theme") != null);
    // Idempotent: merging again changes nothing.
    try std.testing.expectEqualStrings(other, try merge(a, other, clients[0], "/bin/za"));
    const vs = try merge(a, "", clients[2], "za");
    try std.testing.expect(std.mem.indexOf(u8, vs, "\"type\": \"stdio\"") != null);
    try std.testing.expectError(error.NotAnObject, merge(a, "[1]", clients[0], "za"));
}

test "AGENTS.md section is added once and updated in place" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const once = try mergeAgentsMd(a, "# Notes\nkeep me\n");
    try std.testing.expect(std.mem.startsWith(u8, once, "# Notes\nkeep me\n\n" ++ md_begin));
    const twice = try mergeAgentsMd(a, once);
    try std.testing.expectEqualStrings(once, twice);
    const old = "# Notes\n" ++ md_begin ++ "\nold text\n" ++ md_end ++ "\nafter\n";
    const updated = try mergeAgentsMd(a, old);
    try std.testing.expect(std.mem.indexOf(u8, updated, "old text") == null);
    try std.testing.expect(std.mem.endsWith(u8, updated, md_end ++ "\nafter\n"));
}
