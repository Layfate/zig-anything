//! Source languages, parameter types and their Zig spellings.

const std = @import("std");

pub const Language = enum {
    javascript,
    typescript,
    python,

    pub fn fromPath(path: []const u8) ?Language {
        const ext = std.fs.path.extension(path);
        const table = .{
            .{ ".js", Language.javascript },  .{ ".mjs", Language.javascript },
            .{ ".cjs", Language.javascript }, .{ ".jsx", Language.javascript },
            .{ ".ts", Language.typescript },  .{ ".mts", Language.typescript },
            .{ ".cts", Language.typescript }, .{ ".tsx", Language.typescript },
            .{ ".py", Language.python },
        };
        inline for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
        }
        return null;
    }

    pub fn isJs(l: Language) bool {
        return l == .javascript or l == .typescript;
    }

    pub fn runtimeName(l: Language) []const u8 {
        return if (l.isJs()) "node" else "python";
    }
};

/// The value shapes ZigAnything can generate inputs for and map to Zig.
pub const ParamType = enum {
    number,
    int,
    string,
    bool,
    number_array,
    int_array,
    string_array,
    any,

    pub fn zigType(t: ParamType) []const u8 {
        return switch (t) {
            .number => "f64",
            .int => "i64",
            .string => "[]const u8",
            .bool => "bool",
            .number_array => "[]const f64",
            .int_array => "[]const i64",
            .string_array => "[]const []const u8",
            .any => "std.json.Value",
        };
    }
};

pub const Param = struct {
    name: []const u8,
    type: ParamType = .any,
    optional: bool = false,
};

pub const Function = struct {
    name: []const u8,
    params: []const Param,
    returns: ?ParamType = null,
    line: u32 = 0,
    exported: bool = true,
    is_async: bool = false,
    /// Has rest/variadic parameters, which are never passed by the recorder.
    variadic: bool = false,
};

const zig_keywords = std.StaticStringMap(void).initComptime(.{
    .{"addrspace"}, .{"align"},    .{"allowzero"},   .{"and"},      .{"anyframe"},
    .{"anytype"},   .{"asm"},      .{"break"},       .{"callconv"}, .{"catch"},
    .{"comptime"},  .{"const"},    .{"continue"},    .{"defer"},    .{"else"},
    .{"enum"},      .{"errdefer"}, .{"error"},       .{"export"},   .{"extern"},
    .{"fn"},        .{"for"},      .{"if"},          .{"inline"},   .{"linksection"},
    .{"noalias"},   .{"noinline"}, .{"nosuspend"},   .{"opaque"},   .{"or"},
    .{"orelse"},    .{"packed"},   .{"pub"},         .{"resume"},   .{"return"},
    .{"struct"},    .{"suspend"},  .{"switch"},      .{"test"},     .{"threadlocal"},
    .{"try"},       .{"union"},    .{"unreachable"}, .{"var"},      .{"volatile"},
    .{"while"},     .{"type"},     .{"true"},        .{"false"},    .{"null"},
    .{"undefined"}, .{"std"},      .{"allocator"},
});

/// Writes `name` as a valid Zig identifier, quoting it when needed.
pub fn writeZigIdent(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    var plain = name.len > 0 and !std.ascii.isDigit(name[0]) and !zig_keywords.has(name);
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') plain = false;
    }
    if (plain) return w.writeAll(name);
    try w.writeAll("@\"");
    for (name) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

test "language from path" {
    try std.testing.expectEqual(Language.typescript, Language.fromPath("src/a.TS").?);
    try std.testing.expectEqual(Language.javascript, Language.fromPath("x.mjs").?);
    try std.testing.expectEqual(Language.python, Language.fromPath("pkg/mod.py").?);
    try std.testing.expectEqual(@as(?Language, null), Language.fromPath("main.go"));
}

test "zig identifiers are quoted when needed" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeZigIdent(&aw.writer, "type");
    try aw.writer.writeByte(' ');
    try writeZigIdent(&aw.writer, "fooBar");
    try aw.writer.writeByte(' ');
    try writeZigIdent(&aw.writer, "$el");
    try std.testing.expectEqualStrings("@\"type\" fooBar @\"$el\"", aw.written());
}
