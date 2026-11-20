//! Lightweight source scanners that find top-level functions in JavaScript,
//! TypeScript and Python files and infer parameter types.
//!
//! These are not full parsers. They tokenize just enough (strings, comments,
//! template literals, regex literals, bracket depth) to find top-level
//! function declarations reliably, then read TypeScript/Python annotations,
//! default values and how each parameter is used in the body.

const std = @import("std");
const lang = @import("lang.zig");
const Allocator = std.mem.Allocator;
const Language = lang.Language;
const ParamType = lang.ParamType;
const Param = lang.Param;
const Function = lang.Function;

pub fn scanSource(a: Allocator, language: Language, src: []const u8) ![]Function {
    return switch (language) {
        .javascript, .typescript => scanJs(a, src),
        .python => scanPython(a, src),
    };
}

// =============================================================== JS / TS

const TokKind = enum { ident, number, string, template, regex, punct };

const Tok = struct {
    kind: TokKind,
    text: []const u8,
    line: u32,
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

const regex_prefix_keywords = std.StaticStringMap(void).initComptime(.{
    .{"return"}, .{"typeof"}, .{"case"},   .{"do"},   .{"else"},  .{"in"},
    .{"of"},     .{"new"},    .{"delete"}, .{"void"}, .{"throw"}, .{"yield"},
    .{"await"},
});

fn regexAllowed(prev: ?Tok) bool {
    const t = prev orelse return true;
    return switch (t.kind) {
        .punct => !(std.mem.eql(u8, t.text, ")") or std.mem.eql(u8, t.text, "]") or std.mem.eql(u8, t.text, "}")),
        .ident => regex_prefix_keywords.has(t.text),
        else => false,
    };
}

/// Skips a quoted string starting at `i` (the opening quote). Returns the
/// index just past the closing quote.
fn skipString(src: []const u8, i: usize, line: *u32) usize {
    const q = src[i];
    var j = i + 1;
    while (j < src.len) : (j += 1) {
        switch (src[j]) {
            '\\' => j += 1,
            '\n' => {
                line.* += 1;
                if (q != '`') return j; // unterminated
            },
            else => if (src[j] == q) return j + 1,
        }
    }
    return src.len;
}

/// Skips a template literal, including nested `${ ... }` expressions.
fn skipTemplate(src: []const u8, i: usize, line: *u32) usize {
    var j = i + 1;
    while (j < src.len) {
        const c = src[j];
        if (c == '\\') {
            j += 2;
        } else if (c == '`') {
            return j + 1;
        } else if (c == '$' and j + 1 < src.len and src[j + 1] == '{') {
            j = skipBalanced(src, j + 1, line);
        } else {
            if (c == '\n') line.* += 1;
            j += 1;
        }
    }
    return src.len;
}

/// Skips from an opening `{` to just past its matching `}`, honoring
/// strings, templates and comments inside.
fn skipBalanced(src: []const u8, open: usize, line: *u32) usize {
    var depth: usize = 0;
    var j = open;
    while (j < src.len) {
        const c = src[j];
        switch (c) {
            '{' => {
                depth += 1;
                j += 1;
            },
            '}' => {
                depth -= 1;
                j += 1;
                if (depth == 0) return j;
            },
            '\'', '"' => j = skipString(src, j, line),
            '`' => j = skipTemplate(src, j, line),
            '/' => {
                if (j + 1 < src.len and src[j + 1] == '/') {
                    while (j < src.len and src[j] != '\n') j += 1;
                } else if (j + 1 < src.len and src[j + 1] == '*') {
                    j = skipBlockComment(src, j, line);
                } else j += 1;
            },
            '\n' => {
                line.* += 1;
                j += 1;
            },
            else => j += 1,
        }
    }
    return src.len;
}

fn skipBlockComment(src: []const u8, i: usize, line: *u32) usize {
    var j = i + 2;
    while (j + 1 < src.len) : (j += 1) {
        if (src[j] == '\n') line.* += 1;
        if (src[j] == '*' and src[j + 1] == '/') return j + 2;
    }
    return src.len;
}

fn tokenizeJs(a: Allocator, src: []const u8) ![]Tok {
    var toks: std.ArrayList(Tok) = .empty;
    var i: usize = 0;
    var line: u32 = 1;
    // Skip a hashbang line.
    if (std.mem.startsWith(u8, src, "#!")) {
        while (i < src.len and src[i] != '\n') i += 1;
    }
    while (i < src.len) {
        const c = src[i];
        if (c == '\n') {
            line += 1;
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        const start = i;
        const start_line = line;
        var kind: TokKind = .punct;
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        } else if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i = skipBlockComment(src, i, &line);
            continue;
        } else if (c == '\'' or c == '"') {
            i = skipString(src, i, &line);
            kind = .string;
        } else if (c == '`') {
            i = skipTemplate(src, i, &line);
            kind = .template;
        } else if (c == '/' and regexAllowed(if (toks.items.len > 0) toks.items[toks.items.len - 1] else null)) {
            var in_class = false;
            i += 1;
            while (i < src.len and src[i] != '\n') : (i += 1) {
                switch (src[i]) {
                    '\\' => i += 1,
                    '[' => in_class = true,
                    ']' => in_class = false,
                    '/' => if (!in_class) break,
                    else => {},
                }
            }
            i = @min(i + 1, src.len);
            while (i < src.len and std.ascii.isAlphabetic(src[i])) i += 1;
            kind = .regex;
        } else if (isIdentStart(c)) {
            while (i < src.len and isIdentChar(src[i])) i += 1;
            kind = .ident;
        } else if (std.ascii.isDigit(c) or (c == '.' and i + 1 < src.len and std.ascii.isDigit(src[i + 1]))) {
            while (i < src.len) {
                const d = src[i];
                if (isIdentChar(d) or d == '.') {
                    i += 1;
                } else if ((d == '+' or d == '-') and (src[i - 1] == 'e' or src[i - 1] == 'E') and
                    !std.mem.startsWith(u8, src[start..], "0x") and !std.mem.startsWith(u8, src[start..], "0X"))
                {
                    i += 1;
                } else break;
            }
            kind = .number;
        } else {
            const multi = [_][]const u8{ "...", "=>", "?.", "??", "===", "!==", "==", "!=", "<=", ">=", "**", "&&", "||" };
            var len: usize = 1;
            for (multi) |m| {
                if (std.mem.startsWith(u8, src[i..], m)) {
                    len = m.len;
                    break;
                }
            }
            i += len;
        }
        try toks.append(a, .{ .kind = kind, .text = src[start..i], .line = start_line });
    }
    return toks.toOwnedSlice(a);
}

