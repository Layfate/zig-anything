//! ZigAnything runtime for port units.
//!
//! This file is copied into every port unit by `zig-anything init`. It turns
//! recorded JSON arguments into typed Zig values, calls the port, and writes
//! results back as JSON lines that `zig-anything diff` compares against the
//! recorded behavior of the original function.
//!
//! Do not edit the copy inside a unit; `zig-anything init --force` rewrites it.

const std = @import("std");
const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const DecodeError = error{ TypeMismatch, OutOfMemory };

/// Converts a JSON number (or a `{"$num": "NaN" | "Infinity" | "-Infinity"}`
/// tag, which is how non-finite floats are recorded) into an `f64`.
pub fn toF64(v: json.Value) DecodeError!f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch error.TypeMismatch,
        .object => |o| blk: {
            if (o.count() != 1) break :blk error.TypeMismatch;
            const tag = o.get("$num") orelse break :blk error.TypeMismatch;
            if (tag != .string) break :blk error.TypeMismatch;
            if (std.mem.eql(u8, tag.string, "NaN")) break :blk std.math.nan(f64);
            if (std.mem.eql(u8, tag.string, "Infinity")) break :blk std.math.inf(f64);
            if (std.mem.eql(u8, tag.string, "-Infinity")) break :blk -std.math.inf(f64);
            break :blk error.TypeMismatch;
        },
        else => error.TypeMismatch,
    };
}

/// Decodes a recorded JSON value into the Zig type `T`.
///
/// Supported: bool, ints, floats, optionals, `[]const u8` strings, slices of
/// any supported type, structs (from JSON objects), enums (from strings) and
/// `std.json.Value` (passed through untouched).
pub fn decode(comptime T: type, a: Allocator, v: json.Value) DecodeError!T {
    if (T == json.Value) return v;
    switch (@typeInfo(T)) {
        .bool => return switch (v) {
            .bool => |b| b,
            else => error.TypeMismatch,
        },
        .float => return @floatCast(try toF64(v)),
        .int => return switch (v) {
            .integer => |i| std.math.cast(T, i) orelse error.TypeMismatch,
            .float => |f| blk: {
                if (!std.math.isFinite(f) or f != @trunc(f)) break :blk error.TypeMismatch;
                if (f < @as(f64, @floatFromInt(std.math.minInt(T))) or
                    f > @as(f64, @floatFromInt(std.math.maxInt(T)))) break :blk error.TypeMismatch;
                break :blk @intFromFloat(f);
            },
            .number_string => |s| std.fmt.parseInt(T, s, 10) catch error.TypeMismatch,
            else => error.TypeMismatch,
        },
        .optional => |o| {
            if (v == .null) return null;
            return try decode(o.child, a, v);
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("unsupported parameter type " ++ @typeName(T));
            if (p.child == u8) {
                if (v != .string) return error.TypeMismatch;
                return if (p.attrs.@"const") v.string else try a.dupe(u8, v.string);
            }
            const items = switch (v) {
                .array => |arr| arr.items,
                else => return error.TypeMismatch,
            };
            const out = try a.alloc(p.child, items.len);
            for (items, out) |item, *slot| slot.* = try decode(p.child, a, item);
            return out;
        },
        .@"enum" => |e| {
            if (v != .string) return error.TypeMismatch;
            inline for (e.field_names) |name| {
                if (std.mem.eql(u8, name, v.string)) return @field(T, name);
            }
            return error.TypeMismatch;
        },
        .@"struct" => |s| {
            const obj = switch (v) {
                .object => |o| o,
                else => return error.TypeMismatch,
            };
            var out: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |name, FT, attrs| {
                if (obj.get(name)) |fv| {
                    @field(out, name) = try decode(FT, a, fv);
                } else if (attrs.defaultValue(FT)) |d| {
                    @field(out, name) = d;
                } else if (@typeInfo(FT) == .optional) {
                    @field(out, name) = null;
                } else return error.TypeMismatch;
            }
            return out;
        },
        else => @compileError("unsupported parameter type " ++ @typeName(T)),
    }
}

/// Writes `s` as a JSON string literal.
pub fn writeString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0C => "\\f",
            else => null,
        };
        if (esc != null or c < 0x20) {
            try w.writeAll(s[start..i]);
            if (esc) |e| try w.writeAll(e) else try w.print("\\u{x:0>4}", .{c});
            start = i + 1;
        }
    }
    try w.writeAll(s[start..]);
    try w.writeByte('"');
}

