//! zig-anything: port JavaScript, TypeScript and Python code to Zig one
//! function at a time, proving each port against the original's recorded
//! behavior.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const cli = @import("cli.zig");
const config = @import("config.zig");
const scan_cmd = @import("cmd/scan.zig");
const record_cmd = @import("cmd/record.zig");
const diff_cmd = @import("cmd/diff.zig");
const bench_cmd = @import("cmd/bench.zig");
const gate_cmd = @import("cmd/gate.zig");
const bridge_cmd = @import("cmd/bridge.zig");
const program_cmd = @import("cmd/program.zig");
const profile_cmd = @import("cmd/profile.zig");
const fuzz_cmd = @import("cmd/fuzz.zig");
const plan_cmd = @import("cmd/plan.zig");
const integrate_cmd = @import("cmd/integrate.zig");
const agent_cmd = @import("cmd/agent.zig");
const mcp = @import("mcp.zig");
const Io = std.Io;

pub const version = options.version;

const Command = struct {
    name: []const u8,
    usage: []const u8,
    summary: []const u8,
    flags: []const cli.Flag,
    run: *const fn (*cli.Ctx, cli.Parsed) anyerror!u8,
};

fn runMcp(c: *cli.Ctx, args: cli.Parsed) anyerror!u8 {
    if (args.has("print-config")) return mcp.printConfig(c);
    return mcp.serve(c, version);
}

const commands = [_]Command{
    .{ .name = "profile", .usage = "profile <script> [-- args]", .summary = "find the functions worth porting first", .flags = &profile_cmd.flags, .run = profile_cmd.run },
    .{ .name = "scan", .usage = "scan [path]", .summary = "list portable functions and their inferred types", .flags = &scan_cmd.scan_flags, .run = scan_cmd.runScan },
    .{ .name = "plan", .usage = "plan [path]", .summary = "order a whole project's migration: callees first, hot code first", .flags = &plan_cmd.flags, .run = plan_cmd.run },
    .{ .name = "init", .usage = "init <source-file> <function>", .summary = "create a port unit (manifest, Zig stub, harness)", .flags = &scan_cmd.init_flags, .run = scan_cmd.runInit },
    .{ .name = "init-cli", .usage = "init-cli <name> -- <command...>", .summary = "create a program unit for a whole command-line program", .flags = &program_cmd.init_flags, .run = program_cmd.runInit },
    .{ .name = "record", .usage = "record <unit>", .summary = "run the original on edge cases and save its behavior", .flags = &record_cmd.flags, .run = record_cmd.run },
    .{ .name = "fuzz", .usage = "fuzz <unit>", .summary = "find inputs that reach new code in the original (coverage-guided)", .flags = &fuzz_cmd.flags, .run = fuzz_cmd.run },
    .{ .name = "build", .usage = "build <unit>", .summary = "compile the Zig port and harness", .flags = &diff_cmd.build_flags, .run = diff_cmd.runBuild },
    .{ .name = "diff", .usage = "diff <unit>", .summary = "replay every recorded case against the port", .flags = &diff_cmd.diff_flags, .run = diff_cmd.runDiff },
    .{ .name = "bench", .usage = "bench <unit>", .summary = "time original vs port and give a verdict", .flags = &bench_cmd.flags, .run = bench_cmd.run },
    .{ .name = "bridge", .usage = "bridge <unit>", .summary = "make the port callable from the original code (wasm for Node, native lib for Python)", .flags = &bridge_cmd.flags, .run = bridge_cmd.run },
    .{ .name = "integrate", .usage = "integrate <unit> [-- test command]", .summary = "wire the port into the original source, verified, with automatic rollback", .flags = &integrate_cmd.flags, .run = integrate_cmd.run },
    .{ .name = "gate", .usage = "gate <unit>", .summary = "check that a port is done (exit 0) or not (exit 1)", .flags = &gate_cmd.gate_flags, .run = gate_cmd.runGate },
    .{ .name = "status", .usage = "status [dir]", .summary = "overview of every unit", .flags = &gate_cmd.status_flags, .run = gate_cmd.runStatus },
    .{ .name = "setup-agent", .usage = "setup-agent", .summary = "register the MCP server with Claude Code, Cursor and VS Code in this project", .flags = &agent_cmd.flags, .run = agent_cmd.run },
    .{ .name = "mcp", .usage = "mcp", .summary = "serve the commands as MCP tools over stdio", .flags = &mcp.flags, .run = runMcp },
};

