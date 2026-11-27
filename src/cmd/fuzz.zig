//! `fuzz`: coverage-guided input discovery for a function unit.
//!
//! The original runs in `cover` mode, which reports, per case, the set of
//! code blocks (Node: V8 block coverage) or line transitions (Python) it
//! executed, bucketed by hit count. Starting from the recorded inputs, each
//! round mutates inputs from the corpus (mutate.zig), runs them, and keeps
//! every input that reaches a feature no earlier input reached. A new error
//! type counts as a feature too. Kept inputs go to inputs.fuzz.jsonl, which
//! `record` reads like inputs.jsonl, so `record` + `diff` then hold the port
//! to the original on exactly the inputs that exercise new behavior.

const std = @import("std");
const integrate = @import("integrate.zig");
const json = std.json;
const cli = @import("../cli.zig");
const gen = @import("../gen.zig");
const mutate = @import("../mutate.zig");
const proc = @import("../proc.zig");
const cases_mod = @import("../cases.zig");
const runtime = @import("../runtime.zig");
const unit_mod = @import("../unit.zig");
const Io = std.Io;

pub const flags = [_]cli.Flag{
    .{ .name = "rounds", .value = "N", .help = "mutation rounds (default 20)" },
    .{ .name = "batch", .value = "N", .help = "inputs tried per round (default 200)" },
    .{ .name = "seed", .value = "N", .help = "random seed (default from config: 1)" },
    .{ .name = "max-new", .value = "N", .help = "stop after keeping this many new inputs (default 200)" },
    .{ .name = "sandbox", .help = "block file writes, subprocesses and network access by the original" },
    .{ .name = "jobs", .value = "N", .help = "parallel processes per round (default: one per CPU core)" },
    .{ .name = "json", .help = "machine-readable summary" },
};

const Entry = struct {
    args_text: []const u8,
    args: []const json.Value,
};

const RunResult = struct {
    features: []const u32,
    err: ?[]const u8,
};

/// Runs `inputs` in cover mode (split across processes) and returns the
/// features each one reached.
/// Files written by `cover`, deleted when fuzzing ends.
var scratch_files: std.ArrayList([]const u8) = .empty;

fn cover(c: *cli.Ctx, u: unit_mod.Unit, inputs: []const []const u8, jobs: usize, round: usize, sandbox: bool) cli.Reported![]RunResult {
    const shards = std.math.clamp(inputs.len / 64, 1, @max(jobs, 1));
    const per = (inputs.len + shards - 1) / shards;
    const job_list = c.arena.alloc(proc.Job, shards) catch return c.fail("out of memory", .{});
    const outs = c.arena.alloc([]const u8, shards) catch return c.fail("out of memory", .{});
    for (job_list, outs, 0..) |*job, *out, k| {
        const lo = @min(k * per, inputs.len);
        const hi = @min(lo + per, inputs.len);
        var aw: Io.Writer.Allocating = .init(c.arena);
        for (inputs[lo..hi]) |t| aw.writer.print("{{\"args\":{s}}}\n", .{t}) catch return c.fail("out of memory", .{});
        const in_path = u.workPath(c.arena, std.fmt.allocPrint(c.arena, "fuzz.{d}.{d}.in.jsonl", .{ round, k }) catch return c.fail("out of memory", .{}));
        out.* = u.workPath(c.arena, std.fmt.allocPrint(c.arena, "fuzz.{d}.{d}.out.jsonl", .{ round, k }) catch return c.fail("out of memory", .{}));
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = in_path, .data = aw.written() }) catch |err|
            return c.fail("cannot write {s}: {s}", .{ in_path, @errorName(err) });
        scratch_files.appendSlice(c.arena, &.{ in_path, out.* }) catch {};
        job.* = try runtime.prepare(c, u, .cover, in_path, out.*, .{ .sandbox = sandbox });
    }
    const results = try proc.runMany(c, job_list);
    var all: std.ArrayList(RunResult) = .empty;
    for (results, outs) |r, out| {
        if (!r.ok) return runtime.reportFailure(c, u, r);
        const text = Io.Dir.cwd().readFileAlloc(c.io, out, c.arena, .unlimited) catch |err|
            return c.fail("cannot read {s}: {s}", .{ out, @errorName(err) });
        var it: cases_mod.LineIterator = .{ .rest = text };
        while (it.next()) |line| {
            const v = json.parseFromSliceLeaky(json.Value, c.arena, line, .{}) catch return c.fail("coverage output is not JSON", .{});
            var feats: std.ArrayList(u32) = .empty;
            if (v.object.get("cov")) |cv| if (cv == .array) for (cv.array.items) |x| switch (x) {
                .integer => |i| feats.append(c.arena, @truncate(@as(u64, @bitCast(i)))) catch {},
                else => {},
            };
            const err: ?[]const u8 = if (v.object.get("err")) |e| (if (e == .string) e.string else "?") else null;
            all.append(c.arena, .{ .features = feats.items, .err = err }) catch return c.fail("out of memory", .{});
        }
    }
    if (all.items.len != inputs.len) return c.fail("coverage run returned {d} results for {d} inputs", .{ all.items.len, inputs.len });
    return all.items;
}

