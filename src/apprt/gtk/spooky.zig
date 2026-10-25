//! Integration with the spooky terminal multiplexer (`spooky/` in the repo).
//!
//! With `spooky-integration`, each surface runs a `spooky` client that is
//! attached to a pane owned by the spooky daemon. Ghostty itself keeps a
//! connection to the daemon as its "controller" in order to:
//!
//!   - report which surfaces are in which windows, tabs and splits, so the
//!     daemon remembers each window as a session (sent whenever it changes),
//!   - tell the daemon when the user closes a split or a tab, so the panes
//!     in it end (closing a whole window only detaches its session),
//!   - open windows the daemon asks for, e.g. for `spooky attach NAME`,
//!   - run spooky in new tabs and splits opened from a spooky pane, so they
//!     join its session. Everything else stays a plain shell.
//!
//! The wire format is defined in spooky/src/protocol.zig and the layout
//! JSON in spooky/src/layout.zig.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const glib = @import("glib");
const glibunix = @import("glibunix");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Application = @import("class/application.zig").Application;
const SplitTree = @import("class/split_tree.zig").SplitTree;
const Surface = @import("class/surface.zig").Surface;
const Tab = @import("class/tab.zig").Tab;
const Window = @import("class/window.zig").Window;
const Overrides = @import("class/Overrides.zig");
const CoreSurface = @import("../../Surface.zig");

const log = std.log.scoped(.spooky);

/// The protocol tags used here, from spooky/src/protocol.zig.
const Tag = enum(u8) {
    controller = 8,
    layout = 9,
    closed = 10,
    open_window = 70,
    present_window = 71,
    surfaces = 72,
    _,
};

const header_len = 5;

/// How often to look for layout changes, and to retry connecting.
const poll_ms = 500;

/// A layout tree node; see spooky/src/layout.zig.
const Node = struct {
    argv: ?[]const []const u8 = null,
    split: ?[]const u8 = null,
    ratio: f32 = 0.5,
    left: ?*Node = null,
    right: ?*Node = null,
};

const OpenRequest = struct {
    session: []const u8 = "",
    active: u32 = 0,
    tabs: []Node = &.{},
};

var state: struct {
    fd: i32 = -1,
    watch: c_uint = 0,
    timer: c_uint = 0,
    in: std.ArrayList(u8) = .empty,
    /// The last layout sent, so only changes are sent.
    last_layout: std.ArrayList(u8) = .empty,
    /// From the daemon: the spooky executable, and the surfaces that show
    /// a spooky pane. See `inherit`.
    exe: ?[:0]u8 = null,
    surfaces: std.ArrayList(u64) = .empty,
} = .{};

/// Start connecting to the daemon. Safe to call more than once.
pub fn start() void {
    if (comptime builtin.os.tag != .linux) return;
    if (state.timer != 0) return;
    state.timer = glib.timeoutAdd(poll_ms, onTimer, null);
    _ = onTimer(null);
}

/// The user closed a split: end the pane shown in it.
pub fn surfaceClosed(surface: *Surface) void {
    const core = surface.core() orelse return;
    var id: [8]u8 = undefined;
    std.mem.writeInt(u64, &id, core.id, .little);
    send(.closed, &id);
}

/// The user closed a tab: end the panes shown in it.
pub fn tabClosed(tab: *Tab) void {
    if (state.fd < 0) return;
    const tree = tab.getSurfaceTree() orelse return;
    const alloc = Application.default().allocator();
    var ids: std.ArrayList(u8) = .empty;
    defer ids.deinit(alloc);
    var it = tree.iterator();
    while (it.next()) |entry| {
        const core = entry.view.core() orelse continue;
        var id: [8]u8 = undefined;
        std.mem.writeInt(u64, &id, core.id, .little);
        ids.appendSlice(alloc, &id) catch return;
    }
    send(.closed, ids.items);
}