fn is(t: Tok, text: []const u8) bool {
    return std.mem.eql(u8, t.text, text) and (t.kind == .punct or t.kind == .ident);
}

fn isOpen(t: Tok) bool {
    return t.kind == .punct and t.text.len == 1 and (t.text[0] == '(' or t.text[0] == '[' or t.text[0] == '{');
}

fn isClose(t: Tok) bool {
    return t.kind == .punct and t.text.len == 1 and (t.text[0] == ')' or t.text[0] == ']' or t.text[0] == '}');
}

/// Index of the token matching the opener at `open`, or toks.len.
fn matchClose(toks: []const Tok, open: usize) usize {
    var depth: usize = 0;
    var k = open;
    while (k < toks.len) : (k += 1) {
        if (isOpen(toks[k])) depth += 1;
        if (isClose(toks[k])) {
            depth -= 1;
            if (depth == 0) return k;
        }
    }
    return toks.len;
}

const JsDecl = struct {
    name: []const u8,
    params: []const Tok, // tokens between the parens
    single_param: ?Tok = null, // `x => ...`
    ret: []const Tok = &.{}, // TS return annotation tokens
    body: []const Tok,
    line: u32,
    exported: bool,
    is_async: bool,
};

fn joinTokens(a: Allocator, toks: []const Tok) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (toks) |t| try buf.appendSlice(a, t.text);
    return buf.toOwnedSlice(a);
}

/// Maps a TypeScript type annotation (tokens joined without spaces) to a
/// ParamType. Returns the type and whether it allows undefined/null.
pub fn mapTsType(text_in: []const u8) struct { ParamType, bool } {
    var optional = false;
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    // Remove `readonly`, `|undefined` and `|null`.
    var it = std.mem.splitScalar(u8, text_in, '|');
    while (it.next()) |part_raw| {
        var part = part_raw;
        if (std.mem.startsWith(u8, part, "readonly")) part = part["readonly".len..];
        if (std.mem.eql(u8, part, "undefined") or std.mem.eql(u8, part, "null")) {
            optional = true;
            continue;
        }
        if (part.len == 0) continue;
        if (n != 0 or part.len + n > buf.len) return .{ .any, optional }; // a real union
        @memcpy(buf[0..part.len], part);
        n = part.len;
    }
    const t = buf[0..n];
    const table = .{
        .{ "number", ParamType.number },
        .{ "string", ParamType.string },
        .{ "boolean", ParamType.bool },
        .{ "number[]", ParamType.number_array },
        .{ "Array<number>", ParamType.number_array },
        .{ "ReadonlyArray<number>", ParamType.number_array },
        .{ "string[]", ParamType.string_array },
        .{ "Array<string>", ParamType.string_array },
        .{ "ReadonlyArray<string>", ParamType.string_array },
    };
    inline for (table) |e| {
        if (std.mem.eql(u8, t, e[0])) return .{ e[1], optional };
    }
    return .{ .any, optional };
}

fn literalType(t: Tok) ?ParamType {
    return switch (t.kind) {
        .number => .number,
        .string, .template => .string,
        .ident => if (is(t, "true") or is(t, "false")) .bool else null,
        else => null,
    };
}

fn parseJsParams(a: Allocator, d: JsDecl, f: *Function) ![]Param {
    var params: std.ArrayList(Param) = .empty;
    if (d.single_param) |t| {
        try params.append(a, .{ .name = t.text, .type = inferJsUsage(t.text, d.body) });
        return params.toOwnedSlice(a);
    }
    const toks = d.params;
    var start: usize = 0;
    var k: usize = 0;
    var depth: usize = 0;
    while (k <= toks.len) : (k += 1) {
        const at_end = k == toks.len;
        if (!at_end) {
            const t = toks[k];
            if (isOpen(t) or is(t, "<")) depth += 1;
            if ((isClose(t) or is(t, ">")) and depth > 0) depth -= 1;
            if (!(depth == 0 and is(t, ","))) continue;
        }
        const seg = toks[start..k];
        start = k + 1;
        if (seg.len == 0) continue;
        if (is(seg[0], "...")) {
            f.variadic = true;
            continue;
        }
        var s: usize = 0;
        while (s < seg.len and seg[s].kind == .ident and
            (is(seg[s], "public") or is(seg[s], "private") or is(seg[s], "protected") or is(seg[s], "readonly"))) s += 1;
        if (s >= seg.len) continue;
        if (is(seg[s], "this")) continue; // TS `this` parameter
        var p: Param = .{ .name = "" };
        if (isOpen(seg[s])) {
            p.name = try std.fmt.allocPrint(a, "arg{d}", .{params.items.len});
            p.type = .any;
            try params.append(a, p);
            continue;
        }
        p.name = seg[s].text;
        var j = s + 1;
        if (j < seg.len and is(seg[j], "?")) {
            p.optional = true;
            j += 1;
        }
        var typed = false;
        if (j < seg.len and is(seg[j], ":")) {
            const ty_start = j + 1;
            j = ty_start;
            var dd: usize = 0;
            while (j < seg.len) : (j += 1) {
                if (isOpen(seg[j]) or is(seg[j], "<")) dd += 1;
                if ((isClose(seg[j]) or is(seg[j], ">")) and dd > 0) dd -= 1;
                if (dd == 0 and is(seg[j], "=")) break;
            }
            const mapped = mapTsType(try joinTokens(a, seg[ty_start..j]));
            p.type = mapped[0];
            p.optional = p.optional or mapped[1];
            typed = true;
        }
        if (j < seg.len and is(seg[j], "=")) {
            if (!typed and j + 1 < seg.len) {
                if (literalType(seg[j + 1])) |lt| {
                    p.type = lt;
                    typed = true;
                } else if (is(seg[j + 1], "-") and j + 2 < seg.len and seg[j + 2].kind == .number) {
                    p.type = .number;
                    typed = true;
                }
            }
        }
        if (!typed) p.type = inferJsUsage(p.name, d.body);
        try params.append(a, p);
    }
    return params.toOwnedSlice(a);
}