const help_flag: cli.Flag = .{ .name = "help", .help = "show help for this command" };

fn printMainHelp(c: *cli.Ctx) void {
    c.print(
        \\{s}zig-anything{s} {s}: port JS, TS and Python functions, and whole command-line
        \\programs, to Zig one piece at a time, proven against the original's recorded behavior.
        \\
        \\{s}usage:{s} zig-anything <command> [arguments] [flags]
        \\
        \\{s}commands:{s}
        \\
    , .{ c.s(.bold), c.s(.reset), version, c.s(.bold), c.s(.reset), c.s(.bold), c.s(.reset) });
    for (commands) |cmd| c.print("  {s: <32} {s}\n", .{ cmd.usage, cmd.summary });
    c.print(
        \\  {s: <32} {s}
        \\  {s: <32} {s}
        \\
        \\{s}workflow:{s}
        \\  zig-anything profile src/app.mjs          find what is hot
        \\  zig-anything plan src/                    order the migration (callees first)
        \\  zig-anything init src/text.ts slugify     scaffold zig-port/slugify
        \\  zig-anything record slugify               record the original's behavior
        \\  $EDITOR zig-port/slugify/src/port.zig     write the port
        \\  zig-anything diff slugify                 repeat until every case matches
        \\  zig-anything gate slugify                 done means this passes
        \\
        \\{s}global flags:{s} --no-color, --color, --no-cache (always run the compiler), --help, --version
        \\exit codes: 0 success, 1 check failed, 2 usage error, 3 runtime/environment error
        \\run `zig-anything help <command>` for command flags, `zig-anything help config` for configuration.
        \\
    , .{ "help [command|config]", "show help", "version", "print the version", c.s(.bold), c.s(.reset), c.s(.bold), c.s(.reset) });
}

fn printCommandHelp(c: *cli.Ctx, cmd: Command) void {
    c.print("{s}usage:{s} zig-anything {s} [flags]\n\n{s}\n", .{ c.s(.bold), c.s(.reset), cmd.usage, cmd.summary });
    if (cmd.flags.len > 0) {
        c.print("\n{s}flags:{s}\n", .{ c.s(.bold), c.s(.reset) });
        for (cmd.flags) |f| {
            var buf: [64]u8 = undefined;
            const left = if (f.value) |v| std.fmt.bufPrint(&buf, "--{s} {s}", .{ f.name, v }) catch f.name else std.fmt.bufPrint(&buf, "--{s}", .{f.name}) catch f.name;
            c.print("  {s: <22} {s}\n", .{ left, f.help });
        }
    }
}

fn printConfigHelp(c: *cli.Ctx) void {
    c.print(
        \\{s}configuration{s}: an optional {s} in the project root (found by searching
        \\upward from the current or unit directory). All fields are optional:
        \\
        \\  {{
        \\    "units_dir": "zig-port",        where `init` creates units
        \\    "node": ["node"],               command used for .js/.ts sources
        \\    "python": ["{s}"],{s}       command used for .py sources
        \\    "zig": "zig",                   compiler used to build units
        \\    "samples": 64,                  random cases per recording
        \\    "seed": 1,                      seed for reproducible recordings
        \\    "max_cases": 2000,              cap on generated cases
        \\    "timeout": 300,                 seconds before a child process is stopped
        \\    "tolerance": 0                  float tolerance for diff (0 = exact)
        \\  }}
        \\
        \\environment overrides: ZIG_ANYTHING_NODE, ZIG_ANYTHING_PYTHON, ZIG, NO_COLOR
        \\
    , .{
        c.s(.bold),                                              c.s(.reset),                                 config.file_name,
        if (builtin.os.tag == .windows) "python" else "python3", if (builtin.os.tag == .windows) " " else "",
    });
}

fn findCommand(name: []const u8) ?Command {
    for (commands) |cmd| if (std.mem.eql(u8, cmd.name, name)) return cmd;
    return null;
}

fn commandNames() [commands.len + 2][]const u8 {
    var names: [commands.len + 2][]const u8 = undefined;
    for (commands, 0..) |cmd, i| names[i] = cmd.name;
    names[commands.len] = "help";
    names[commands.len + 1] = "version";
    return names;
}