/// Overrides for a new tab or split opened from `parent`. One opened from
/// a spooky pane runs `spooky new`, which joins the window's session.
pub fn inherit(parent: ?*CoreSurface, overrides: Overrides) Overrides {
    if (overrides.command != null) return overrides;
    const core = parent orelse return overrides;
    const exe = state.exe orelse return overrides;
    if (std.mem.indexOfScalar(u64, state.surfaces.items, core.id) == null) return overrides;
    const argv = struct {
        var buf: [2][:0]const u8 = undefined;
    };
    argv.buf = .{ exe, "new" };
    var result = overrides;
    result.command = .{ .direct = &argv.buf };
    return result;
}

fn onTimer(_: ?*anyopaque) callconv(.c) c_int {
    if (state.fd < 0) connect() catch return 1;
    sendLayout() catch |err| log.warn("sending layout to spooky failed: {}", .{err});
    return 1;
}

// Connection ---------------------------------------------------------------

/// The daemon's socket; the same rules as spooky's sys.socketPath.
fn socketPath(buf: []u8) ![]const u8 {
    if (std.c.getenv("SPOOKY_SOCKET")) |path| {
        return std.fmt.bufPrint(buf, "{s}", .{std.mem.span(path)});
    }
    if (std.c.getenv("XDG_RUNTIME_DIR")) |dir| {
        return std.fmt.bufPrint(buf, "{s}/spooky/default.sock", .{std.mem.span(dir)});
    }
    return std.fmt.bufPrint(buf, "/tmp/spooky-{d}/default.sock", .{linux.getuid()});
}

fn connect() !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try socketPath(&path_buf);

    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);

    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    // Fails until the first surface's spooky has started the daemon.
    if (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) != .SUCCESS)
        return error.ConnectFailed;

    state.fd = fd;
    state.in.clearRetainingCapacity();
    state.last_layout.clearRetainingCapacity();
    state.watch = glibunix.fdAdd(fd, .{ .in = true, .hup = true, .err = true }, onReadable, null);
    send(.controller, "");
    log.info("connected to spooky at {s}", .{path});
}

fn disconnect(remove_watch: bool) void {
    if (state.fd < 0) return;
    if (remove_watch and state.watch != 0) _ = glib.Source.remove(state.watch);
    state.watch = 0;
    _ = linux.close(state.fd);
    state.fd = -1;
    state.surfaces.clearRetainingCapacity();
    log.info("disconnected from spooky", .{});
}

fn send(tag: Tag, payload: []const u8) void {
    if (state.fd < 0) return;
    var header: [header_len]u8 = undefined;
    header[0] = @backingInt(tag);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    writeAll(&header) catch return disconnect(true);
    writeAll(payload) catch return disconnect(true);
}

