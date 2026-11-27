//! Node-API (N-API) runtime for `zig-anything bridge`.
//!
//! Copied into a function unit as src/napi.zig and compiled, together with a
//! generated src/bridge_node.zig, into `bridge/port.node`: a native Node
//! addon that calls the port with no JSON in between.
//!
//!   * Arguments are converted straight from JS values to the port's
//!     parameter types (read at compile time), and results straight back.
//!   * A TypedArray passed to a numeric slice parameter of the same element
//!     type (`Float64Array` -> `[]const f64`, `Int32Array` -> `[]i32`, ...)
//!     is borrowed, not copied, when its memory is suitably aligned. The port
//!     sees the caller's memory for the duration of the call only.
//!   * A plain JS array passed to a mutable slice parameter is copied in and,
//!     after the call, copied back element by element, so in-place changes
//!     the port makes are visible to the caller as they would be in JS.
//!   * Per-thread arenas are kept between calls, so a warm call allocates
//!     almost nothing.
//!
//! The addon needs no Node headers or import library: the N-API functions are
//! looked up in the host process when the module loads (GetProcAddress on
//! Windows, dlsym elsewhere). If that fails, loading the addon fails and
//! index.mjs falls back to the WebAssembly build.
//!
//! Do not edit the copy inside a unit; `zig-anything bridge` rewrites it.

const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------- N-API ABI

pub const Env = *opaque {};
pub const Value = *opaque {};
pub const CallbackInfo = *opaque {};
const Status = c_int; // napi_ok == 0
const Callback = *const fn (Env, CallbackInfo) callconv(.c) ?Value;

const ValueType = enum(c_int) { undefined, null, boolean, number, string, symbol, object, function, external, bigint, _ };
const TypedArrayType = enum(c_int) { int8, uint8, uint8_clamped, int16, uint16, int32, uint32, float32, float64, bigint64, biguint64, _ };

/// The N-API functions this runtime uses. Each field `x` is resolved from the
/// host process as the symbol `napi_x`.
const Api = struct {
    get_cb_info: *const fn (Env, CallbackInfo, *usize, ?[*]Value, ?*Value, ?*?*anyopaque) callconv(.c) Status,
    typeof: *const fn (Env, Value, *ValueType) callconv(.c) Status,
    get_value_double: *const fn (Env, Value, *f64) callconv(.c) Status,
    get_value_bool: *const fn (Env, Value, *bool) callconv(.c) Status,
    get_value_string_utf8: *const fn (Env, Value, ?[*]u8, usize, ?*usize) callconv(.c) Status,
    is_array: *const fn (Env, Value, *bool) callconv(.c) Status,
    get_array_length: *const fn (Env, Value, *u32) callconv(.c) Status,
    get_element: *const fn (Env, Value, u32, *Value) callconv(.c) Status,
    set_element: *const fn (Env, Value, u32, Value) callconv(.c) Status,
    is_typedarray: *const fn (Env, Value, *bool) callconv(.c) Status,
    get_typedarray_info: *const fn (Env, Value, *TypedArrayType, *usize, ?*?*anyopaque, ?*Value, ?*usize) callconv(.c) Status,
    get_named_property: *const fn (Env, Value, [*:0]const u8, *Value) callconv(.c) Status,
    set_named_property: *const fn (Env, Value, [*:0]const u8, Value) callconv(.c) Status,
    get_property_names: *const fn (Env, Value, *Value) callconv(.c) Status,
    get_property: *const fn (Env, Value, Value, *Value) callconv(.c) Status,
    set_property: *const fn (Env, Value, Value, Value) callconv(.c) Status,
    create_double: *const fn (Env, f64, *Value) callconv(.c) Status,
    get_boolean: *const fn (Env, bool, *Value) callconv(.c) Status,
    create_string_utf8: *const fn (Env, [*]const u8, usize, *Value) callconv(.c) Status,
    create_array_with_length: *const fn (Env, usize, *Value) callconv(.c) Status,
    create_object: *const fn (Env, *Value) callconv(.c) Status,
    get_null: *const fn (Env, *Value) callconv(.c) Status,
    get_undefined: *const fn (Env, *Value) callconv(.c) Status,
    get_global: *const fn (Env, *Value) callconv(.c) Status,
    new_instance: *const fn (Env, Value, usize, ?[*]const Value, *Value) callconv(.c) Status,
    instanceof: *const fn (Env, Value, Value, *bool) callconv(.c) Status,
    throw: *const fn (Env, Value) callconv(.c) Status,
    throw_type_error: *const fn (Env, ?[*:0]const u8, [*:0]const u8) callconv(.c) Status,
    create_function: *const fn (Env, [*]const u8, usize, Callback, ?*anyopaque, *Value) callconv(.c) Status,
    is_exception_pending: *const fn (Env, *bool) callconv(.c) Status,
};