const js_string_methods = std.StaticStringMap(void).initComptime(.{
    .{"toLowerCase"}, .{"toUpperCase"},   .{"trim"},       .{"trimStart"},   .{"trimEnd"},
    .{"split"},       .{"charAt"},        .{"charCodeAt"}, .{"codePointAt"}, .{"startsWith"},
    .{"endsWith"},    .{"substring"},     .{"substr"},     .{"replace"},     .{"replaceAll"},
    .{"padStart"},    .{"padEnd"},        .{"repeat"},     .{"match"},       .{"matchAll"},
    .{"normalize"},   .{"localeCompare"}, .{"search"},
});

const js_array_methods = std.StaticStringMap(void).initComptime(.{
    .{"map"},    .{"filter"}, .{"reduce"},    .{"reduceRight"}, .{"forEach"}, .{"push"},
    .{"pop"},    .{"shift"},  .{"unshift"},   .{"sort"},        .{"join"},    .{"every"},
    .{"some"},   .{"find"},   .{"findIndex"}, .{"flatMap"},     .{"flat"},    .{"reverse"},
    .{"splice"},
});

fn isArith(t: Tok) bool {
    if (t.kind != .punct) return false;
    const ops = [_][]const u8{ "*", "/", "%", "-", "**", "<", ">", "<=", ">=" };
    for (ops) |o| if (std.mem.eql(u8, t.text, o)) return true;
    return false;
}

const Scores = struct {
    num: i32 = 0,
    int: i32 = 0,
    str: i32 = 0,
    arr: i32 = 0,
    boolean: i32 = 0,

    fn pick(s: Scores, name: []const u8) ParamType {
        const best = @max(s.num, s.int, s.str, s.arr, s.boolean);
        if (best <= 0) return nameHeuristic(name);
        if (s.arr == best) {
            const guess = nameHeuristic(name);
            return switch (guess) {
                .number_array, .int_array, .string_array => guess,
                else => .any,
            };
        }
        if (s.str == best) return .string;
        if (s.int == best) return .int;
        if (s.num == best) return .number;
        return .bool;
    }
};

fn inferJsUsage(name: []const u8, body: []const Tok) ParamType {
    var s: Scores = .{};
    for (body, 0..) |t, k| {
        if (t.kind != .ident or !std.mem.eql(u8, t.text, name)) continue;
        if (k > 0 and (is(body[k - 1], ".") or is(body[k - 1], "?."))) continue; // other.name
        const next: ?Tok = if (k + 1 < body.len) body[k + 1] else null;
        const next2: ?Tok = if (k + 2 < body.len) body[k + 2] else null;
        const prev: ?Tok = if (k > 0) body[k - 1] else null;
        if (next) |n| {
            if ((is(n, ".") or is(n, "?.")) and next2 != null) {
                const m = next2.?.text;
                if (js_string_methods.has(m)) s.str += 3;
                if (js_array_methods.has(m)) s.arr += 3;
                if (std.mem.eql(u8, m, "length") or std.mem.eql(u8, m, "slice") or
                    std.mem.eql(u8, m, "includes") or std.mem.eql(u8, m, "indexOf"))
                {
                    s.str += 1;
                    s.arr += 1;
                }
                if (std.mem.eql(u8, m, "toFixed") or std.mem.eql(u8, m, "toPrecision")) s.num += 3;
            }
            if (isArith(n)) s.num += 2;
            if (is(n, "+") and next2 != null) {
                if (next2.?.kind == .string or next2.?.kind == .template) s.str += 2;
                if (next2.?.kind == .number) s.num += 1;
            }
            if (is(n, "[")) {
                s.str += 1;
                s.arr += 1;
            }
            if (is(n, "&&") or is(n, "||") or is(n, "?")) s.boolean += 1;
        }
        if (prev) |pv| {
            if (isArith(pv) and k >= 2 and !isOpen(body[k - 2]) and !is(body[k - 2], ",") and !is(body[k - 2], "=")) s.num += 2;
            if (is(pv, "-") or is(pv, "~")) s.num += 1;
            if (is(pv, "!")) s.boolean += 1;
            if (is(pv, "of")) s.arr += 2;
            if (is(pv, "+") and k >= 2 and (body[k - 2].kind == .string or body[k - 2].kind == .template)) s.str += 2;
            // Math.fn(name ...)
            if (is(pv, "(") and k >= 4 and is(body[k - 3], ".") and is(body[k - 4], "Math")) s.num += 3;
            if (is(pv, "(") and k >= 2 and (is(body[k - 2], "Number") or is(body[k - 2], "isNaN"))) s.num += 1;
        }
    }
    return s.pick(name);
}

/// Guesses a type from a parameter name (last camelCase/snake_case word).
pub fn nameHeuristic(name: []const u8) ParamType {
    var buf: [64]u8 = undefined;
    if (name.len == 0 or name.len > buf.len) return .any;
    const lower = std.ascii.lowerString(&buf, name);
    // Booleans: isX, hasX, shouldX, canX, allowX, enableX, useX.
    const bool_prefixes = [_][]const u8{ "is", "has", "should", "can", "allow", "enable", "use" };
    for (bool_prefixes) |pfx| {
        if (name.len > pfx.len and std.mem.startsWith(u8, name, pfx) and
            (std.ascii.isUpper(name[pfx.len]) or name[pfx.len] == '_')) return .bool;
    }
    // Last word of camelCase or snake_case.
    var word_start: usize = 0;
    for (name, 0..) |c, idx| {
        if (idx > 0 and (std.ascii.isUpper(c) or name[idx - 1] == '_')) word_start = idx;
    }
    const last = lower[word_start..];
    const tables = .{
        .{ ParamType.bool, [_][]const u8{ "flag", "strict", "verbose", "recursive", "enabled", "insensitive", "sensitive", "ignorecase", "loose" } },
        .{ ParamType.number_array, [_][]const u8{ "nums", "numbers", "values", "scores", "prices", "weights", "xs", "ys", "amounts", "samples", "vals" } },
        .{ ParamType.string_array, [_][]const u8{ "words", "names", "strings", "lines", "tokens", "tags", "keys", "labels", "parts", "strs", "terms" } },
        .{ ParamType.int, [_][]const u8{ "i", "j", "k", "index", "idx", "count", "len", "length", "size", "n", "times", "depth", "level", "places", "digits", "year", "port", "id" } },
        .{ ParamType.number, [_][]const u8{
            "x",       "y",          "z",        "num",    "number",  "amount",    "total",  "price",
            "rate",    "ratio",      "width",    "height", "min",     "max",       "limit",  "offset",
            "start",   "end",        "step",     "seed",   "score",   "threshold", "weight", "age",
            "celsius", "fahrenheit", "degrees",  "radius", "ms",      "seconds",   "base",   "exp",
            "power",   "value",      "val",      "factor", "percent", "lo",        "hi",     "a",
            "b",       "temp",       "distance", "angle",  "lat",     "lon",       "lng",    "minutes",
        } },
        .{ ParamType.string, [_][]const u8{
            "s",        "str",       "text",      "name",   "query",    "pattern", "word",     "input",
            "line",     "path",      "url",       "email",  "title",    "label",   "prefix",   "suffix",
            "sep",      "separator", "delimiter", "delim",  "char",     "ch",      "key",      "message",
            "msg",      "slug",      "html",      "source", "format",   "locale",  "haystack", "needle",
            "content",  "body",      "string",    "phrase", "sentence", "code",    "hex",      "color",
            "filename", "ext",       "camel",     "snake",  "template", "csv",     "json",     "src",
        } },
    };
    inline for (tables) |entry| {
        for (entry[1]) |w| {
            if (std.mem.eql(u8, last, w)) return entry[0];
        }
    }
    return .any;
}

