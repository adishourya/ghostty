//! `spooky animal` with no arguments: pick this pane's session animal with
//! the arrow keys. Every move sets it right away, so ghostty's tab bar
//! shows each animal in place while choosing. Esc puts the old one back.

const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");
const client = @import("client.zig");
const animals = @import("animals.zig");

const Key = enum { left, right, keep, cancel, other };

pub fn run(gpa: std.mem.Allocator, pane: u32) !u8 {
    const current = try client.animal(gpa, pane, "", "") orelse return 1;
    const start = animals.find(current) orelse 0;
    gpa.free(current);
    var selected = start;

    var saved: c.struct_termios = undefined;
    if (c.tcgetattr(0, &saved) != 0) return error.NotATerminal;
    var raw = saved;
    c.cfmakeraw(&raw);
    _ = c.tcsetattr(0, c.TCSAFLUSH, &raw);
    defer _ = c.tcsetattr(0, c.TCSAFLUSH, &saved);

    // Hide the cursor while the picker is up; clear it away afterwards.
    try sys.writeAll(1, "\x1b[?25l");
    defer sys.writeAll(1, "\r\x1b[2K\n\x1b[2K\x1b[1A\x1b[?25h") catch {};

    while (true) {
        try draw(selected);
        var buf: [16]u8 = undefined;
        const n = c.read(0, &buf, buf.len);
        if (n <= 0) return 1;
        const moved: animals.Index = switch (parseKey(buf[0..@intCast(n)])) {
            .left => if (selected == 0) animals.all.len - 1 else selected - 1,
            .right => if (selected == animals.all.len - 1) 0 else selected + 1,
            .keep => return 0,
            .cancel => {
                if (selected != start) try set(gpa, pane, start);
                return 0;
            },
            .other => continue,
        };
        selected = moved;
        try set(gpa, pane, selected);
    }
}

fn set(gpa: std.mem.Allocator, pane: u32, index: animals.Index) !void {
    const name = try client.animal(gpa, pane, "", animals.all[index].name) orelse return;
    gpa.free(name);
}

/// Two lines: every animal with the selected one highlighted, then its
/// name and the keys. The cursor is left at the start of the first line.
fn draw(selected: animals.Index) !void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("\r\x1b[2K ");
    for (animals.all, 0..) |a, i| {
        if (i == selected)
            try w.print("\x1b[7m {s} \x1b[27m", .{a.glyph})
        else
            try w.print(" {s} ", .{a.glyph});
    }
    try w.print("\r\n\x1b[2K  {s}  \x1b[2m←/→ choose · enter keep · esc cancel\x1b[22m\x1b[1A\r", .{
        animals.all[selected].name,
    });
    try sys.writeAll(1, w.buffered());
}

fn parseKey(input: []const u8) Key {
    if (std.mem.eql(u8, input, "\x1b[D") or std.mem.eql(u8, input, "\x1bOD")) return .left;
    if (std.mem.eql(u8, input, "\x1b[C") or std.mem.eql(u8, input, "\x1bOC")) return .right;
    if (input.len != 1) return .other;
    return switch (input[0]) {
        'h' => .left,
        'l', '\t' => .right,
        '\r', '\n' => .keep,
        0x1b, 'q', 3 => .cancel,
        else => .other,
    };
}