/// Writes any port return value as JSON. Non-finite floats are written as
/// `{"$num": ...}` tags so they survive the round trip.
pub fn encode(w: *Io.Writer, value: anytype) Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (T == json.Value) return json.Stringify.value(value, .{}, w);
    switch (@typeInfo(T)) {
        .void, .null => try w.writeAll("null"),
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => try w.print("{d}", .{value}),
        .float, .comptime_float => {
            const f: f64 = @floatCast(value);
            if (std.math.isNan(f)) {
                try w.writeAll("{\"$num\":\"NaN\"}");
            } else if (std.math.isInf(f)) {
                try w.writeAll(if (f > 0) "{\"$num\":\"Infinity\"}" else "{\"$num\":\"-Infinity\"}");
            } else if (f == @trunc(f) and @abs(f) < 1e21) {
                // Integral floats print without a fraction, matching JSON
                // emitters in JavaScript and Python.
                try w.print("{d}", .{@as(i128, @intFromFloat(f))});
            } else {
                try w.print("{d}", .{f});
            }
        },
        .optional => if (value) |inner| try encode(w, inner) else try w.writeAll("null"),
        .@"enum" => try writeString(w, @tagName(value)),
        .error_set => {
            try w.writeAll("{\"err\":");
            try writeString(w, @errorName(value));
            try w.writeByte('}');
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) return writeString(w, value);
                try w.writeByte('[');
                for (value, 0..) |item, i| {
                    if (i != 0) try w.writeByte(',');
                    try encode(w, item);
                }
                try w.writeByte(']');
            },
            .one => switch (@typeInfo(p.child)) {
                .array => |arr| {
                    if (arr.child == u8) return writeString(w, value);
                    try encode(w, @as([]const arr.child, value));
                },
                else => try encode(w, value.*),
            },
            else => @compileError("cannot encode " ++ @typeName(T)),
        },
        .array => |arr| {
            if (arr.child == u8) return writeString(w, &value);
            try encode(w, @as([]const arr.child, &value));
        },
        .@"struct" => |s| {
            if (s.is_tuple) {
                try w.writeByte('[');
                inline for (s.field_names, 0..) |name, i| {
                    if (i != 0) try w.writeByte(',');
                    try encode(w, @field(value, name));
                }
                try w.writeByte(']');
                return;
            }
            try w.writeByte('{');
            inline for (s.field_names, 0..) |name, i| {
                if (i != 0) try w.writeByte(',');
                try writeString(w, name);
                try w.writeByte(':');
                try encode(w, @field(value, name));
            }
            try w.writeByte('}');
        },
        else => @compileError("cannot encode " ++ @typeName(T)),
    }
}

/// Number of parameters of `F` that are filled from recorded arguments
/// (every parameter except a leading `std.mem.Allocator`).
pub fn dataArity(comptime F: type) comptime_int {
    var n: comptime_int = 0;
    inline for (@typeInfo(F).@"fn".param_types) |P| {
        if (P.? != Allocator) n += 1;
    }
    return n;
}

fn Args(comptime f: anytype) type {
    return std.meta.ArgsTuple(@TypeOf(f));
}

/// Builds the argument tuple for `f`. Any `std.mem.Allocator` parameter
/// receives `scratch`; every other parameter is decoded from `args`.
pub fn buildArgs(comptime f: anytype, a: Allocator, scratch: Allocator, args: []const json.Value) (DecodeError || error{ArityMismatch})!Args(f) {
    const F = @TypeOf(f);
    if (args.len != comptime dataArity(F)) return error.ArityMismatch;
    var tuple: Args(f) = undefined;
    comptime var j: usize = 0;
    inline for (@typeInfo(F).@"fn".param_types, 0..) |P, i| {
        if (P.? == Allocator) {
            tuple[i] = scratch;
        } else {
            tuple[i] = try decode(P.?, a, args[j]);
            j += 1;
        }
    }
    return tuple;
}