fn returnType(a: Allocator, ret: []const Tok, is_async: *bool) !?ParamType {
    if (ret.len == 0) return null;
    var text = try joinTokens(a, ret);
    if (std.mem.startsWith(u8, text, "Promise<") and std.mem.endsWith(u8, text, ">")) {
        text = text["Promise<".len .. text.len - 1];
        is_async.* = true;
    }
    if (std.mem.eql(u8, text, "void")) return null;
    const mapped = mapTsType(text);
    if (mapped[0] == .any) return null;
    return mapped[0];
}

/// Collects a TS return annotation starting at `k` (just after `)`), up to
/// the body opener `{` or `=>` at depth 0. Returns the annotation tokens and
/// advances `k` to the opener.
fn readReturnAnnotation(toks: []const Tok, k: *usize) []const Tok {
    if (k.* >= toks.len or !is(toks[k.*], ":")) return &.{};
    const start = k.* + 1;
    var j = start;
    var depth: usize = 0;
    while (j < toks.len) : (j += 1) {
        const t = toks[j];
        if (depth == 0 and (is(t, "{") or is(t, "=>"))) {
            // `{` directly after `:` would be an object type literal.
            if (is(t, "{") and j == start) {
                j = matchClose(toks, j);
                continue;
            }
            break;
        }
        if (isOpen(t) or is(t, "<")) depth += 1;
        if ((isClose(t) or is(t, ">")) and depth > 0) depth -= 1;
    }
    k.* = j;
    return toks[start..j];
}

/// Reads an arrow/function body starting at `k`. Block bodies run to the
/// matching brace; expression bodies to the next `;` or `,` at depth 0.
fn readBody(toks: []const Tok, k: usize) []const Tok {
    if (k >= toks.len) return &.{};
    if (is(toks[k], "{")) {
        const end = matchClose(toks, k);
        return toks[k..@min(end + 1, toks.len)];
    }
    var j = k;
    var depth: usize = 0;
    while (j < toks.len) : (j += 1) {
        const t = toks[j];
        if (isOpen(t)) depth += 1;
        if (isClose(t)) {
            if (depth == 0) break;
            depth -= 1;
        }
        if (depth == 0 and (is(t, ";") or is(t, ","))) break;
        if (depth == 0 and j > k and toks[j].line != toks[j - 1].line and t.kind == .ident and
            (is(t, "export") or is(t, "const") or is(t, "let") or is(t, "var") or is(t, "function") or is(t, "class"))) break;
    }
    return toks[k..j];
}

/// Tries to read a function expression at `k`: `[async] function [name] (...)`,
/// `[async] (...) =>`, or `[async] x =>`.
fn readFunctionExpr(toks: []const Tok, k_in: usize, name: []const u8, line: u32, exported: bool) ?JsDecl {
    var k = k_in;
    var is_async = false;
    if (k < toks.len and is(toks[k], "async")) {
        is_async = true;
        k += 1;
    }
    if (k >= toks.len) return null;
    if (is(toks[k], "function")) {
        k += 1;
        if (k < toks.len and is(toks[k], "*")) k += 1;
        if (k < toks.len and toks[k].kind == .ident) k += 1;
        if (k >= toks.len or !is(toks[k], "(")) return null;
        const close = matchClose(toks, k);
        if (close >= toks.len) return null;
        var after = close + 1;
        const ret = readReturnAnnotation(toks, &after);
        if (after >= toks.len or !is(toks[after], "{")) return null;
        return .{ .name = name, .params = toks[k + 1 .. close], .ret = ret, .body = readBody(toks, after), .line = line, .exported = exported, .is_async = is_async };
    }
    // Generic arrow type parameters: <T>(...) =>
    if (is(toks[k], "<")) {
        var j = k;
        while (j < toks.len and !is(toks[j], ">")) j += 1;
        k = j + 1;
        if (k >= toks.len) return null;
    }
    if (is(toks[k], "(")) {
        const close = matchClose(toks, k);
        if (close >= toks.len) return null;
        var after = close + 1;
        const ret = readReturnAnnotation(toks, &after);
        if (after >= toks.len or !is(toks[after], "=>")) return null;
        return .{ .name = name, .params = toks[k + 1 .. close], .ret = ret, .body = readBody(toks, after + 1), .line = line, .exported = exported, .is_async = is_async };
    }
    if (toks[k].kind == .ident and k + 1 < toks.len and is(toks[k + 1], "=>")) {
        return .{ .name = name, .params = &.{}, .single_param = toks[k], .body = readBody(toks, k + 2), .line = line, .exported = exported, .is_async = is_async };
    }
    return null;
}