var api: Api = undefined;
var api_loaded = false;

const win = struct {
    extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
};

/// The handle `dlsym` searches for symbols already loaded into the process.
const rtld_default: ?*anyopaque = switch (builtin.os.tag) {
    .linux => null,
    else => @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))), // macOS and the BSDs
};

fn lookup(name: [*:0]const u8) ?*anyopaque {
    if (builtin.os.tag == .windows) {
        // N-API is exported by the executable that hosts Node (node.exe,
        // or an embedder such as Electron).
        const exe = win.GetModuleHandleW(null) orelse return null;
        return win.GetProcAddress(exe, name);
    }
    return std.c.dlsym(rtld_default, name);
}

fn loadApi() bool {
    if (api_loaded) return true;
    inline for (@typeInfo(Api).@"struct".field_names, @typeInfo(Api).@"struct".field_types) |name, T| {
        const sym = lookup(comptime std.fmt.comptimePrint("napi_{s}", .{name})) orelse return false;
        @field(api, name) = @as(T, @ptrCast(@alignCast(sym)));
    }
    api_loaded = true;
    return true;
}

// ---------------------------------------------------------------- errors

/// `Js`: an N-API call failed, and a JS exception is (or will be made) pending.
const Fail = error{ TypeMismatch, OutOfMemory, Js };

fn check(s: Status) Fail!void {
    if (s != 0) return error.Js;
}

/// Turns a failure into a pending JS exception (unless one is pending).
fn throwFail(env: Env, err: Fail, what: [*:0]const u8) void {
    var pending = false;
    _ = api.is_exception_pending(env, &pending);
    if (pending) return;
    _ = api.throw_type_error(env, null, switch (err) {
        error.TypeMismatch => what,
        error.OutOfMemory => "zig-anything bridge: out of memory",
        error.Js => "zig-anything bridge: a Node-API call failed",
    });
}

/// Throws the error the port returned, as the JS error with the same name
/// when one exists (`RangeError`, `TypeError`, ...), otherwise as `Error`.
/// The Zig error name is kept in the `zigError` property.
fn throwPortError(env: Env, name: [:0]const u8) void {
    throwPortErrorInner(env, name) catch {
        var pending = false;
        _ = api.is_exception_pending(env, &pending);
        if (!pending) _ = api.throw_type_error(env, null, name.ptr);
    };
}

fn throwPortErrorInner(env: Env, name: [:0]const u8) Fail!void {
    var global: Value = undefined;
    try check(api.get_global(env, &global));
    var error_ctor: Value = undefined;
    try check(api.get_named_property(env, global, "Error", &error_ctor));
    var ctor = error_ctor;
    var candidate: Value = undefined;
    if (api.get_named_property(env, global, name.ptr, &candidate) == 0 and typeOf(env, candidate) == .function) {
        // Use it only if it is an Error subclass, decided without calling it.
        var proto: Value = undefined;
        var is_error = false;
        if (api.get_named_property(env, candidate, "prototype", &proto) == 0 and
            api.instanceof(env, proto, error_ctor, &is_error) == 0 and is_error) ctor = candidate;
    }
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} (from the Zig port)", .{name}) catch name;
    var msg_v: Value = undefined;
    try check(api.create_string_utf8(env, msg.ptr, msg.len, &msg_v));
    var err_v: Value = undefined;
    try check(api.new_instance(env, ctor, 1, &.{msg_v}, &err_v));
    var name_v: Value = undefined;
    try check(api.create_string_utf8(env, name.ptr, name.len, &name_v));
    try check(api.set_named_property(env, err_v, "zigError", name_v));
    try check(api.throw(env, err_v));
}