fn writeAll(bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = linux.write(state.fd, rest.ptr, rest.len);
        switch (linux.errno(rc)) {
            .SUCCESS => rest = rest[rc..],
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
}

fn onReadable(fd: c_int, _: glib.IOCondition, _: ?*anyopaque) callconv(.c) c_int {
    const alloc = Application.default().allocator();
    var buf: [64 * 1024]u8 = undefined;
    const rc = linux.read(fd, &buf, buf.len);
    switch (linux.errno(rc)) {
        .SUCCESS => if (rc == 0) {
            disconnect(false);
            return 0;
        },
        .INTR, .AGAIN => return 1,
        else => {
            disconnect(false);
            return 0;
        },
    }
    state.in.appendSlice(alloc, buf[0..rc]) catch return 1;

    var off: usize = 0;
    while (state.in.items.len - off >= header_len) {
        const frame = state.in.items[off..];
        const len = std.mem.readInt(u32, frame[1..5], .little);
        if (frame.len - header_len < len) break;
        handle(@fromBackingInt(frame[0]), frame[header_len..][0..len]);
        off += header_len + len;
    }
    const rest = state.in.items.len - off;
    std.mem.copyForwards(u8, state.in.items[0..rest], state.in.items[off..]);
    state.in.shrinkRetainingCapacity(rest);
    return 1;
}

fn handle(tag: Tag, payload: []const u8) void {
    switch (tag) {
        .open_window => openWindow(payload) catch |err| {
            log.warn("opening window for spooky failed: {}", .{err});
        },
        .present_window => {
            if (payload.len < 8) return;
            const id = std.mem.readInt(u64, payload[0..8], .little);
            const window = findWindow(id) orelse return;
            window.as(gtk.Window).present();
        },
        .surfaces => setSurfaces(payload) catch |err| {
            log.warn("reading spooky surfaces failed: {}", .{err});
        },
        else => {},
    }
}

fn setSurfaces(payload: []const u8) !void {
    const alloc = Application.default().allocator();
    const sep = std.mem.indexOfScalar(u8, payload, 0) orelse return error.InvalidPayload;
    const exe = payload[0..sep];
    if (state.exe == null or !std.mem.eql(u8, state.exe.?, exe)) {
        const owned = try alloc.dupeSentinel(u8, exe, 0);
        if (state.exe) |old| alloc.free(old);
        state.exe = owned;
    }
    state.surfaces.clearRetainingCapacity();
    var ids = payload[sep + 1 ..];
    while (ids.len >= 8) : (ids = ids[8..]) {
        try state.surfaces.append(alloc, std.mem.readInt(u64, ids[0..8], .little));
    }
}

// Layout ------------------------------------------------------------------

fn sendLayout() !void {
    if (state.fd < 0) return;
    const alloc = Application.default().allocator();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try writeLayout(alloc, &out);
    if (std.mem.eql(u8, out.items, state.last_layout.items)) return;
    send(.layout, out.items);
    state.last_layout.clearRetainingCapacity();
    try state.last_layout.appendSlice(alloc, out.items);
}

/// Every window, its tabs, and each tab's split tree with surface ids as
/// leaves. A window's id is its address, which is stable while it's open.
fn writeLayout(alloc: Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(alloc, "{\"windows\":[");
    var first_window = true;
    var it = windows();
    while (it.next()) |window| {
        if (!first_window) try out.append(alloc, ',');
        first_window = false;

        const tab_view = window.getTabView();
        const active: c_int = if (tab_view.getSelectedPage()) |p| tab_view.getPagePosition(p) else 0;
        try out.print(alloc, "{{\"id\":{d},\"active\":{d},\"tabs\":[", .{ @intFromPtr(window), active });
        var first_tab = true;
        const n: usize = @intCast(tab_view.getNPages());
        for (0..n) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const tree = tab.getSurfaceTree() orelse continue;
            if (tree.isEmpty()) continue;
            if (!first_tab) try out.append(alloc, ',');
            first_tab = false;
            try writeNode(alloc, out, tree, .root);
        }
        try out.appendSlice(alloc, "]}");
    }
    try out.appendSlice(alloc, "]}");
}

fn writeNode(alloc: Allocator, out: *std.ArrayList(u8), tree: *const Surface.Tree, handle_: Surface.Tree.Node.Handle) !void {
    switch (tree.nodes[handle_.idx()]) {
        .leaf => |surface| {
            const id: u64 = if (surface.core()) |core| core.id else 0;
            try out.print(alloc, "{{\"surface\":{d}}}", .{id});
        },
        .split => |s| {
            try out.print(alloc, "{{\"split\":\"{s}\",\"ratio\":{d:.4},\"left\":", .{
                if (s.layout == .horizontal) "h" else "v",
                @as(f32, s.ratio),
            });
            try writeNode(alloc, out, tree, s.left);
            try out.appendSlice(alloc, ",\"right\":");
            try writeNode(alloc, out, tree, s.right);
            try out.append(alloc, '}');
        },
    }
}