fn scanJs(a: Allocator, src: []const u8) ![]Function {
    const toks = try tokenizeJs(a, src);
    var decls: std.ArrayList(JsDecl) = .empty;
    // name -> exported-as name(s)
    var exports: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;

    const addExport = struct {
        fn f(al: Allocator, map: *std.StringHashMapUnmanaged(std.ArrayList([]const u8)), local: []const u8, exported_as: []const u8) !void {
            const gop = try map.getOrPut(al, local);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(al, exported_as);
        }
    }.f;

    var k: usize = 0;
    while (k < toks.len) {
        const t = toks[k];
        if (isOpen(t)) {
            k = matchClose(toks, k) + 1;
            continue;
        }
        var j = k;
        var exported = false;
        if (is(toks[j], "export")) {
            exported = true;
            j += 1;
            if (j < toks.len and is(toks[j], "default")) j += 1;
        }
        if (j >= toks.len) break;

        // export { a, b as c }
        if (exported and is(toks[j], "{")) {
            const close = matchClose(toks, j);
            var m = j + 1;
            while (m < close) : (m += 1) {
                if (toks[m].kind != .ident) continue;
                if (m + 2 < close and is(toks[m + 1], "as")) {
                    try addExport(a, &exports, toks[m].text, toks[m + 2].text);
                    m += 2;
                } else try addExport(a, &exports, toks[m].text, toks[m].text);
            }
            k = close + 1;
            continue;
        }
        // export default name;
        if (exported and toks[j].kind == .ident and j + 1 < toks.len and is(toks[j + 1], ";") and is(toks[k + 1], "default")) {
            try addExport(a, &exports, toks[j].text, toks[j].text);
            k = j + 2;
            continue;
        }
        // [async] function name(
        {
            var m = j;
            var is_async = false;
            if (m < toks.len and is(toks[m], "async")) {
                is_async = true;
                m += 1;
            }
            if (m < toks.len and is(toks[m], "function")) {
                m += 1;
                if (m < toks.len and is(toks[m], "*")) m += 1;
                if (m + 1 < toks.len and toks[m].kind == .ident and is(toks[m + 1], "(")) {
                    const name_tok = toks[m];
                    const close = matchClose(toks, m + 1);
                    var after = close + 1;
                    const ret = readReturnAnnotation(toks, &after);
                    if (after < toks.len and is(toks[after], "{")) {
                        const body = readBody(toks, after);
                        try decls.append(a, .{ .name = name_tok.text, .params = toks[m + 2 .. close], .ret = ret, .body = body, .line = name_tok.line, .exported = exported, .is_async = is_async });
                        k = after + body.len;
                        continue;
                    }
                    // TS overload signature without a body: skip it.
                    k = after;
                    continue;
                }
            }
        }
        // const name = <function expr>
        if (j + 2 < toks.len and (is(toks[j], "const") or is(toks[j], "let") or is(toks[j], "var")) and toks[j + 1].kind == .ident) {
            const name_tok = toks[j + 1];
            var m = j + 2;
            if (is(toks[m], ":")) {
                // Skip a type annotation on the binding.
                var depth: usize = 0;
                while (m < toks.len) : (m += 1) {
                    if (isOpen(toks[m]) or is(toks[m], "<")) depth += 1;
                    if ((isClose(toks[m]) or is(toks[m], ">")) and depth > 0) depth -= 1;
                    if (depth == 0 and is(toks[m], "=")) break;
                }
            }
            if (m < toks.len and is(toks[m], "=")) {
                if (readFunctionExpr(toks, m + 1, name_tok.text, name_tok.line, exported)) |d| {
                    try decls.append(a, d);
                    const body_end = @intFromPtr(d.body.ptr + d.body.len);
                    const base = @intFromPtr(toks.ptr);
                    k = @max(m + 1, (body_end - base) / @sizeOf(Tok));
                    continue;
                }
            }
        }
        // module.exports = { a, b: c } / module.exports = name / module.exports.x = ... / exports.x = ...
        if (is(t, "module") or is(t, "exports")) {
            var m = k;
            if (is(toks[m], "module") and m + 2 < toks.len and is(toks[m + 1], ".") and is(toks[m + 2], "exports")) m += 3 else if (is(toks[m], "exports")) m += 1 else {
                k += 1;
                continue;
            }
            if (m < toks.len and is(toks[m], ".") and m + 2 < toks.len and toks[m + 1].kind == .ident and is(toks[m + 2], "=")) {
                const exported_name = toks[m + 1];
                if (readFunctionExpr(toks, m + 3, exported_name.text, exported_name.line, true)) |d| {
                    try decls.append(a, d);
                } else if (m + 3 < toks.len and toks[m + 3].kind == .ident) {
                    try addExport(a, &exports, toks[m + 3].text, exported_name.text);
                }
                k = m + 3;
                continue;
            }
            if (m < toks.len and is(toks[m], "=")) {
                if (m + 1 < toks.len and is(toks[m + 1], "{")) {
                    const close = matchClose(toks, m + 1);
                    var q = m + 2;
                    while (q < close) : (q += 1) {
                        if (toks[q].kind != .ident) continue;
                        if (q + 2 < close and is(toks[q + 1], ":") and toks[q + 2].kind == .ident) {
                            try addExport(a, &exports, toks[q + 2].text, toks[q].text);
                            q += 2;
                        } else if (q + 1 <= close and (is(toks[q + 1], ",") or q + 1 == close)) {
                            try addExport(a, &exports, toks[q].text, toks[q].text);
                        } else if (q + 1 < close and (is(toks[q + 1], "(") or is(toks[q + 1], ":"))) {
                            // inline method / value: skip to the next top-level comma
                            var depth: usize = 0;
                            while (q < close) : (q += 1) {
                                if (isOpen(toks[q])) depth += 1;
                                if (isClose(toks[q])) depth -= 1;
                                if (depth == 0 and is(toks[q], ",")) break;
                            }
                        }
                    }
                    k = close + 1;
                    continue;
                }
                if (m + 1 < toks.len and toks[m + 1].kind == .ident) {
                    try addExport(a, &exports, toks[m + 1].text, toks[m + 1].text);
                }
            }
        }
        k += 1;
    }

    var out: std.ArrayList(Function) = .empty;
    for (decls.items) |d| {
        var f: Function = .{ .name = d.name, .params = &.{}, .line = d.line, .exported = d.exported, .is_async = d.is_async };
        f.params = try parseJsParams(a, d, &f);
        f.returns = try returnType(a, d.ret, &f.is_async);
        if (exports.get(d.name)) |aliases| {
            for (aliases.items) |alias| {
                var copy = f;
                copy.name = alias;
                copy.exported = true;
                try out.append(a, copy);
            }
        } else try out.append(a, f);
    }
    return out.toOwnedSlice(a);
}

// ================================================================ Python