/// Calls `f` and writes one result line: `{"ok":<value>}` or `{"err":"Name"}`.
pub fn callAndWrite(comptime f: anytype, w: *Io.Writer, tuple: Args(f)) Io.Writer.Error!void {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    const result = @call(.auto, f, tuple);
    if (@typeInfo(R) == .error_union) {
        if (result) |ok| {
            try w.writeAll("{\"ok\":");
            try encode(w, ok);
            try w.writeAll("}\n");
        } else |err| {
            try w.writeAll("{\"err\":");
            try writeString(w, @errorName(err));
            try w.writeAll("}\n");
        }
    } else {
        try w.writeAll("{\"ok\":");
        try encode(w, result);
        try w.writeAll("}\n");
    }
}

fn caseArgs(a: Allocator, line: []const u8) ![]const json.Value {
    const root = try json.parseFromSliceLeaky(json.Value, a, line, .{});
    const obj = switch (root) {
        .object => |o| o,
        .array => |arr| return arr.items,
        else => return error.BadCase,
    };
    const args = obj.get("args") orelse return error.BadCase;
    if (args != .array) return error.BadCase;
    return args.array.items;
}

fn nextLine(rest: *[]const u8) ?[]const u8 {
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest.*, '\n') orelse rest.len;
        const line = std.mem.trim(u8, rest.*[0..nl], " \t\r");
        rest.* = if (nl < rest.len) rest.*[nl + 1 ..] else rest.*[rest.len..];
        if (line.len != 0) return line;
    }
    return null;
}

fn usage() noreturn {
    std.debug.print(
        \\usage: harness run <cases.jsonl> <out.jsonl>
        \\       harness bench <cases.jsonl> <out.json> <iterations>
        \\
    , .{});
    std.process.exit(2);
}

/// Entry point used by the generated `harness.zig` of each unit.
pub fn harnessMain(init: std.process.Init, comptime f: anytype) !void {
    const io = init.io;
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 4) usage();
    const mode = argv[1];
    const cwd = Io.Dir.cwd();

    const input = try cwd.readFileAlloc(io, argv[2], gpa, .unlimited);
    defer gpa.free(input);

    var out_file = try cwd.createFile(io, argv[3], .{});
    defer out_file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .init(out_file, io, &out_buf);
    const w = &fw.interface;

    // Arguments live in `args_arena`; anything the port allocates through its
    // Allocator parameter lives in `scratch`, which is reset after every call.
    var args_arena: std.heap.ArenaAllocator = .init(gpa);
    defer args_arena.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    if (std.mem.eql(u8, mode, "run")) {
        var rest: []const u8 = input;
        while (nextLine(&rest)) |line| {
            defer _ = args_arena.reset(.retain_capacity);
            defer _ = scratch.reset(.retain_capacity);
            const a = args_arena.allocator();
            const args = caseArgs(a, line) catch {
                try w.writeAll("{\"harness_error\":\"unreadable case line\"}\n");
                continue;
            };
            const tuple = buildArgs(f, a, scratch.allocator(), args) catch |err| {
                try w.print("{{\"harness_error\":\"cannot decode arguments: {s}\"}}\n", .{@errorName(err)});
                continue;
            };
            try callAndWrite(f, w, tuple);
            // Flush per case so a crash still leaves every completed result.
            try w.flush();
        }
        try w.flush();
    } else if (std.mem.eql(u8, mode, "bench")) {
        if (argv.len < 5) usage();
        const iters = std.fmt.parseInt(u32, argv[4], 10) catch usage();
        const a = args_arena.allocator();
        var tuples: std.ArrayList(Args(f)) = .empty;
        defer tuples.deinit(gpa);
        var rest: []const u8 = input;
        while (nextLine(&rest)) |line| {
            const args = caseArgs(a, line) catch continue;
            const tuple = buildArgs(f, a, scratch.allocator(), args) catch continue;
            try tuples.append(gpa, tuple);
        }
        // One untimed warm-up pass, mirroring the original-runtime harnesses.
        for (tuples.items) |t| {
            std.mem.doNotOptimizeAway(@call(.auto, f, t));
            _ = scratch.reset(.retain_capacity);
        }
        const start = Io.Timestamp.now(io, .awake);
        var i: u32 = 0;
        while (i < iters) : (i += 1) {
            for (tuples.items) |t| {
                std.mem.doNotOptimizeAway(@call(.auto, f, t));
                _ = scratch.reset(.retain_capacity);
            }
        }
        const ns = start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        try w.print("{{\"cases\":{d},\"iterations\":{d},\"ns\":{d}}}\n", .{ tuples.items.len, iters, ns });
        try w.flush();
    } else usage();
}

