//! Language adapters: everything that differs between source languages lives
//! behind this one table, so the commands never branch on the language.
//!
//! Adding a source language means:
//!   1. a `Language` tag in lang.zig (plus its file extensions),
//!   2. a file in src/adapters/ that fills in an `Adapter`,
//!   3. a recorder script in src/assets/ that speaks the protocol in
//!      docs/ARCHITECTURE.md (run, bench, cover modes), and
//!   4. one line in `forLanguage` below.

const std = @import("std");
const lang = @import("lang.zig");
const config = @import("config.zig");
const Allocator = std.mem.Allocator;

pub const BridgeKind = enum {
    /// Node: a native N-API addon (`port.node`) with a WebAssembly fallback.
    node,
    /// Python: a native shared library loaded with ctypes.
    python,
};

pub const EnvVar = struct { name: []const u8, value: []const u8 };

pub const Adapter = struct {
    /// Runtime name shown to the user ("node", "python").
    runtime: []const u8,
    /// File name of the embedded recorder, written into the unit's .za/.
    recorder_name: []const u8,
    /// The recorder script itself.
    recorder: []const u8,
    /// The configured command prefix that runs this language.
    command: *const fn (cfg: config.Config) []const []const u8,
    /// Environment variables set for every recorder run.
    env: []const EnvVar,
    /// Printed when the runtime cannot be started.
    missing_hint: []const u8,
    /// Finds top-level functions in a source file.
    scan: *const fn (a: Allocator, src: []const u8) anyerror![]lang.Function,
    /// True when the recorder can only reach exported functions.
    requires_export: bool,
    bridge: BridgeKind,
    /// Every number in the language is an IEEE double (JavaScript), so
    /// recorded integers are compared as doubles.
    numbers_are_doubles: bool,
    /// Extra runtime arguments that turn on the side-effect guard (sandbox),
    /// given the directory the recorder may write to. Empty when the guard
    /// lives inside the recorder script instead.
    sandbox_args: *const fn (a: Allocator, writable_dir: []const u8) anyerror![]const []const u8,
};

const javascript = @import("adapters/javascript.zig");
const python = @import("adapters/python.zig");

pub fn forLanguage(l: lang.Language) *const Adapter {
    return switch (l) {
        .javascript, .typescript => &javascript.adapter,
        .python => &python.adapter,
    };
}

test "every language has an adapter with a recorder" {
    inline for (@typeInfo(lang.Language).@"enum".field_names) |name| {
        const ad = forLanguage(@field(lang.Language, name));
        try std.testing.expect(ad.recorder.len > 0);
        try std.testing.expect(ad.runtime.len > 0);
        try std.testing.expect(ad.command(.{}).len > 0);
    }
    try std.testing.expectEqualStrings("node", forLanguage(.typescript).runtime);
    try std.testing.expectEqualStrings("python", forLanguage(.python).runtime);
}