fn mapPyType(text_in: []const u8) struct { ParamType, bool } {
    var text = std.mem.trim(u8, text_in, " \t\r\n");
    var optional = false;
    if (std.mem.startsWith(u8, text, "Optional[") and std.mem.endsWith(u8, text, "]")) {
        text = text["Optional[".len .. text.len - 1];
        optional = true;
    }
    for ([_][]const u8{ "|None", "| None" }) |suffix| {
        if (std.mem.endsWith(u8, text, suffix)) {
            text = std.mem.trimEnd(u8, text[0 .. text.len - suffix.len], " ");
            optional = true;
        }
    }
    if (std.mem.startsWith(u8, text, "None|") or std.mem.startsWith(u8, text, "None |")) {
        text = std.mem.trim(u8, text[std.mem.indexOfScalar(u8, text, '|').? + 1 ..], " ");
        optional = true;
    }
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == ' ') continue;
        if (n == buf.len) return .{ .any, optional };
        buf[n] = c;
        n += 1;
    }
    const t = buf[0..n];
    if (std.mem.eql(u8, t, "int")) return .{ .int, optional };
    if (std.mem.eql(u8, t, "float")) return .{ .number, optional };
    if (std.mem.eql(u8, t, "str")) return .{ .string, optional };
    if (std.mem.eql(u8, t, "bool")) return .{ .bool, optional };
    const containers = [_][]const u8{ "list[", "List[", "Sequence[", "Iterable[", "tuple[", "Tuple[" };
    for (containers) |c| {
        if (std.mem.startsWith(u8, t, c) and std.mem.endsWith(u8, t, "]")) {
            var inner = t[c.len .. t.len - 1];
            if (std.mem.endsWith(u8, inner, ",...")) inner = inner[0 .. inner.len - 4];
            if (std.mem.eql(u8, inner, "int")) return .{ .int_array, optional };
            if (std.mem.eql(u8, inner, "float")) return .{ .number_array, optional };
            if (std.mem.eql(u8, inner, "str")) return .{ .string_array, optional };
        }
    }
    return .{ .any, optional };
}

fn pyLiteralType(text: []const u8) ?ParamType {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return null;
    if (std.mem.eql(u8, t, "True") or std.mem.eql(u8, t, "False")) return .bool;
    if (t[0] == '"' or t[0] == '\'') return .string;
    var s = t;
    if (s[0] == '-' or s[0] == '+') s = s[1..];
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return null;
    for (s) |c| {
        if (c == '.' or c == 'e' or c == 'E') return .number;
        if (!std.ascii.isDigit(c) and c != '_') return null;
    }
    return .int;
}

/// Splits on commas at bracket depth 0, ignoring commas inside strings.
fn splitTopLevel(a: Allocator, s: []const u8) ![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            '"', '\'' => {
                i += 1;
                while (i < s.len and s[i] != c) : (i += 1) {
                    if (s[i] == '\\') i += 1;
                }
            },
            ',' => if (depth == 0) {
                try parts.append(a, s[start..i]);
                start = i + 1;
            },
            else => {},
        }
    }
    try parts.append(a, s[start..]);
    return parts.toOwnedSlice(a);
}

const py_string_methods = [_][]const u8{
    "lower",      "upper",    "strip",  "lstrip", "rstrip",  "split",   "rsplit",  "splitlines", "startswith",
    "endswith",   "replace",  "find",   "rfind",  "isdigit", "isalpha", "isalnum", "isspace",    "title",
    "capitalize", "casefold", "encode", "zfill",  "center",  "ljust",   "rjust",   "partition",  "format",
    "isupper",    "islower",
};
const py_list_methods = [_][]const u8{ "append", "extend", "sort", "pop", "insert", "remove", "reverse" };

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn inferPyUsage(name: []const u8, body: []const u8) ParamType {
    var s: Scores = .{};
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, name)) |pos| {
        i = pos + name.len;
        if (pos > 0 and (isWordChar(body[pos - 1]) or body[pos - 1] == '.')) continue;
        if (i < body.len and isWordChar(body[i])) continue;
        const after = std.mem.trimStart(u8, body[i..@min(body.len, i + 24)], " ");
        const before = std.mem.trimEnd(u8, body[pos -| 24..pos], " ");
        if (after.len > 1 and after[0] == '.') {
            for (py_string_methods) |m| {
                if (std.mem.startsWith(u8, after[1..], m) and after.len > 1 + m.len and after[1 + m.len] == '(') s.str += 3;
            }
            for (py_list_methods) |m| {
                if (std.mem.startsWith(u8, after[1..], m) and after.len > 1 + m.len and after[1 + m.len] == '(') s.arr += 3;
            }
        }
        if (after.len > 0) {
            if (std.mem.startsWith(u8, after, "//") or (after[0] == '%' and !std.mem.startsWith(u8, after, "%s"))) s.int += 3;
            if (std.mem.startsWith(u8, after, "**") or after[0] == '*' or after[0] == '/' or after[0] == '-' or
                after[0] == '<' or after[0] == '>') s.num += 2;
            if (after[0] == '[') {
                s.str += 1;
                s.arr += 1;
            }
            if (after[0] == '+' and after.len > 1) {
                const rhs = std.mem.trimStart(u8, after[1..], " ");
                if (rhs.len > 0 and (rhs[0] == '"' or rhs[0] == '\'' or rhs[0] == 'f')) s.str += 2;
                if (rhs.len > 0 and std.ascii.isDigit(rhs[0])) s.num += 1;
            }
        }
        if (std.mem.endsWith(u8, before, "range(")) s.int += 3;
        if (std.mem.endsWith(u8, before, "math.sqrt(") or std.mem.endsWith(u8, before, "math.floor(") or
            std.mem.endsWith(u8, before, "abs(") or std.mem.endsWith(u8, before, "round(") or
            std.mem.endsWith(u8, before, "math.log(") or std.mem.endsWith(u8, before, "math.exp(")) s.num += 3;
        if (std.mem.endsWith(u8, before, "sum(") or std.mem.endsWith(u8, before, "sorted(") or
            std.mem.endsWith(u8, before, "max(") or std.mem.endsWith(u8, before, "min(")) s.arr += 1;
        if (std.mem.endsWith(u8, before, ".join(") and after.len > 0 and after[0] == ')') s.arr += 3;
        if (std.mem.endsWith(u8, before, " in")) s.arr += 1;
        if (std.mem.endsWith(u8, before, "not") or std.mem.endsWith(u8, before, "if")) s.boolean += 1;
        if (before.len > 0 and (before[before.len - 1] == '*' or before[before.len - 1] == '/' or before[before.len - 1] == '-')) s.num += 1;
    }
    const t = s.pick(name);
    return t;
}