fn dispatch(c: *cli.Ctx, argv_in: []const []const u8) anyerror!u8 {
    // Global flags may appear anywhere before `--`; what follows `--` is
    // another program's command line and is passed on untouched.
    var argv: std.ArrayList([]const u8) = .empty;
    var after_dashes = false;
    for (argv_in) |arg| {
        if (after_dashes) {
            try argv.append(c.arena, arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            after_dashes = true;
            try argv.append(c.arena, arg);
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            c.color = false;
        } else if (std.mem.eql(u8, arg, "--color")) {
            c.color = true;
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            c.no_cache = true;
        } else try argv.append(c.arena, arg);
    }
    const args = argv.items;
    if (args.len == 0) {
        printMainHelp(c);
        return 0;
    }
    const name = args[0];
    if (std.mem.eql(u8, name, "--version") or std.mem.eql(u8, name, "-V") or std.mem.eql(u8, name, "version")) {
        c.print("zig-anything {s}\n", .{version});
        return 0;
    }
    if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "help")) {
        if (args.len > 1) {
            if (std.mem.eql(u8, args[1], "config")) {
                printConfigHelp(c);
                return 0;
            }
            if (findCommand(args[1])) |cmd| {
                printCommandHelp(c, cmd);
                return 0;
            }
            c.report("unknown command '{s}'", .{args[1]});
            return 2;
        }
        printMainHelp(c);
        return 0;
    }
    const cmd = findCommand(name) orelse {
        const names = commandNames();
        if (cli.suggest(name, &names)) |s| c.hint("did you mean `{s}`?", .{s});
        c.report("unknown command '{s}' (run `zig-anything help`)", .{name});
        return 2;
    };
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printCommandHelp(c, cmd);
            return 0;
        }
    }
    var bad: []const u8 = "";
    const parsed = cli.parse(c.arena, args[1..], cmd.flags, &bad) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                var names: std.ArrayList([]const u8) = .empty;
                for (cmd.flags) |f| try names.append(c.arena, f.name);
                if (cli.suggest(std.mem.trimStart(u8, bad, "-"), names.items)) |s| c.hint("did you mean `--{s}`?", .{s});
                c.report("unknown flag '{s}' for `{s}` (see `zig-anything help {s}`)", .{ bad, cmd.name, cmd.name });
            },
            error.MissingValue => c.report("flag '{s}' needs a value", .{bad}),
            error.OutOfMemory => return err,
        }
        return 2;
    };
    return cmd.run(c, parsed);
}

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buf: [16 * 1024]u8 = undefined;
    var err_buf: [4 * 1024]u8 = undefined;
    // Streaming, not positional: when stdout is a file opened for appending
    // (`zig-anything ... >> log`), positional writes would overwrite its start.
    var out_fw: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    var err_fw: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);

    const no_color = init.environ_map.get("NO_COLOR") != null;
    const tty = Io.File.stdout().supportsAnsiEscapeCodes(io) catch false;
    const color = !no_color and tty;
    const cwd = std.process.currentPathAlloc(io, arena) catch ".";

    var c: cli.Ctx = .{
        .io = io,
        .gpa = init.gpa,
        .arena = arena,
        .env = init.environ_map,
        .out = &out_fw.interface,
        .err = &err_fw.interface,
        .color = color,
        .cwd = cwd,
        .tty = tty,
    };
    const argv = init.minimal.args.toSlice(arena) catch {
        std.debug.print("error: cannot read command line\n", .{});
        return 3;
    };
    const code: u8 = dispatch(&c, if (argv.len > 1) argv[1..] else &.{}) catch |err| switch (err) {
        error.Reported => 3,
        else => blk: {
            c.report("unexpected failure: {s}", .{@errorName(err)});
            break :blk 3;
        },
    };
    c.out.flush() catch {};
    c.err.flush() catch {};
    return code;
}

test {
    _ = @import("cli.zig");
    _ = @import("adapter.zig");
    _ = @import("hash.zig");
    _ = @import("config.zig");
    _ = @import("jsonx.zig");
    _ = @import("lang.zig");
    _ = @import("scan.zig");
    _ = @import("gen.zig");
    _ = @import("cases.zig");
    _ = @import("unit.zig");
    _ = @import("proc.zig");
    _ = @import("mcp.zig");
    _ = @import("cmd/diff.zig");
    _ = @import("cmd/bench.zig");
    _ = @import("cmd/bridge.zig");
    _ = @import("cmd/program.zig");
    _ = @import("cmd/profile.zig");
    _ = @import("cmd/fuzz.zig");
    _ = @import("cmd/plan.zig");
    _ = @import("cmd/integrate.zig");
    _ = @import("cmd/agent.zig");
    _ = @import("mutate.zig");
}
