//! Reference Zig rewrite of tests/fixtures/cli/wc.py.
const std = @import("std");
const Io = std.Io;

const Counts = struct { lines: usize, words: usize, chars: usize };

fn count(text: []const u8) Counts {
    var c: Counts = .{ .lines = 0, .words = 0, .chars = 0 };
    var in_word = false;
    for (text) |b| {
        if (b == '\n') c.lines += 1;
        // Code points, like Python's len(str): count non-continuation bytes.
        if (b & 0xC0 != 0x80) c.chars += 1;
        const space = b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == 0x0B or b == 0x0C;
        if (!space and !in_word) c.words += 1;
        in_word = !space;
    }
    return c;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = (try init.minimal.args.toSlice(arena))[1..];

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};
    var err_buf: [512]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &stderr.interface;
    defer err.flush() catch {};

    var show_l = false;
    var show_w = false;
    var show_c = false;
    var files: std.ArrayList([]const u8) = .empty;
    for (argv) |a| {
        if (a.len > 1 and a[0] == '-') {
            if (std.mem.eql(u8, a, "-l")) show_l = true else if (std.mem.eql(u8, a, "-w")) show_w = true else if (std.mem.eql(u8, a, "-c")) show_c = true else {
                try err.print("wc: unknown option {s}\n", .{a});
                return 2;
            }
        } else try files.append(arena, a);
    }
    if (!show_l and !show_w and !show_c) {
        show_l = true;
        show_w = true;
        show_c = true;
    }
    if (files.items.len == 0) try files.append(arena, "-");
    for (files.items) |name| {
        const data = if (std.mem.eql(u8, name, "-")) blk: {
            var in_buf: [4096]u8 = undefined;
            var stdin = Io.File.stdin().readerStreaming(io, &in_buf);
            break :blk try stdin.interface.allocRemaining(arena, .unlimited);
        } else Io.Dir.cwd().readFileAlloc(io, name, arena, .unlimited) catch {
            try err.print("wc: {s}: no such file\n", .{name});
            return 1;
        };
        const c = count(data);
        var first = true;
        inline for (.{ .{ show_l, "lines" }, .{ show_w, "words" }, .{ show_c, "chars" } }) |f| {
            if (f[0]) {
                if (!first) try out.writeByte(' ');
                try out.print("{d}", .{@field(c, f[1])});
                first = false;
            }
        }
        if (!std.mem.eql(u8, name, "-")) try out.print(" {s}", .{name});
        try out.writeByte('\n');
    }
    return 0;
}
