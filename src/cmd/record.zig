//! `record`: run the original function on generated and user inputs and save
//! its behavior as cases.jsonl.

const std = @import("std");
const json = std.json;
const cli = @import("../cli.zig");
const gen = @import("../gen.zig");
const jsonx = @import("../jsonx.zig");
const cases_mod = @import("../cases.zig");
const runtime = @import("../runtime.zig");
const unit_mod = @import("../unit.zig");
const program = @import("program.zig");
const Io = std.Io;

pub const flags = [_]cli.Flag{
    .{ .name = "samples", .value = "N", .help = "random cases on top of edge cases (default from config: 64)" },
    .{ .name = "seed", .value = "N", .help = "random seed (default from config: 1)" },
    .{ .name = "max-cases", .value = "N", .help = "cap on generated cases (default from config: 2000)" },
    .{ .name = "no-verify", .help = "record once instead of twice (skips flaky-case detection)" },
    .{ .name = "no-generate", .help = "only use inputs.jsonl" },
};

/// Reads `inputs.jsonl`: each line is an argument array or {"args": [...]}.
fn readUserInputs(c: *cli.Ctx, u: unit_mod.Unit, out: *std.ArrayList([]const u8)) cli.Reported!usize {
    const p = u.path(c.arena, unit_mod.inputs_name);
    const text = Io.Dir.cwd().readFileAlloc(c.io, p, c.arena, .limited(256 << 20)) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return c.fail("cannot read {s}: {s}", .{ c.rel(p), @errorName(err) }),
    };
    var it: cases_mod.LineIterator = .{ .rest = text };
    var n: usize = 0;
    var line_no: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        if (line[0] == '#' or std.mem.startsWith(u8, line, "//")) continue;
        const v = json.parseFromSliceLeaky(json.Value, c.arena, line, .{}) catch
            return c.fail("{s}:{d}: not valid JSON", .{ c.rel(p), line_no });
        const args = switch (v) {
            .array => v,
            .object => |o| o.get("args") orelse return c.fail("{s}:{d}: object lines need an \"args\" array", .{ c.rel(p), line_no }),
            else => return c.fail("{s}:{d}: expected an argument array like [1, \"x\"]", .{ c.rel(p), line_no }),
        };
        if (args != .array) return c.fail("{s}:{d}: \"args\" must be an array", .{ c.rel(p), line_no });
        if (args.array.items.len != u.manifest.params.len)
            return c.fail("{s}:{d}: {d} argument(s) given, '{s}' takes {d}", .{ c.rel(p), line_no, args.array.items.len, u.manifest.function, u.manifest.params.len });
        out.append(c.arena, jsonx.stringify(c.arena, args) catch return c.fail("out of memory", .{})) catch return c.fail("out of memory", .{});
        n += 1;
    }
    return n;
}

fn readLines(c: *cli.Ctx, p: []const u8) cli.Reported![]const []const u8 {
    const text = Io.Dir.cwd().readFileAlloc(c.io, p, c.arena, .unlimited) catch |err|
        return c.fail("cannot read recorder output {s}: {s}", .{ p, @errorName(err) });
    var lines: std.ArrayList([]const u8) = .empty;
    var it: cases_mod.LineIterator = .{ .rest = text };
    while (it.next()) |l| lines.append(c.arena, l) catch return c.fail("out of memory", .{});
    return lines.items;
}

fn errName(v: json.Value) ?[]const u8 {
    if (v != .object) return null;
    const e = v.object.get("err") orelse return null;
    return if (e == .string) e.string else "?";
}

/// Two recordings agree when both returned equal values or both threw the
/// same kind of error (messages may legitimately vary).
fn sameOutcome(a: json.Value, b: json.Value) bool {
    if (errName(a)) |ea| {
        const eb = errName(b) orelse return false;
        return std.mem.eql(u8, ea, eb);
    }
    if (errName(b) != null) return false;
    return jsonx.equal(a, b, .{});
}