// ---------------------------------------------------------------- JS -> Zig

fn typeOf(env: Env, v: Value) ValueType {
    var t: ValueType = .undefined;
    _ = api.typeof(env, v, &t);
    return t;
}

fn typedArrayKind(comptime T: type) ?TypedArrayType {
    return switch (T) {
        i8 => .int8,
        u8 => .uint8,
        i16 => .int16,
        u16 => .uint16,
        i32 => .int32,
        u32 => .uint32,
        f32 => .float32,
        f64 => .float64,
        i64 => .bigint64,
        u64 => .biguint64,
        else => null,
    };
}

/// Borrows the memory of a TypedArray whose element type is `T`. Null when
/// the value is not such an array or its memory is not aligned for `T`.
fn borrowTyped(comptime T: type, env: Env, v: Value) ?[]T {
    const want = comptime typedArrayKind(T) orelse return null;
    // BigInt arrays hold BigInts, which the original sees as a different
    // type from numbers; never treat them as numeric slices.
    if (comptime (want == .bigint64 or want == .biguint64)) return null;
    var is_typed = false;
    if (api.is_typedarray(env, v, &is_typed) != 0 or !is_typed) return null;
    var kind: TypedArrayType = undefined;
    var len: usize = 0;
    var data: ?*anyopaque = null;
    if (api.get_typedarray_info(env, v, &kind, &len, &data, null, null) != 0) return null;
    if (kind != want) return null;
    if (len == 0) return &.{};
    const p = data orelse return null;
    if (@intFromPtr(p) % @alignOf(T) != 0) return null;
    const many: [*]T = @ptrCast(@alignCast(p));
    return many[0..len];
}

// napi_status values that mean "wrong JS type".
const string_expected: Status = 3;
const number_expected: Status = 6;
const boolean_expected: Status = 7;

/// Bytes tried in one call before asking for a string's exact length.
const short_string = 256;

fn getString(a: Allocator, env: Env, v: Value) Fail![]u8 {
    // One call for short strings (the common case): copy straight into the
    // arena, and let the status say whether `v` is a string at all.
    const first = try a.alloc(u8, short_string);
    var written: usize = 0;
    const s = api.get_value_string_utf8(env, v, first.ptr, first.len, &written);
    if (s == string_expected) return error.TypeMismatch;
    try check(s);
    // A truncated copy stops at a character boundary, so it can end up to 3
    // bytes short of the buffer (which also holds a NUL). Shorter is complete.
    if (written + 4 < first.len) return first[0..written];
    var len: usize = 0;
    try check(api.get_value_string_utf8(env, v, null, 0, &len));
    if (len + 1 <= first.len) {
        try check(api.get_value_string_utf8(env, v, first.ptr, first.len, &written));
        return first[0..written];
    }
    const buf = try a.alloc(u8, len + 1);
    try check(api.get_value_string_utf8(env, v, buf.ptr, buf.len, &written));
    return buf[0..written];
}

fn arrayLength(env: Env, v: Value) Fail!?u32 {
    var is_arr = false;
    try check(api.is_array(env, v, &is_arr));
    if (!is_arr) {
        // TypedArrays are read element by element when they cannot be borrowed.
        var is_typed = false;
        try check(api.is_typedarray(env, v, &is_typed));
        if (!is_typed) return null;
        var kind: TypedArrayType = undefined;
        var len: usize = 0;
        try check(api.get_typedarray_info(env, v, &kind, &len, null, null, null));
        if (kind == .bigint64 or kind == .biguint64) return null;
        return std.math.cast(u32, len) orelse error.TypeMismatch;
    }
    var n: u32 = 0;
    try check(api.get_array_length(env, v, &n));
    return n;
}

fn toF64(env: Env, v: Value) Fail!f64 {
    var x: f64 = 0;
    const s = api.get_value_double(env, v, &x);
    if (s == number_expected) return error.TypeMismatch;
    try check(s);
    return x;
}

/// How a slice argument reached the port, for copying mutations back.
const Origin = enum { none, borrowed, copied };

