//! Window layouts exchanged with ghostty and saved per session.
//!
//! Ghostty reports its windows as trees whose leaves are surface ids. The
//! daemon translates leaves to pane ids to remember a session's layout,
//! and to argv lists (`spooky attach -p ID`) when asking ghostty to open a
//! window for a session again. All three use the same tree shape:
//!
//!   {"surface": 123} | {"pane": 4} | {"argv": ["spooky", ...]}
//!   {"split": "h" | "v", "ratio": 0.5, "left": NODE, "right": NODE}
//!
//! "h" is ghostty's horizontal layout (side by side), "v" is stacked.

const std = @import("std");

pub const Node = struct {
    surface: ?u64 = null,
    pane: ?u32 = null,
    argv: ?[]const []const u8 = null,
    split: ?[]const u8 = null,
    ratio: f32 = 0.5,
    left: ?*Node = null,
    right: ?*Node = null,

    pub fn isLeaf(self: Node) bool {
        return self.split == null;
    }
};

/// One ghostty window, as reported by ghostty.
pub const Window = struct {
    id: u64,
    active: u32 = 0,
    tabs: []Node = &.{},
};

/// Everything ghostty has open. Sent whenever it changes.
pub const Report = struct {
    windows: []Window = &.{},
};

/// A session's layout with pane leaves, as saved by the daemon.
pub const Saved = struct {
    active: u32 = 0,
    tabs: []Node = &.{},
};

/// Request to ghostty to open a window, with argv leaves.
pub const Open = struct {
    session: []const u8,
    active: u32 = 0,
    tabs: []Node,
};

/// Sent to ghostty: the surfaces that show a pane and the windows that
/// show a session, each with the session's name.
pub const Surfaces = struct {
    exe: []const u8,
    surfaces: []const Entry,
    windows: []const Entry,

    pub const Entry = struct {
        id: u64,
        session: []const u8,
    };
};

pub const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

pub const stringify_options: std.json.Stringify.Options = .{
    .emit_null_optional_fields = false,
};

/// Rebuild `node` with every leaf passed through `ctx.leaf(Node) ?Node`.
/// Leaves mapped to null are dropped and a split left with one side is
/// replaced by that side, so the result stays a valid tree.
pub fn map(arena: std.mem.Allocator, node: Node, ctx: anytype) error{OutOfMemory}!?Node {
    if (node.isLeaf()) return ctx.leaf(node);
    const left = if (node.left) |l| try map(arena, l.*, ctx) else null;
    const right = if (node.right) |r| try map(arena, r.*, ctx) else null;
    if (left == null) return right;
    if (right == null) return left;
    const l = try arena.create(Node);
    l.* = left.?;
    const r = try arena.create(Node);
    r.* = right.?;
    return .{ .split = node.split, .ratio = node.ratio, .left = l, .right = r };
}

/// Map every tab of a window; tabs left empty are dropped. `active` is
/// adjusted to keep pointing at the same tab when possible.
pub fn mapTabs(
    arena: std.mem.Allocator,
    tabs: []const Node,
    active: u32,
    ctx: anytype,
) error{OutOfMemory}!Saved {
    var out: std.ArrayList(Node) = .empty;
    var new_active: u32 = 0;
    for (tabs, 0..) |tab, i| {
        const mapped = try map(arena, tab, ctx) orelse continue;
        if (i == active) new_active = @intCast(out.items.len);
        try out.append(arena, mapped);
    }
    return .{ .active = new_active, .tabs = out.items };
}

/// Call `f(ctx, leaf)` for every leaf.
pub fn forEachLeaf(node: Node, ctx: anytype, comptime f: anytype) void {
    if (node.isLeaf()) return f(ctx, node);
    if (node.left) |l| forEachLeaf(l.*, ctx, f);
    if (node.right) |r| forEachLeaf(r.*, ctx, f);
}

test "map drops leaves and collapses splits" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"split":"h","ratio":0.3,"left":{"surface":1},
        \\ "right":{"split":"v","ratio":0.5,"left":{"surface":2},"right":{"surface":3}}}
    ;
    const tree = try std.json.parseFromSliceLeaky(Node, arena, json, parse_options);

    const Ctx = struct {
        fn leaf(_: @This(), n: Node) ?Node {
            if (n.surface.? == 2) return null;
            return .{ .pane = @intCast(n.surface.? * 10) };
        }
    };
    const out = (try map(arena, tree, Ctx{})).?;
    try std.testing.expectEqualStrings("h", out.split.?);
    try std.testing.expectEqual(@as(f32, 0.3), out.ratio);
    try std.testing.expectEqual(@as(?u32, 10), out.left.?.pane);
    try std.testing.expectEqual(@as(?u32, 30), out.right.?.pane);
}