fn hasOpaque(v: json.Value) bool {
    return switch (v) {
        .object => |o| blk: {
            if (o.get("$opaque") != null or o.get("$big") != null) break :blk true;
            var it = o.iterator();
            while (it.next()) |e| if (hasOpaque(e.value_ptr.*)) break :blk true;
            break :blk false;
        },
        .array => |arr| blk: {
            for (arr.items) |x| if (hasOpaque(x)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

pub fn run(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const u = try unit_mod.load(c, args.pos(0));
    if (u.isCli()) return program.record(c, u, args);
    const cfg = u.cfg.config;
    const opts: gen.Options = .{
        .samples = try cli.parseInt(u32, c, args, "samples", cfg.samples),
        .seed = try cli.parseInt(u64, c, args, "seed", cfg.seed),
        .max_cases = try cli.parseInt(u32, c, args, "max-cases", cfg.max_cases),
    };

    var inputs: std.ArrayList([]const u8) = .empty;
    const user_count = try readUserInputs(c, u, &inputs);
    var generated: usize = 0;
    if (!args.has("no-generate")) {
        const g = gen.generate(c.arena, u.manifest.params, opts) catch return c.fail("out of memory", .{});
        generated = g.len;
        inputs.appendSlice(c.arena, g) catch return c.fail("out of memory", .{});
    }
    if (inputs.items.len == 0) return c.fail("no inputs: add lines to {s} or drop --no-generate", .{c.rel(u.path(c.arena, unit_mod.inputs_name))});

    try u.ensureWorkDir(c);
    const in_path = u.workPath(c.arena, "inputs.gen.jsonl");
    {
        var aw: Io.Writer.Allocating = .init(c.arena);
        for (inputs.items) |args_text| {
            aw.writer.writeAll("{\"args\":") catch return c.fail("out of memory", .{});
            aw.writer.writeAll(args_text) catch return c.fail("out of memory", .{});
            aw.writer.writeAll("}\n") catch return c.fail("out of memory", .{});
        }
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = in_path, .data = aw.written() }) catch |err|
            return c.fail("cannot write {s}: {s}", .{ in_path, @errorName(err) });
    }

    c.print("recording {s}{s}{s} via {s}: {d} inputs ({d} from inputs.jsonl, {d} generated)\n", .{
        c.s(.bold), u.manifest.function, c.s(.reset), runtime.runtimeLabel(u), inputs.items.len, user_count, generated,
    });
    c.out.flush() catch {};

    const verify = !args.has("no-verify");
    const out1 = u.workPath(c.arena, "record.1.jsonl");
    const r1 = try runtime.invoke(c, u, .run, in_path, out1, 1);
    if (!r1.ok) return runtime.reportFailure(c, u, r1);
    const lines1 = try readLines(c, out1);
    if (lines1.len != inputs.items.len)
        return c.fail("recorder produced {d} results for {d} inputs", .{ lines1.len, inputs.items.len });
    var lines2: []const []const u8 = &.{};
    if (verify) {
        const out2 = u.workPath(c.arena, "record.2.jsonl");
        const r2 = try runtime.invoke(c, u, .run, in_path, out2, 1);
        if (!r2.ok) return runtime.reportFailure(c, u, r2);
        lines2 = try readLines(c, out2);
        if (lines2.len != inputs.items.len)
            return c.fail("second recording produced {d} results for {d} inputs", .{ lines2.len, inputs.items.len });
    }

    var aw: Io.Writer.Allocating = .init(c.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    var n_ok: usize = 0;
    var n_err: usize = 0;
    var n_flaky: usize = 0;
    var n_opaque: usize = 0;
    var kinds: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var err_kinds: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (inputs.items, lines1, 0..) |args_text, line, i| {
        const v1 = json.parseFromSliceLeaky(json.Value, c.arena, line, .{}) catch
            return c.fail("recorder output line {d} is not valid JSON", .{i + 1});
        var flaky = false;
        if (verify) {
            const v2 = json.parseFromSliceLeaky(json.Value, c.arena, lines2[i], .{}) catch
                return c.fail("second recording line {d} is not valid JSON", .{i + 1});
            flaky = !sameOutcome(v1, v2);
        }
        if (flaky) n_flaky += 1;
        if (errName(v1)) |e| {
            n_err += 1;
            const gop = err_kinds.getOrPut(c.arena, e) catch return c.fail("out of memory", .{});
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        } else if (v1 == .object and v1.object.get("ok") != null) {
            n_ok += 1;
            const okv = v1.object.get("ok").?;
            if (hasOpaque(okv)) n_opaque += 1;
            const gop = kinds.getOrPut(c.arena, jsonx.kindName(okv)) catch return c.fail("out of memory", .{});
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        } else return c.fail("recorder output line {d} has neither \"ok\" nor \"err\"", .{i + 1});
        try w.print("{{\"id\":{d},\"args\":{s},\"expect\":{s}", .{ i + 1, args_text, line });
        if (flaky) try w.writeAll(",\"flaky\":true");
        try w.writeAll("}\n");
    }
    const cases_path = u.path(c.arena, unit_mod.cases_name);
    // Leave an identical recording untouched: no mtime churn, no VCS noise,
    // and `status` keeps trusting the last diff.
    const previous = Io.Dir.cwd().readFileAlloc(c.io, cases_path, c.arena, .unlimited) catch null;
    const unchanged = previous != null and std.mem.eql(u8, previous.?, aw.written());
    if (!unchanged) {
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = cases_path, .data = aw.written() }) catch |err|
            return c.fail("cannot write {s}: {s}", .{ cases_path, @errorName(err) });
    }

    c.print("{s}recorded{s} {d} cases -> {s}{s}\n", .{ c.s(.green), c.s(.reset), inputs.items.len, c.rel(cases_path), if (unchanged) " (unchanged)" else "" });
    c.print("  returned  {d}", .{n_ok});
    if (kinds.count() > 0) {
        c.print("  (", .{});
        var it = kinds.iterator();
        var first = true;
        while (it.next()) |e| {
            c.print("{s}{s} {d}", .{ if (first) "" else ", ", e.key_ptr.*, e.value_ptr.* });
            first = false;
        }
        c.print(")", .{});
    }
    c.print("\n  threw     {d}", .{n_err});
    if (err_kinds.count() > 0) {
        c.print("  (", .{});
        var it = err_kinds.iterator();
        var first = true;
        while (it.next()) |e| {
            c.print("{s}{s} {d}", .{ if (first) "" else ", ", e.key_ptr.*, e.value_ptr.* });
            first = false;
        }
        c.print(")", .{});
    }
    c.print("\n", .{});
    if (verify) c.print("  flaky     {d}{s}\n", .{ n_flaky, if (n_flaky > 0) " (results differed between two runs; diff skips them)" else "" });
    if (n_opaque > 0) c.warn("{d} result(s) contain functions, symbols or BigInts that JSON cannot carry; those cases cannot match", .{n_opaque});
    if (n_flaky * 2 > inputs.items.len) c.warn("most results are nondeterministic (time, randomness or I/O?); the recording is weak evidence", .{});
    if (u.manifest.returns == null and kinds.count() == 1 and n_err < inputs.items.len and unit_mod.portIsStub(c, u)) {
        c.hint("every call returned {s}; consider making that the port's return type", .{kinds.keys()[0]});
    }
    return 0;
}
