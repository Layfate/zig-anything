//! Content hashes for build caching and recording provenance (SHA-256, hex).

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hex = [Sha256.digest_length * 2]u8;

pub fn hex(digest: [Sha256.digest_length]u8) Hex {
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn of(bytes: []const u8) Hex {
    var d: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &d, .{});
    return hex(d);
}

/// Hashes a sequence of named parts. Each part is length-prefixed so that
/// ("ab", "c") and ("a", "bc") never collide.
pub const Builder = struct {
    h: Sha256 = .init(.{}),

    pub fn add(b: *Builder, name: []const u8, data: []const u8) void {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, name.len, .little);
        b.h.update(&len);
        b.h.update(name);
        std.mem.writeInt(u64, &len, data.len, .little);
        b.h.update(&len);
        b.h.update(data);
    }

    pub fn final(b: *Builder) Hex {
        return hex(b.h.finalResult());
    }
};

test "builder parts are unambiguous" {
    var x: Builder = .{};
    x.add("ab", "c");
    var y: Builder = .{};
    y.add("a", "bc");
    try std.testing.expect(!std.mem.eql(u8, &x.final(), &y.final()));
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &of(""));
}