fn scanPython(a: Allocator, src: []const u8) ![]Function {
    var out: std.ArrayList(Function) = .empty;
    // First pass: find line starts of top-level `def`, skipping triple-quoted
    // strings and lines inside open brackets.
    var i: usize = 0;
    var line_no: u32 = 1;
    var depth: usize = 0;
    var at_line_start = true;
    var defs: std.ArrayList(struct { pos: usize, line: u32 }) = .empty;
    while (i < src.len) {
        const c = src[i];
        if (at_line_start and depth == 0) {
            at_line_start = false;
            if (std.mem.startsWith(u8, src[i..], "def ") or std.mem.startsWith(u8, src[i..], "async def ")) {
                try defs.append(a, .{ .pos = i, .line = line_no });
            }
        }
        switch (c) {
            '\n' => {
                line_no += 1;
                at_line_start = true;
                i += 1;
            },
            '#' => {
                while (i < src.len and src[i] != '\n') i += 1;
            },
            '(', '[', '{' => {
                depth += 1;
                i += 1;
            },
            ')', ']', '}' => {
                depth -|= 1;
                i += 1;
            },
            '"', '\'' => {
                if (i + 2 < src.len and src[i + 1] == c and src[i + 2] == c) {
                    const delim = src[i .. i + 3];
                    i += 3;
                    while (i < src.len and !std.mem.startsWith(u8, src[i..], delim)) : (i += 1) {
                        if (src[i] == '\\') i += 1 else if (src[i] == '\n') line_no += 1;
                    }
                    i = @min(i + 3, src.len);
                } else {
                    i += 1;
                    while (i < src.len and src[i] != c and src[i] != '\n') : (i += 1) {
                        if (src[i] == '\\') i += 1;
                    }
                    i = @min(i + 1, src.len);
                }
            },
            else => i += 1,
        }
    }

    for (defs.items, 0..) |d, di| {
        var p = d.pos;
        var is_async = false;
        if (std.mem.startsWith(u8, src[p..], "async ")) {
            is_async = true;
            p += "async ".len;
        }
        p += "def ".len;
        const name_start = p;
        while (p < src.len and isWordChar(src[p])) p += 1;
        const name = src[name_start..p];
        while (p < src.len and src[p] == ' ') p += 1;
        if (p >= src.len or src[p] != '(') continue;
        // Matching paren.
        var dd: usize = 0;
        const open = p;
        while (p < src.len) : (p += 1) {
            if (src[p] == '(') dd += 1;
            if (src[p] == ')') {
                dd -= 1;
                if (dd == 0) break;
            }
        }
        if (p >= src.len) continue;
        const params_text = src[open + 1 .. p];
        // Return annotation up to the ':' that ends the signature.
        var q = p + 1;
        var ret_text: []const u8 = "";
        const colon = std.mem.indexOfScalarPos(u8, src, q, ':') orelse continue;
        const head = std.mem.trim(u8, src[q..colon], " \t");
        if (std.mem.startsWith(u8, head, "->")) ret_text = std.mem.trim(u8, head[2..], " \t");
        q = colon + 1;
        // Body: until the next top-level def, or the next non-indented code line.
        const next_def = if (di + 1 < defs.items.len) defs.items[di + 1].pos else src.len;
        var body_end = q;
        var scan_pos = q;
        while (scan_pos < next_def) {
            const nl = std.mem.indexOfScalarPos(u8, src, scan_pos, '\n') orelse next_def;
            const ln = src[scan_pos..@min(nl, next_def)];
            if (scan_pos != q and ln.len > 0 and ln[0] != ' ' and ln[0] != '\t' and ln[0] != '#' and
                std.mem.trim(u8, ln, " \t\r").len > 0 and ln[0] != ')' and ln[0] != ']' and ln[0] != '}') break;
            body_end = @min(nl, next_def);
            scan_pos = nl + 1;
        }
        const body = src[q..body_end];

        var f: Function = .{ .name = name, .params = &.{}, .line = d.line, .is_async = is_async, .exported = name.len > 0 and name[0] != '_' };
        var params: std.ArrayList(Param) = .empty;
        for (try splitTopLevel(a, params_text)) |raw| {
            const part = std.mem.trim(u8, raw, " \t\r\n");
            if (part.len == 0 or std.mem.eql(u8, part, "/") or std.mem.eql(u8, part, "*")) continue;
            if (part[0] == '*') {
                f.variadic = true;
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, part, '=');
            const decl = std.mem.trim(u8, if (eq) |e| part[0..e] else part, " \t");
            const default = if (eq) |e| part[e + 1 ..] else "";
            const colon_pos = std.mem.indexOfScalar(u8, decl, ':');
            const pname = std.mem.trim(u8, if (colon_pos) |cp| decl[0..cp] else decl, " \t");
            if (std.mem.eql(u8, pname, "self") or std.mem.eql(u8, pname, "cls")) continue;
            var param: Param = .{ .name = pname };
            var typed = false;
            if (colon_pos) |cp| {
                const mapped = mapPyType(decl[cp + 1 ..]);
                param.type = mapped[0];
                param.optional = mapped[1];
                typed = mapped[0] != .any;
            }
            if (!typed and eq != null) {
                if (pyLiteralType(default)) |lt| {
                    param.type = lt;
                    typed = true;
                } else if (std.mem.eql(u8, std.mem.trim(u8, default, " "), "None")) param.optional = true;
            }
            if (!typed) param.type = inferPyUsage(pname, body);
            try params.append(a, param);
        }
        f.params = try params.toOwnedSlice(a);
        if (ret_text.len > 0) {
            const mapped = mapPyType(ret_text);
            if (mapped[0] != .any) f.returns = mapped[0];
        }
        try out.append(a, f);
    }
    return out.toOwnedSlice(a);
}

// ================================================================= tests

const testing = std.testing;