const WindowIterator = struct {
    list: ?*glib.List,

    fn next(self: *WindowIterator) ?*Window {
        while (self.list) |node| {
            self.list = node.f_next;
            const data = node.f_data orelse continue;
            const object: *gobject.Object = @ptrCast(@alignCast(data));
            if (gobject.ext.cast(Window, object)) |window| return window;
        }
        return null;
    }
};

fn windows() WindowIterator {
    const app = Application.default();
    return .{ .list = @as(?*glib.List, app.as(gtk.Application).getWindows()) };
}

fn findWindow(id: u64) ?*Window {
    var it = windows();
    while (it.next()) |window| {
        if (@intFromPtr(window) == id) return window;
    }
    return null;
}

// Opening windows -----------------------------------------------------------

/// Build the window the daemon asked for: one tab per tree, each leaf a
/// surface running the given command (`spooky attach -p ID`).
fn openWindow(payload: []const u8) !void {
    const app = Application.default();
    const alloc = app.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const request = try std.json.parseFromSliceLeaky(OpenRequest, arena, payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (request.tabs.len == 0) return;

    var window: ?*Window = null;
    for (request.tabs) |tab_node| {
        const overrides = try commandOverrides(arena, firstLeaf(tab_node));
        if (window) |w| {
            w.newTab(null, overrides);
        } else {
            window = app.createWindow(null, overrides);
        }
        if (tab_node.split == null) continue;

        // The tab starts with a single surface for the first leaf; build
        // the rest of the tree around it.
        const tab_view = window.?.getTabView();
        const page = tab_view.getSelectedPage() orelse continue;
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
        const split_tree = tab.getSplitTree();
        const first = (split_tree.getTree() orelse continue).nodes[0].leaf;
        var used_first = false;
        var tree = try buildTree(alloc, arena, tab_node, split_tree, first, &used_first);
        defer tree.deinit();
        split_tree.setTree(&tree);
    }

    const w = window orelse return;
    const tab_view = w.getTabView();
    if (request.active < tab_view.getNPages()) {
        tab_view.setSelectedPage(tab_view.getNthPage(@intCast(request.active)));
    }
    w.as(gtk.Window).present();
}

fn buildTree(
    alloc: Allocator,
    arena: Allocator,
    node: Node,
    split_tree: *SplitTree,
    first: *Surface,
    used_first: *bool,
) !Surface.Tree {
    if (node.split) |split| {
        const left_node = node.left orelse return error.InvalidLayout;
        const right_node = node.right orelse return error.InvalidLayout;
        var left = try buildTree(alloc, arena, left_node.*, split_tree, first, used_first);
        defer left.deinit();
        var right = try buildTree(alloc, arena, right_node.*, split_tree, first, used_first);
        defer right.deinit();
        const direction: Surface.Tree.Split.Direction =
            if (std.mem.eql(u8, split, "h")) .right else .down;
        // The ratio is the left (or top) side's share, as reported.
        return left.split(alloc, .root, direction, @floatCast(node.ratio), &right);
    }

    // Leaves are built left to right, so the first one is the surface
    // the tab was created with.
    if (!used_first.*) {
        used_first.* = true;
        return Surface.Tree.init(alloc, first);
    }

    const surface: *Surface = .new(try commandOverrides(arena, node));
    defer surface.unref();
    _ = surface.refSink();
    surface.bindIsSplit(split_tree);
    return Surface.Tree.init(alloc, surface);
}

fn firstLeaf(node: Node) Node {
    if (node.split == null) return node;
    const left = node.left orelse return node;
    return firstLeaf(left.*);
}

fn commandOverrides(arena: Allocator, leaf: Node) !Overrides {
    var overrides: Overrides = .none;
    const argv = leaf.argv orelse return overrides;
    if (argv.len == 0) return overrides;
    const args = try arena.alloc([:0]const u8, argv.len);
    for (argv, args) |arg, *out| out.* = try arena.dupeSentinel(u8, arg, 0);
    overrides.command = .{ .direct = args };
    return overrides;
}