// ---------------------------------------------------------------- tests

fn parse(a: Allocator, s: []const u8) !json.Value {
    return json.parseFromSliceLeaky(json.Value, a, s, .{});
}

fn encodeToString(a: Allocator, v: anytype) ![]u8 {
    var aw: Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v);
    return aw.toOwnedSlice();
}

test "decode scalars, slices, optionals, structs and enums" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 3), try decode(f64, a, try parse(a, "3")));
    try std.testing.expectEqual(@as(i32, -7), try decode(i32, a, try parse(a, "-7")));
    try std.testing.expectEqual(@as(i64, 4), try decode(i64, a, try parse(a, "4.0")));
    try std.testing.expectError(error.TypeMismatch, decode(i64, a, try parse(a, "4.5")));
    try std.testing.expectError(error.TypeMismatch, decode(u8, a, try parse(a, "300")));
    try std.testing.expect(std.math.isNan(try decode(f64, a, try parse(a, "{\"$num\":\"NaN\"}"))));
    try std.testing.expectEqual(-std.math.inf(f64), try decode(f64, a, try parse(a, "{\"$num\":\"-Infinity\"}")));
    try std.testing.expectEqualStrings("hé", try decode([]const u8, a, try parse(a, "\"hé\"")));
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, try decode([]const i64, a, try parse(a, "[1,2,3]")));
    try std.testing.expectEqual(@as(?bool, null), try decode(?bool, a, try parse(a, "null")));
    const P = struct { x: f64, label: []const u8 = "none", tag: ?u8 };
    const p = try decode(P, a, try parse(a, "{\"x\":1.5}"));
    try std.testing.expectEqual(@as(f64, 1.5), p.x);
    try std.testing.expectEqualStrings("none", p.label);
    try std.testing.expectEqual(@as(?u8, null), p.tag);
    const E = enum { red, green };
    try std.testing.expectEqual(E.green, try decode(E, a, try parse(a, "\"green\"")));
    try std.testing.expectError(error.TypeMismatch, decode(E, a, try parse(a, "\"blue\"")));
    try std.testing.expectError(error.TypeMismatch, decode(bool, a, try parse(a, "1")));
}

test "encode matches common JSON emitters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("3", try encodeToString(a, @as(f64, 3.0)));
    try std.testing.expectEqualStrings("0.1", try encodeToString(a, @as(f64, 0.1)));
    try std.testing.expectEqualStrings("{\"$num\":\"NaN\"}", try encodeToString(a, std.math.nan(f64)));
    try std.testing.expectEqualStrings("\"a\\\"b\\n\\u0001\"", try encodeToString(a, @as([]const u8, "a\"b\n\x01")));
    try std.testing.expectEqualStrings("[1,2]", try encodeToString(a, @as([]const i32, &.{ 1, 2 })));
    try std.testing.expectEqualStrings("null", try encodeToString(a, @as(?u8, null)));
    const S = struct { a: u8, b: bool };
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":true}", try encodeToString(a, S{ .a = 1, .b = true }));
    try std.testing.expectEqualStrings("[1,\"x\"]", try encodeToString(a, .{ @as(u8, 1), @as([]const u8, "x") }));
}

fn sample(gpa: Allocator, words: []const []const u8, sep: []const u8) ![]u8 {
    return std.mem.join(gpa, sep, words);
}

fn addOne(x: i64) i64 {
    return x + 1;
}

fn mayFail(x: f64) !f64 {
    if (x < 0) return error.Negative;
    return @sqrt(x);
}

test "buildArgs injects allocators and checks arity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 2), dataArity(@TypeOf(sample)));
    const args = (try parse(a, "[[\"a\",\"b\"],\"-\"]")).array.items;
    const t = try buildArgs(sample, a, a, args);
    const joined = try @call(.auto, sample, t);
    try std.testing.expectEqualStrings("a-b", joined);
    try std.testing.expectError(error.ArityMismatch, buildArgs(addOne, a, a, args));
}

test "callAndWrite emits ok and err lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    try callAndWrite(mayFail, &aw.writer, .{4});
    try callAndWrite(mayFail, &aw.writer, .{-1});
    try callAndWrite(addOne, &aw.writer, .{41});
    try std.testing.expectEqualStrings("{\"ok\":2}\n{\"err\":\"Negative\"}\n{\"ok\":42}\n", aw.written());
}