fn findFn(fns: []const Function, name: []const u8) ?Function {
    for (fns) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

test "js: declarations, arrows and export forms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\// a comment with function fake(x) {}
        \\import x from "y";
        \\export function add(a, b) { return a + b * 1; }
        \\export const slugify = (text) => text.toLowerCase().split(' ').join('-');
        \\export const clamp = (value, lo = 0, hi = 1) => Math.min(Math.max(value, lo), hi);
        \\const re = /function nope\(/g;
        \\function helper(s) { return `${s}{}` + "}"; }
        \\export async function fetchIt(url) { return url; }
        \\const sq = x => x * x;
        \\export { helper, sq as square };
        \\export default function main() {}
    ;
    const fns = try scanJs(a, src);
    const add = findFn(fns, "add").?;
    try testing.expect(add.exported);
    try testing.expectEqual(@as(usize, 2), add.params.len);
    try testing.expectEqual(@as(u32, 3), add.line);
    const slug = findFn(fns, "slugify").?;
    try testing.expectEqual(ParamType.string, slug.params[0].type);
    const clamp = findFn(fns, "clamp").?;
    try testing.expectEqual(ParamType.number, clamp.params[0].type);
    try testing.expectEqual(ParamType.number, clamp.params[1].type);
    try testing.expect(findFn(fns, "helper").?.exported);
    try testing.expect(findFn(fns, "fake") == null);
    try testing.expect(findFn(fns, "nope") == null);
    try testing.expect(findFn(fns, "fetchIt").?.is_async);
    const square = findFn(fns, "square").?;
    try testing.expectEqual(ParamType.number, square.params[0].type);
    try testing.expect(findFn(fns, "sq") == null);
    try testing.expect(findFn(fns, "main") != null);
}

test "js: commonjs exports" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\function a(str) { return str.trim(); }
        \\function b(n) { return n % 2; }
        \\function hidden() {}
        \\exports.c = function (words) { return words.join(","); };
        \\module.exports = { a, bee: b };
    ;
    const fns = try scanJs(a, src);
    try testing.expect(findFn(fns, "a").?.exported);
    try testing.expectEqual(ParamType.string, findFn(fns, "a").?.params[0].type);
    try testing.expect(findFn(fns, "bee").?.exported);
    try testing.expect(!findFn(fns, "hidden").?.exported);
    try testing.expectEqual(ParamType.string_array, findFn(fns, "c").?.params[0].type);
}

test "ts: annotations, optionals, return types, overloads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\export function score(query: string, items: readonly string[], limit?: number): number {
        \\  return 0;
        \\}
        \\export function pick(x: number): number;
        \\export function pick(x: string): string;
        \\export function pick(x: any): any { return x; }
        \\export const mean = (xs: Array<number>, opts: { skip: boolean } = { skip: false }): number => 0;
        \\export async function later(n: number | undefined): Promise<string> { return ""; }
        \\export function obj(): { a: number } { return { a: 1 }; }
    ;
    const fns = try scanJs(a, src);
    const s = findFn(fns, "score").?;
    try testing.expectEqual(ParamType.string, s.params[0].type);
    try testing.expectEqual(ParamType.string_array, s.params[1].type);
    try testing.expectEqual(ParamType.number, s.params[2].type);
    try testing.expect(s.params[2].optional);
    try testing.expectEqual(ParamType.number, s.returns.?);
    var picks: usize = 0;
    for (fns) |f| if (std.mem.eql(u8, f.name, "pick")) {
        picks += 1;
    };
    try testing.expectEqual(@as(usize, 1), picks);
    const m = findFn(fns, "mean").?;
    try testing.expectEqual(ParamType.number_array, m.params[0].type);
    try testing.expectEqual(ParamType.any, m.params[1].type);
    const l = findFn(fns, "later").?;
    try testing.expect(l.is_async and l.params[0].optional);
    try testing.expectEqual(ParamType.string, l.returns.?);
    try testing.expect(findFn(fns, "obj") != null);
}

test "python: top-level defs, annotations, usage and docstrings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\"""Module docstring.
        \\def not_a_function(x):
        \\"""
        \\import math
        \\
        \\def mean(values: list[float]) -> float:
        \\    return sum(values) / len(values)
        \\
        \\def slugify(text, sep="-"):
        \\    return sep.join(text.lower().split())
        \\
        \\class Thing:
        \\    def method(self, x):
        \\        return x
        \\
        \\def fizz(n, *args, verbose=False, **kw):
        \\    for i in range(n):
        \\        pass
        \\
        \\def _private(
        \\    a: Optional[int],
        \\    b: str | None = None,
        \\) -> List[str]:
        \\    return []
        \\
        \\async def get(url: str) -> dict:
        \\    return {}
    ;
    const fns = try scanPython(a, src);
    try testing.expect(findFn(fns, "not_a_function") == null);
    try testing.expect(findFn(fns, "method") == null);
    const m = findFn(fns, "mean").?;
    try testing.expectEqual(ParamType.number_array, m.params[0].type);
    try testing.expectEqual(ParamType.number, m.returns.?);
    const s = findFn(fns, "slugify").?;
    try testing.expectEqual(ParamType.string, s.params[0].type);
    try testing.expectEqual(ParamType.string, s.params[1].type);
    const f = findFn(fns, "fizz").?;
    try testing.expect(f.variadic);
    try testing.expectEqual(@as(usize, 2), f.params.len);
    try testing.expectEqual(ParamType.int, f.params[0].type);
    try testing.expectEqual(ParamType.bool, f.params[1].type);
    const p = findFn(fns, "_private").?;
    try testing.expect(!p.exported);
    try testing.expectEqual(ParamType.int, p.params[0].type);
    try testing.expect(p.params[0].optional and p.params[1].optional);
    try testing.expectEqual(ParamType.string_array, p.returns.?);
    try testing.expect(findFn(fns, "get").?.is_async);
}

test "name heuristics" {
    try testing.expectEqual(ParamType.bool, nameHeuristic("isActive"));
    try testing.expectEqual(ParamType.string, nameHeuristic("userName"));
    try testing.expectEqual(ParamType.int, nameHeuristic("max_count"));
    try testing.expectEqual(ParamType.number, nameHeuristic("threshold"));
    try testing.expectEqual(ParamType.string_array, nameHeuristic("words"));
    try testing.expectEqual(ParamType.any, nameHeuristic("thing"));
}

test "ts type mapping" {
    try testing.expectEqual(ParamType.number, mapTsType("number")[0]);
    try testing.expect(mapTsType("string|null")[1]);
    try testing.expectEqual(ParamType.any, mapTsType("string|number")[0]);
    try testing.expectEqual(ParamType.number_array, mapTsType("readonlynumber[]")[0]);
}