/// Converts a JS value into the Zig type `T`, allocating from `a`.
pub fn fromJs(comptime T: type, a: Allocator, env: Env, v: Value, origin: *Origin) Fail!T {
    if (T == json.Value) return toJsonValue(a, env, v);
    switch (@typeInfo(T)) {
        .bool => {
            var b = false;
            const s = api.get_value_bool(env, v, &b);
            if (s == boolean_expected) return error.TypeMismatch;
            try check(s);
            return b;
        },
        .float => return @floatCast(try toF64(env, v)),
        .int => {
            const x = try toF64(env, v);
            if (!std.math.isFinite(x) or x != @trunc(x)) return error.TypeMismatch;
            if (x < @as(f64, @floatFromInt(std.math.minInt(T))) or x > @as(f64, @floatFromInt(std.math.maxInt(T)))) return error.TypeMismatch;
            return @intFromFloat(x);
        },
        .optional => |o| {
            const t = typeOf(env, v);
            if (t == .undefined or t == .null) return null;
            return try fromJs(o.child, a, env, v, origin);
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("unsupported parameter type " ++ @typeName(T));
            if (p.child == u8) return getString(a, env, v);
            if (borrowTyped(p.child, env, v)) |s| {
                origin.* = .borrowed;
                return s;
            }
            const n = (try arrayLength(env, v)) orelse return error.TypeMismatch;
            const out = try a.alloc(p.child, n);
            var ignored: Origin = .none;
            for (out, 0..) |*slot, i| {
                var item: Value = undefined;
                try check(api.get_element(env, v, @intCast(i), &item));
                slot.* = try fromJs(p.child, a, env, item, &ignored);
            }
            origin.* = .copied;
            return out;
        },
        .@"enum" => |e| {
            var buf: [256]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&buf);
            const s = getString(fba.allocator(), env, v) catch |err| switch (err) {
                error.OutOfMemory => return error.TypeMismatch, // longer than any tag
                else => return err,
            };
            inline for (e.field_names) |name| {
                if (std.mem.eql(u8, name, s)) return @field(T, name);
            }
            return error.TypeMismatch;
        },
        .@"struct" => |s| {
            if (typeOf(env, v) != .object) return error.TypeMismatch;
            var out: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |name, FT, attrs| {
                var fv: Value = undefined;
                try check(api.get_named_property(env, v, name.ptr, &fv));
                if (typeOf(env, fv) != .undefined) {
                    var ignored: Origin = .none;
                    @field(out, name) = try fromJs(FT, a, env, fv, &ignored);
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

/// Converts any JSON-shaped JS value into a `std.json.Value`, the way the
/// recorder would have written it (non-finite numbers as `{"$num": ...}`).
fn toJsonValue(a: Allocator, env: Env, v: Value) Fail!json.Value {
    switch (typeOf(env, v)) {
        .undefined, .null => return .null,
        .boolean => {
            var b = false;
            try check(api.get_value_bool(env, v, &b));
            return .{ .bool = b };
        },
        .number => {
            const x = try toF64(env, v);
            if (!std.math.isFinite(x)) {
                var obj: json.ObjectMap = .empty;
                try obj.put(a, "$num", .{ .string = if (std.math.isNan(x)) "NaN" else if (x > 0) "Infinity" else "-Infinity" });
                return .{ .object = obj };
            }
            if (x == @trunc(x) and @abs(x) <= 9007199254740992) return .{ .integer = @intFromFloat(x) };
            return .{ .float = x };
        },
        .string => return .{ .string = try getString(a, env, v) },
        .object => {
            if (try arrayLength(env, v)) |n| {
                var arr: json.Array = .init(a);
                try arr.ensureTotalCapacity(n);
                for (0..n) |i| {
                    var item: Value = undefined;
                    try check(api.get_element(env, v, @intCast(i), &item));
                    arr.appendAssumeCapacity(try toJsonValue(a, env, item));
                }
                return .{ .array = arr };
            }
            var keys: Value = undefined;
            try check(api.get_property_names(env, v, &keys));
            var n: u32 = 0;
            try check(api.get_array_length(env, keys, &n));
            var obj: json.ObjectMap = .empty;
            for (0..n) |i| {
                var key: Value = undefined;
                try check(api.get_element(env, keys, @intCast(i), &key));
                var val: Value = undefined;
                try check(api.get_property(env, v, key, &val));
                const t = typeOf(env, val);
                if (t == .undefined or t == .function or t == .symbol) continue; // JSON.stringify drops these
                try obj.put(a, try getString(a, env, key), try toJsonValue(a, env, val));
            }
            return .{ .object = obj };
        },
        else => return error.TypeMismatch,
    }
}

// ---------------------------------------------------------------- Zig -> JS

fn newString(env: Env, s: []const u8) Fail!Value {
    var out: Value = undefined;
    try check(api.create_string_utf8(env, s.ptr, s.len, &out));
    return out;
}

fn newNumber(env: Env, x: f64) Fail!Value {
    var out: Value = undefined;
    try check(api.create_double(env, x, &out));
    return out;
}

fn newNull(env: Env) Fail!Value {
    var out: Value = undefined;
    try check(api.get_null(env, &out));
    return out;
}

fn newArray(env: Env, items: anytype) Fail!Value {
    var out: Value = undefined;
    try check(api.create_array_with_length(env, items.len, &out));
    for (items, 0..) |item, i| try check(api.set_element(env, out, @intCast(i), try toJs(env, item)));
    return out;
}

/// Converts a port return value (any type `rt.encode` accepts) into a JS value.
pub fn toJs(env: Env, value: anytype) Fail!Value {
    const T = @TypeOf(value);
    if (T == json.Value) return jsonToJs(env, value);
    switch (@typeInfo(T)) {
        .void => {
            var out: Value = undefined;
            try check(api.get_undefined(env, &out));
            return out;
        },
        .null => return newNull(env),
        .bool => {
            var out: Value = undefined;
            try check(api.get_boolean(env, value, &out));
            return out;
        },
        .int, .comptime_int => return newNumber(env, @floatFromInt(value)),
        .float, .comptime_float => return newNumber(env, @floatCast(value)),
        .optional => return if (value) |inner| toJs(env, inner) else newNull(env),
        .@"enum" => return newString(env, @tagName(value)),
        .pointer => |p| switch (p.size) {
            .slice => return if (p.child == u8) newString(env, value) else newArray(env, value),
            .one => switch (@typeInfo(p.child)) {
                .array => |arr| return if (arr.child == u8) newString(env, value) else newArray(env, value),
                else => return toJs(env, value.*),
            },
            else => @compileError("cannot return " ++ @typeName(T)),
        },
        .array => |arr| return if (arr.child == u8) newString(env, &value) else newArray(env, &value),
        .@"struct" => |s| {
            var out: Value = undefined;
            if (s.is_tuple) {
                try check(api.create_array_with_length(env, s.field_names.len, &out));
                inline for (s.field_names, 0..) |name, i| try check(api.set_element(env, out, i, try toJs(env, @field(value, name))));
                return out;
            }
            try check(api.create_object(env, &out));
            inline for (s.field_names) |name| try check(api.set_named_property(env, out, name.ptr, try toJs(env, @field(value, name))));
            return out;
        },
        else => @compileError("cannot return " ++ @typeName(T)),
    }
}

fn jsonToJs(env: Env, v: json.Value) Fail!Value {
    switch (v) {
        .null => return newNull(env),
        .bool => |b| return toJs(env, b),
        .integer => |i| return newNumber(env, @floatFromInt(i)),
        .float => |f| return newNumber(env, f),
        .number_string => |s| return newNumber(env, std.fmt.parseFloat(f64, s) catch std.math.nan(f64)),
        .string => |s| return newString(env, s),
        .array => |arr| return newArray(env, arr.items),
        .object => |obj| {
            if (obj.count() == 1) if (obj.get("$num")) |tag| if (tag == .string) {
                const x: ?f64 = if (std.mem.eql(u8, tag.string, "NaN")) std.math.nan(f64) else if (std.mem.eql(u8, tag.string, "Infinity")) std.math.inf(f64) else if (std.mem.eql(u8, tag.string, "-Infinity")) -std.math.inf(f64) else null;
                if (x) |n| return newNumber(env, n);
            };
            var out: Value = undefined;
            try check(api.create_object(env, &out));
            for (obj.keys(), obj.values()) |k, item| try check(api.set_property(env, out, try newString(env, k), try jsonToJs(env, item)));
            return out;
        },
    }
}

// ---------------------------------------------------------------- the addon

fn isInjected(comptime P: type) bool {
    return P == Allocator or P == *Io.Writer;
}

fn dataArity(comptime F: type) comptime_int {
    var n: comptime_int = 0;
    for (@typeInfo(F).@"fn".param_types) |P| {
        if (!isInjected(P.?)) n += 1;
    }
    return n;
}

fn isMutableSlice(comptime P: type) bool {
    return switch (@typeInfo(P)) {
        .pointer => |p| p.size == .slice and !p.attrs.@"const" and p.child != u8,
        .optional => |o| isMutableSlice(o.child),
        else => false,
    };
}

/// The addon for port function `f`. The generated src/bridge_node.zig
/// exports `init` as `napi_register_module_v1`, which Node calls on load.
pub fn Addon(comptime f: anytype) type {
    const F = @TypeOf(f);
    const params = @typeInfo(F).@"fn".param_types;
    const R = @typeInfo(F).@"fn".return_type.?;
    const arity = dataArity(F);

    return struct {
        const gpa: Allocator = std.heap.smp_allocator;
        // Kept between calls; Node can call from worker threads too.
        threadlocal var state: std.heap.ArenaAllocator.State = .init;
        const keep_bytes = 1 << 20;

        pub fn init(env: Env, exports: Value) callconv(.c) ?Value {
            if (!loadApi()) return null;
            define(env, exports, "call", call) catch return null;
            define(env, exports, "callBatch", callBatch) catch return null;
            return exports;
        }

        fn define(env: Env, exports: Value, comptime name: [:0]const u8, cb: Callback) Fail!void {
            var fn_v: Value = undefined;
            try check(api.create_function(env, name.ptr, name.len, cb, null, &fn_v));
            try check(api.set_named_property(env, exports, name.ptr, fn_v));
        }

        /// `call(...args)`: one call of the port.
        fn call(env: Env, info: CallbackInfo) callconv(.c) ?Value {
            var argv: [@max(arity, 1)]Value = undefined;
            var argc: usize = arity;
            if (api.get_cb_info(env, info, &argc, &argv, null, null) != 0) {
                throwFail(env, error.Js, "");
                return null;
            }
            if (argc < arity) {
                // Missing trailing arguments are `undefined`, as in JS.
                var undef: Value = undefined;
                _ = api.get_undefined(env, &undef);
                for (argv[argc..arity]) |*slot| slot.* = undef;
            }
            var arena = state.promote(gpa);
            defer {
                _ = arena.reset(.{ .retain_with_limit = keep_bytes });
                state = arena.state;
            }
            return invoke(env, arena.allocator(), argv[0..arity]);
        }

        /// `callBatch(listOfArgumentArrays)`: many calls in one crossing.
        fn callBatch(env: Env, info: CallbackInfo) callconv(.c) ?Value {
            var list: Value = undefined;
            var argc: usize = 1;
            if (api.get_cb_info(env, info, &argc, @ptrCast(&list), null, null) != 0 or argc < 1) {
                throwFail(env, error.TypeMismatch, "zig-anything bridge: expected an array of argument arrays");
                return null;
            }
            return batch(env, list) catch |err| {
                throwFail(env, err, "zig-anything bridge: expected an array of argument arrays");
                return null;
            };
        }

        fn batch(env: Env, list: Value) Fail!?Value {
            const n = (try arrayLength(env, list)) orelse return error.TypeMismatch;
            var out: Value = undefined;
            try check(api.create_array_with_length(env, n, &out));
            var arena = state.promote(gpa);
            defer {
                _ = arena.reset(.{ .retain_with_limit = keep_bytes });
                state = arena.state;
            }
            var argv: [@max(arity, 1)]Value = undefined;
            var undef: Value = undefined;
            try check(api.get_undefined(env, &undef));
            for (0..n) |i| {
                defer _ = arena.reset(.retain_capacity);
                var args: Value = undefined;
                try check(api.get_element(env, list, @intCast(i), &args));
                const m = (try arrayLength(env, args)) orelse return error.TypeMismatch;
                for (argv[0..arity], 0..) |*slot, j| {
                    if (j < m) try check(api.get_element(env, args, @intCast(j), slot)) else slot.* = undef;
                }
                const r = invoke(env, arena.allocator(), argv[0..arity]) orelse return null; // exception pending
                try check(api.set_element(env, out, @intCast(i), r));
            }
            return out;
        }

        /// Converts the arguments, calls the port, copies mutated arrays
        /// back and converts the result. Null means a JS exception is pending.
        fn invoke(env: Env, a: Allocator, argv: []const Value) ?Value {
            var discard: Io.Writer.Discarding = .init(&.{});
            var tuple: std.meta.ArgsTuple(F) = undefined;
            var origins: [@max(params.len, 1)]Origin = @splat(.none);
            comptime var j: usize = 0;
            inline for (params, 0..) |P, i| {
                if (P.? == Allocator) {
                    tuple[i] = a;
                } else if (P.? == *Io.Writer) {
                    tuple[i] = &discard.writer;
                } else {
                    tuple[i] = fromJs(P.?, a, env, argv[j], &origins[i]) catch |err| {
                        throwFail(env, err, comptime std.fmt.comptimePrint("zig-anything bridge: argument {d} must be {s}", .{ j + 1, describe(P.?) }));
                        return null;
                    };
                    j += 1;
                }
            }
            const result = @call(.auto, f, tuple);
            writeBack(env, tuple, &origins, argv) catch |err| {
                throwFail(env, err, "zig-anything bridge: cannot copy a mutated argument back");
                return null;
            };
            const ok = if (comptime @typeInfo(R) == .error_union) result catch |err| {
                throwPortError(env, @errorName(err));
                return null;
            } else result;
            return toJs(env, ok) catch |err| {
                throwFail(env, err, "zig-anything bridge: cannot convert the result");
                return null;
            };
        }

        fn writeBack(env: Env, tuple: std.meta.ArgsTuple(F), origins: []const Origin, argv: []const Value) Fail!void {
            inline for (params, 0..) |P, i| {
                if (comptime !isInjected(P.?) and isMutableSlice(P.?)) {
                    const js_arg = argv[comptime argIndex(i)];
                    const maybe: ?NonOptional(P.?) = tuple[i];
                    if (origins[i] == .copied) if (maybe) |slice| {
                        for (slice, 0..) |item, k| try check(api.set_element(env, js_arg, @intCast(k), try toJs(env, item)));
                    };
                }
            }
        }

        /// Position among the JS arguments of the port's parameter `i`.
        fn argIndex(comptime i: usize) usize {
            var j: usize = 0;
            for (params[0..i]) |P| {
                if (!isInjected(P.?)) j += 1;
            }
            return j;
        }
    };
}

fn NonOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

fn describe(comptime T: type) []const u8 {
    if (T == json.Value) return "a JSON value";
    return switch (@typeInfo(T)) {
        .bool => "a boolean",
        .int => "an integer",
        .float => "a number",
        .optional => |o| describe(o.child) ++ " or null",
        .pointer => |p| if (p.child == u8) "a string" else "an array",
        .@"enum" => "one of the allowed strings",
        .@"struct" => "an object",
        else => "a supported value",
    };
}

test "typed array kinds match element types" {
    try std.testing.expectEqual(TypedArrayType.float64, typedArrayKind(f64).?);
    try std.testing.expectEqual(TypedArrayType.int32, typedArrayKind(i32).?);
    try std.testing.expectEqual(@as(?TypedArrayType, null), typedArrayKind(bool));
    try std.testing.expect(isMutableSlice([]f64));
    try std.testing.expect(!isMutableSlice([]const f64));
    try std.testing.expect(!isMutableSlice([]u8));
    try std.testing.expectEqual(2, dataArity(fn (Allocator, []const u8, i64) i64));
}

test "addon compiles for a representative signature" {
    const S = struct { x: f64, tag: ?[]const u8 = null };
    const E = enum { a, b };
    const port = struct {
        fn f(a: Allocator, s: []const u8, xs: []f64, p: S, e: E, j: json.Value) !struct { []const u8, f64 } {
            _ = a;
            _ = p;
            _ = e;
            _ = j;
            if (xs.len == 0) return error.Empty;
            return .{ s, xs[0] };
        }
    };
    _ = &Addon(port.f).init;
}
