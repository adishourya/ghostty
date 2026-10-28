//! The animal each session shows beside its name in ghostty's tab bar.
//!
//! A session gets a random one when it's created and keeps it, so it
//! survives restarts and is the same in every window. `spooky animal`
//! changes it. The glyphs are monochrome Nerd Font (Material Design) icons,
//! so ghostty's CSS can color them.

const std = @import("std");
const c = @import("c");

pub const Animal = struct {
    name: []const u8,
    glyph: []const u8,
};

pub const all = [_]Animal{
    .{ .name = "paw", .glyph = "\u{F03E9}" },
    .{ .name = "dog", .glyph = "\u{F0A43}" },
    .{ .name = "cat", .glyph = "\u{F011B}" },
    .{ .name = "rabbit", .glyph = "\u{F0907}" },
    .{ .name = "owl", .glyph = "\u{F03D2}" },
    .{ .name = "panda", .glyph = "\u{F03DA}" },
    .{ .name = "penguin", .glyph = "\u{F0EC0}" },
    .{ .name = "turtle", .glyph = "\u{F0CD7}" },
    .{ .name = "duck", .glyph = "\u{F01E5}" },
    .{ .name = "elephant", .glyph = "\u{F07C6}" },
    .{ .name = "koala", .glyph = "\u{F173F}" },
    .{ .name = "bird", .glyph = "\u{F15C6}" },
    .{ .name = "jellyfish", .glyph = "\u{F0F01}" },
    .{ .name = "bee", .glyph = "\u{F0FA1}" },
    .{ .name = "dolphin", .glyph = "\u{F18B4}" },
    .{ .name = "snail", .glyph = "\u{F1677}" },
};

/// An index into `all`.
pub const Index = u8;

pub fn find(name: []const u8) ?Index {
    for (all, 0..) |a, i| {
        if (std.mem.eql(u8, a.name, name)) return @intCast(i);
    }
    return null;
}

pub fn random() Index {
    return @intCast(c.arc4random_uniform(all.len));
}

/// Split a session name from the animal that may follow it after a zero
/// byte, as `new` and `open` requests send them: "NAME" or "NAME\x00ANIMAL".
pub fn splitName(payload: []const u8) struct { name: []const u8, animal: []const u8 } {
    const sep = std.mem.indexOfScalar(u8, payload, 0) orelse return .{ .name = payload, .animal = "" };
    return .{ .name = payload[0..sep], .animal = payload[sep + 1 ..] };
}

test "find and splitName" {
    try std.testing.expectEqual(@as(?Index, 0), find("paw"));
    try std.testing.expectEqual(@as(?Index, null), find("unicorn"));
    const both = splitName("work\x00owl");
    try std.testing.expectEqualStrings("work", both.name);
    try std.testing.expectEqualStrings("owl", both.animal);
    const plain = splitName("work");
    try std.testing.expectEqualStrings("work", plain.name);
    try std.testing.expectEqualStrings("", plain.animal);
}