fn errFeature(name: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0x7a61, name) | 1);
}

/// Adds the new features of `r` to `seen`; returns how many were new.
fn absorb(c: *cli.Ctx, seen: *std.AutoHashMapUnmanaged(u32, void), r: RunResult) usize {
    var fresh: usize = 0;
    for (r.features) |f| {
        const gop = seen.getOrPut(c.arena, f) catch continue;
        if (!gop.found_existing) fresh += 1;
    }
    if (r.err) |e| {
        const gop = seen.getOrPut(c.arena, errFeature(e)) catch return fresh;
        if (!gop.found_existing) fresh += 1;
    }
    return fresh;
}

pub fn run(c: *cli.Ctx, args: cli.Parsed) !u8 {
    const u = try unit_mod.load(c, args.pos(0));
    if (u.isCli()) return c.fail("fuzz is for function units (program units have no coverage hook)", .{});
    try integrate.refuseIfIntegrated(c, u, "fuzzing");
    const cfg = u.cfg.config;
    const rounds = try cli.parseInt(usize, c, args, "rounds", 20);
    const batch = @max(try cli.parseInt(usize, c, args, "batch", 200), 1);
    const seed = try cli.parseInt(u64, c, args, "seed", cfg.seed);
    const max_new = try cli.parseInt(usize, c, args, "max-new", 200);
    const jobs = try cli.jobCount(c, args, cfg.jobs);
    const sandbox = args.has("sandbox") or cfg.sandbox;
    const json_out = args.has("json");
    try u.ensureWorkDir(c);

    // Seed corpus: what record would use (generated + inputs files), plus
    // anything already recorded.
    var seen_inputs: std.StringHashMapUnmanaged(void) = .empty;
    var corpus: std.ArrayList(Entry) = .empty;
    var seeds: std.ArrayList([]const u8) = .empty;
    const g = gen.generate(c.arena, u.manifest.params, .{ .samples = cfg.samples, .seed = cfg.seed, .max_cases = cfg.max_cases }) catch return c.fail("out of memory", .{});
    seeds.appendSlice(c.arena, g) catch return c.fail("out of memory", .{});
    for ([_][]const u8{ unit_mod.inputs_name, unit_mod.fuzz_inputs_name }) |name| {
        const text = Io.Dir.cwd().readFileAlloc(c.io, u.path(c.arena, name), c.arena, .limited(256 << 20)) catch continue;
        var it: cases_mod.LineIterator = .{ .rest = text };
        while (it.next()) |line| {
            if (line[0] == '#' or std.mem.startsWith(u8, line, "//")) continue;
            const v = json.parseFromSliceLeaky(json.Value, c.arena, line, .{}) catch continue;
            const a = if (v == .object) (v.object.get("args") orelse continue) else v;
            if (a != .array) continue;
            seeds.append(c.arena, std.json.Stringify.valueAlloc(c.arena, a, .{}) catch continue) catch {};
        }
    }
    var unique: std.ArrayList([]const u8) = .empty;
    for (seeds.items) |s| {
        const gop = seen_inputs.getOrPut(c.arena, s) catch return c.fail("out of memory", .{});
        if (!gop.found_existing) unique.append(c.arena, s) catch return c.fail("out of memory", .{});
    }
    if (unique.items.len == 0) return c.fail("no seed inputs; add lines to inputs.jsonl", .{});

    if (!json_out) {
        c.print("fuzzing {s}{s}{s} via {s}: {d} seed inputs, {d} rounds of {d}\n", .{ c.s(.bold), u.manifest.function, c.s(.reset), runtime.runtimeLabel(u), unique.items.len, rounds, batch });
        c.out.flush() catch {};
    }

    var features: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var prng: std.Random.DefaultPrng = .init(seed);
    var m: mutate.Mutator = .{ .a = c.arena, .r = prng.random() };
    const seed_results = try cover(c, u, unique.items, jobs, 0, sandbox);
    for (unique.items, seed_results) |text, r| {
        _ = absorb(c, &features, r);
        const v = json.parseFromSliceLeaky(json.Value, c.arena, text, .{}) catch continue;
        m.learn(v) catch {};
        corpus.append(c.arena, .{ .args_text = text, .args = v.array.items }) catch return c.fail("out of memory", .{});
    }
    const seed_features = features.count();

    var found: std.ArrayList([]const u8) = .empty;
    var tried: usize = 0;
    var round: usize = 1;
    while (round <= rounds and found.items.len < max_new) : (round += 1) {
        var candidates: std.ArrayList([]const u8) = .empty;
        var attempts: usize = 0;
        while (candidates.items.len < batch and attempts < batch * 8) : (attempts += 1) {
            // Favor recent finds: half the parents come from the newest quarter.
            const n = corpus.items.len;
            const pick = if (m.r.boolean() and n >= 4) n - 1 - m.r.uintLessThan(usize, n / 4) else m.r.uintLessThan(usize, n);
            const text = m.mutate(u.manifest.params, corpus.items[pick].args) catch continue;
            const gop = seen_inputs.getOrPut(c.arena, text) catch continue;
            if (gop.found_existing) continue;
            candidates.append(c.arena, text) catch return c.fail("out of memory", .{});
        }
        if (candidates.items.len == 0) break;
        tried += candidates.items.len;
        const results = try cover(c, u, candidates.items, jobs, round, sandbox);
        var kept_now: usize = 0;
        for (candidates.items, results) |text, r| {
            if (absorb(c, &features, r) == 0) continue;
            const v = json.parseFromSliceLeaky(json.Value, c.arena, text, .{}) catch continue;
            m.learn(v) catch {};
            corpus.append(c.arena, .{ .args_text = text, .args = v.array.items }) catch return c.fail("out of memory", .{});
            found.append(c.arena, text) catch return c.fail("out of memory", .{});
            kept_now += 1;
            if (found.items.len >= max_new) break;
        }
        if (!json_out and c.tty) {
            c.print("\rround {d}/{d}: {d} features, {d} new inputs kept", .{ round, rounds, features.count(), found.items.len });
            c.out.flush() catch {};
        }
    }
    if (!json_out and c.tty) c.print("\n", .{});

    // Append the finds to inputs.fuzz.jsonl (keeping earlier finds).
    const out_path = u.path(c.arena, unit_mod.fuzz_inputs_name);
    if (found.items.len > 0) {
        const old = Io.Dir.cwd().readFileAlloc(c.io, out_path, c.arena, .limited(256 << 20)) catch "";
        var aw: Io.Writer.Allocating = .init(c.arena);
        aw.writer.writeAll(old) catch return c.fail("out of memory", .{});
        if (old.len > 0 and old[old.len - 1] != '\n') aw.writer.writeByte('\n') catch {};
        for (found.items) |t| aw.writer.print("{s}\n", .{t}) catch return c.fail("out of memory", .{});
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = out_path, .data = aw.written() }) catch |err|
            return c.fail("cannot write {s}: {s}", .{ out_path, @errorName(err) });
    }
    for (scratch_files.items) |p| Io.Dir.cwd().deleteFile(c.io, p) catch {};

    if (json_out) {
        c.print("{{\"unit\":\"{s}\",\"seed_inputs\":{d},\"tried\":{d},\"features_before\":{d},\"features_after\":{d},\"new_inputs\":{d},\"file\":", .{ u.manifest.name, unique.items.len, tried, seed_features, features.count(), found.items.len });
        @import("../jsonx.zig").writeString(c.out, c.rel(out_path)) catch {};
        c.print("}}\n", .{});
        return 0;
    }
    const color = if (found.items.len > 0) c.s(.green) else c.s(.yellow);
    c.print("{s}coverage{s} {d} -> {d} features (+{d}) from {d} mutated inputs\n", .{ color, c.s(.reset), seed_features, features.count(), features.count() - seed_features, tried });
    if (found.items.len > 0) {
        c.print("kept {d} new input(s) -> {s}\n\nnext:\n  zig-anything record {s}   record the original on them\n  zig-anything diff {s}     hold the port to them\n", .{ found.items.len, c.rel(out_path), c.rel(u.dir), c.rel(u.dir) });
    } else c.print("no input reached new code; the recorded cases already cover what mutation can find\n", .{});
    return 0;
}
