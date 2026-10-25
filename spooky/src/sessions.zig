//! Sessions: named groups of panes, each shown as one ghostty window.
//!
//! When ghostty runs with `spooky-integration`, it connects as the
//! controller and reports every window's tabs and splits (leaves are
//! surface ids). Each surface runs a `spooky` client that told the daemon
//! its surface id, so the daemon can tell which panes are in which window.
//! Every window gets a session: the session its panes already belong to,
//! or a new numbered one. The layout is remembered per session so
//! `spooky attach NAME` can ask ghostty to rebuild the window later, even
//! after a reboot.
//!
//! Closing a split or tab in ghostty ends its pane. Closing a window or
//! quitting ghostty only detaches the session.

const std = @import("std");
const c = @import("c");
const protocol = @import("protocol.zig");
const layout = @import("layout.zig");
const Server = @import("Server.zig");
const Pane = @import("Pane.zig");

const log = std.log.scoped(.sessions);

pub const Session = struct {
    name: []u8,
    /// The ghostty window showing this session, while it's open.
    window: ?u64 = null,
    /// The last seen `layout.Saved`, as JSON.
    layout: ?[]u8 = null,

    pub fn deinit(self: Session, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.layout) |l| gpa.free(l);
    }
};

pub fn find(server: *Server, name: []const u8) ?*Session {
    for (server.sessions.items) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

pub fn ensure(server: *Server, name: []const u8) !*Session {
    if (find(server, name)) |s| return s;
    const owned = try server.gpa.dupe(u8, name);
    errdefer server.gpa.free(owned);
    try server.sessions.append(server.gpa, .{ .name = owned });
    server.state_dirty = true;
    return &server.sessions.items[server.sessions.items.len - 1];
}

/// Move a pane into a session.
pub fn assign(server: *Server, pane: *Pane, name: []const u8) void {
    if (std.mem.eql(u8, pane.session, name)) return;
    const owned = server.gpa.dupe(u8, name) catch return;
    server.gpa.free(pane.session);
    pane.session = owned;
    if (name.len > 0) _ = ensure(server, name) catch {};
    server.state_dirty = true;
}

/// The smallest positive number not already used as a session name.
fn autoName(server: *Server, buf: []u8) []const u8 {
    var n: usize = 1;
    while (true) : (n += 1) {
        const name = std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
        if (find(server, name) == null) return name;
    }
}

/// Drop sessions that no longer have any panes, live or awaiting
/// resurrection.
pub fn prune(server: *Server) void {
    var i: usize = 0;
    while (i < server.sessions.items.len) {
        const s = server.sessions.items[i];
        if (inUse(server, s.name)) {
            i += 1;
            continue;
        }
        s.deinit(server.gpa);
        _ = server.sessions.orderedRemove(i);
        server.state_dirty = true;
    }
}

fn inUse(server: *Server, name: []const u8) bool {
    for (server.panes.items) |pane| {
        if (!pane.dead and std.mem.eql(u8, pane.session, name)) return true;
    }
    for (server.departed.items) |d| {
        if (std.mem.eql(u8, d.session, name)) return true;
    }
    return false;
}

// Controller --------------------------------------------------------------

pub fn controllerConnected(server: *Server, client: *Server.Client) void {
    if (server.controller) |old| if (old != client) controllerGone(server, old);
    server.controller = client;
    log.info("ghostty connected", .{});
}

/// Ghostty quit or disconnected: every session it showed is detached.
pub fn controllerGone(server: *Server, client: *Server.Client) void {
    if (server.controller != client) return;
    server.controller = null;
    if (server.last_report) |r| server.gpa.free(r);
    server.last_report = null;
    for (server.sessions.items) |*s| s.window = null;
    log.info("ghostty disconnected", .{});
}

pub fn handleReport(server: *Server, json: []const u8) void {
    log.debug("layout report: {s}", .{json});
    const owned = server.gpa.dupe(u8, json) catch return;
    if (server.last_report) |r| server.gpa.free(r);
    server.last_report = owned;
    applyReport(server);
}

/// Match ghostty's windows to sessions. Called for every report and again
/// whenever a client tells us its surface, since a report can arrive
/// before the clients in a new window have connected.
pub fn applyReport(server: *Server) void {
    const raw = server.last_report orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = std.json.parseFromSliceLeaky(layout.Report, arena, raw, layout.parse_options) catch |err| {
        log.warn("bad layout from ghostty: {}", .{err});
        return;
    };

    var seen: std.ArrayList(u64) = .empty;
    for (report.windows) |win| {
        seen.append(arena, win.id) catch return;
        const saved = layout.mapTabs(arena, win.tabs, win.active, SurfaceToPane{ .server = server }) catch return;
        // None of this window's clients have connected yet.
        if (saved.tabs.len == 0) continue;

        const session = sessionForWindow(server, win.id, saved) orelse continue;
        for (saved.tabs) |tab| layout.forEachLeaf(tab, AssignCtx{ .server = server, .name = session.name }, AssignCtx.leaf);

        // Surfaces in tabs that haven't been shown yet don't exist (id 0),
        // so their clients haven't connected. Keep the saved layout until
        // every leaf is known rather than saving a partial one.
        var total: usize = 0;
        var known: usize = 0;
        for (win.tabs) |tab| layout.forEachLeaf(tab, &total, countLeaf);
        for (saved.tabs) |tab| layout.forEachLeaf(tab, &known, countLeaf);
        if (known < total) continue;

        const json = std.json.Stringify.valueAlloc(server.gpa, saved, layout.stringify_options) catch continue;
        if (session.layout) |old| {
            if (std.mem.eql(u8, old, json)) {
                server.gpa.free(json);
                continue;
            }
            server.gpa.free(old);
        }
        session.layout = json;
        server.state_dirty = true;
    }

    for (server.sessions.items) |*s| {
        const w = s.window orelse continue;
        if (std.mem.indexOfScalar(u64, seen.items, w) == null) s.window = null;
    }
}

fn countLeaf(count: *usize, _: layout.Node) void {
    count.* += 1;
}

const SurfaceToPane = struct {
    server: *Server,

    pub fn leaf(self: SurfaceToPane, node: layout.Node) ?layout.Node {
        const surface = node.surface orelse return null;
        const pane = paneForSurface(self.server, surface) orelse return null;
        return .{ .pane = pane.id };
    }
};

const AssignCtx = struct {
    server: *Server,
    name: []const u8,

    fn leaf(self: AssignCtx, node: layout.Node) void {
        const pane = self.server.findPane(node.pane orelse return) orelse return;
        assign(self.server, pane, self.name);
    }
};

/// The pane currently shown in a surface.
fn paneForSurface(server: *Server, surface: u64) ?*Pane {
    for (server.panes.items) |pane| {
        const client = pane.client orelse continue;
        if (!pane.dead and client.surface == surface) return pane;
    }
    return null;
}

fn sessionForWindow(server: *Server, window: u64, saved: layout.Saved) ?*Session {
    for (server.sessions.items) |*s| {
        if (s.window == window) return s;
    }

    // A window opened for a session (`spooky attach`, `spooky new NAME`)
    // shows panes that already belong to it.
    const Ctx = struct {
        server: *Server,
        found: *?*Session,

        fn leaf(self: @This(), node: layout.Node) void {
            if (self.found.* != null) return;
            const pane = self.server.findPane(node.pane orelse return) orelse return;
            if (pane.session.len == 0) return;
            const s = find(self.server, pane.session) orelse return;
            if (s.window == null) self.found.* = s;
        }
    };
    var found: ?*Session = null;
    for (saved.tabs) |tab| layout.forEachLeaf(tab, Ctx{ .server = server, .found = &found }, Ctx.leaf);

    const session = found orelse session: {
        var buf: [16]u8 = undefined;
        break :session ensure(server, autoName(server, &buf)) catch return null;
    };
    session.window = window;
    return session;
}

/// The user closed these surfaces in ghostty (a split or a tab): end the
/// panes shown in them.
pub fn handleClosed(server: *Server, payload: []const u8) void {
    var i: usize = 0;
    while (i + 8 <= payload.len) : (i += 8) {
        const surface = std.mem.readInt(u64, payload[i..][0..8], .little);
        for (server.panes.items) |pane| {
            if (pane.dead or pane.surface != surface) continue;
            // The pane was attached elsewhere since; that view lives on.
            if (pane.client) |client| if (client.surface != surface) continue;
            log.info("pane {d} closed in ghostty", .{pane.id});
            // Ghostty ends the client in a closed surface itself, as part of
            // closing it. Hanging up first would make that client exit while
            // ghostty is still tearing the surface down.
            if (pane.client != null) pane.close_on_detach = true else pane.hangup();
        }
    }
}

// Requests ----------------------------------------------------------------

/// `spooky attach NAME`, `spooky new NAME` and `spooky attach -p ID` from
/// inside a pane: ask ghostty to open (or raise) the window.
pub fn open(server: *Server, client: *Server.Client, kind: protocol.Prepare.Kind, pane_id: u32, name_: []const u8) void {
    const controller = server.controller orelse return server.fail(client, protocol.no_controller);

    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var name_buf: [16]u8 = undefined;
    const name = if (name_.len > 0) name_ else autoName(server, &name_buf);

    // Null when the session's window is already open and was raised.
    const maybe: ?layout.Open = switch (kind) {
        .pane => request: {
            const pane = server.findPane(pane_id) orelse return server.fail(client, "no such pane");
            const tabs = arena.alloc(layout.Node, 1) catch return;
            tabs[0] = .{ .argv = attachArgv(server, arena, pane.id) catch return };
            break :request .{ .session = pane.session, .tabs = tabs };
        },

        .session, .new => request: {
            if (find(server, name)) |s| {
                if (s.window) |window| {
                    var id: [8]u8 = undefined;
                    std.mem.writeInt(u64, &id, window, .little);
                    server.send(controller, .present_window, &id);
                    break :request null;
                }
                break :request sessionWindow(server, arena, s) catch return;
            }
            if (kind == .session) {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "no session '{s}'", .{name[0..@min(name.len, 64)]}) catch "no such session";
                return server.fail(client, msg);
            }
            const tabs = arena.alloc(layout.Node, 1) catch return;
            const argv = arena.alloc([]const u8, 4) catch return;
            argv[0] = server.exe();
            argv[1] = "new";
            argv[2] = "-s";
            argv[3] = arena.dupe(u8, name) catch return;
            tabs[0] = .{ .argv = argv };
            break :request .{ .session = argv[3], .tabs = tabs };
        },

        _ => return server.fail(client, "malformed open request"),
    };
    const request = maybe orelse {
        server.send(client, .text, "");
        client.closing = true;
        return;
    };

    const json = std.json.Stringify.valueAlloc(arena, request, layout.stringify_options) catch return;
    log.debug("open window: {s}", .{json});
    server.send(controller, .open_window, json);
    server.send(client, .text, "");
    client.closing = true;
}

/// A window for a detached session: its saved layout with each pane
/// reattached, plus a tab for any of its panes the layout doesn't have.
fn sessionWindow(server: *Server, arena: std.mem.Allocator, session: *Session) !layout.Open {
    var saved: layout.Saved = .{};
    if (session.layout) |json| {
        saved = std.json.parseFromSliceLeaky(layout.Saved, arena, json, layout.parse_options) catch .{};
    }

    const PaneToArgv = struct {
        server: *Server,
        arena: std.mem.Allocator,
        used: *std.ArrayList(u32),

        pub fn leaf(self: @This(), node: layout.Node) ?layout.Node {
            const pane = self.server.findPane(node.pane orelse return null) orelse return null;
            self.used.append(self.arena, pane.id) catch return null;
            return .{ .argv = attachArgv(self.server, self.arena, pane.id) catch return null };
        }
    };
    var used: std.ArrayList(u32) = .empty;
    const mapped = try layout.mapTabs(arena, saved.tabs, saved.active, PaneToArgv{
        .server = server,
        .arena = arena,
        .used = &used,
    });

    var tabs: std.ArrayList(layout.Node) = .empty;
    try tabs.appendSlice(arena, mapped.tabs);
    for (server.panes.items) |pane| {
        if (pane.dead or !std.mem.eql(u8, pane.session, session.name)) continue;
        if (std.mem.indexOfScalar(u32, used.items, pane.id) != null) continue;
        try tabs.append(arena, .{ .argv = try attachArgv(server, arena, pane.id) });
    }
    return .{ .session = session.name, .active = mapped.active, .tabs = tabs.items };
}

fn attachArgv(server: *Server, arena: std.mem.Allocator, pane: u32) ![]const []const u8 {
    const argv = try arena.alloc([]const u8, 4);
    argv[0] = server.exe();
    argv[1] = "attach";
    argv[2] = "-p";
    argv[3] = try std.fmt.allocPrint(arena, "{d}", .{pane});
    return argv;
}

pub fn rename(server: *Server, client: *Server.Client, payload: []const u8) void {
    const req = protocol.readStruct(protocol.Rename, payload) orelse return server.fail(client, "malformed rename");
    const rest = payload[@sizeOf(protocol.Rename)..];
    const sep = std.mem.indexOfScalar(u8, rest, 0) orelse return server.fail(client, "malformed rename");
    var old = rest[0..sep];
    const new = rest[sep + 1 ..];

    if (old.len == 0) {
        const pane = server.findPane(req.pane) orelse return server.fail(client, "not inside a spooky pane");
        old = pane.session;
    }
    if (new.len == 0) return server.fail(client, "session name can't be empty");
    if (find(server, new) != null) return server.fail(client, "a session with that name already exists");
    const session = find(server, old) orelse return server.fail(client, "no such session");

    const old_name = session.name;
    session.name = server.gpa.dupe(u8, new) catch return server.fail(client, "out of memory");
    defer server.gpa.free(old_name);
    for (server.panes.items) |pane| {
        if (std.mem.eql(u8, pane.session, old_name)) assign(server, pane, new);
    }
    for (server.departed.items) |*d| {
        if (!std.mem.eql(u8, d.session, old_name)) continue;
        const owned = server.gpa.dupe(u8, new) catch continue;
        server.gpa.free(d.session);
        d.session = owned;
    }
    server.state_dirty = true;
    server.send(client, .text, "");
    client.closing = true;
}

/// `spooky ls`: one line per session.
pub fn list(server: *Server, out: *std.ArrayList(u8)) !void {
    if (server.sessions.items.len == 0) {
        try out.appendSlice(server.gpa, "no sessions\n");
        return;
    }
    var width: usize = "SESSION".len;
    for (server.sessions.items) |s| width = @max(width, s.name.len);

    try out.appendSlice(server.gpa, "SESSION");
    try out.appendNTimes(server.gpa, ' ', width - "SESSION".len);
    try out.appendSlice(server.gpa, "  STATE     TABS  PANES  RUNNING\n");
    for (server.sessions.items) |s| {
        var panes: usize = 0;
        var running: std.ArrayList(u8) = .empty;
        defer running.deinit(server.gpa);
        for (server.panes.items) |pane| {
            if (pane.dead or !std.mem.eql(u8, pane.session, s.name)) continue;
            panes += 1;
            const fg = pane.fg orelse continue;
            const argv = fg.argv orelse continue;
            if (running.items.len > 40) continue;
            if (running.items.len > 0) try running.appendSlice(server.gpa, ", ");
            try running.appendSlice(server.gpa, std.fs.path.basename(argv[0]));
        }
        const tabs = tabCount(server.gpa, s);

        try out.appendSlice(server.gpa, s.name);
        try out.appendNTimes(server.gpa, ' ', width - s.name.len);
        const state = if (s.window != null) "open" else if (panes > 0) "detached" else "saved";
        try out.print(server.gpa, "  {s:<8}  ", .{state});
        if (tabs) |n| try out.print(server.gpa, "{d:>4}", .{n}) else try out.appendSlice(server.gpa, "   -");
        try out.print(server.gpa, "  {d:>5}  {s}\n", .{ panes, running.items });
    }
}

fn tabCount(gpa: std.mem.Allocator, s: Session) ?usize {
    const json = s.layout orelse return null;
    const parsed = std.json.parseFromSlice(layout.Saved, gpa, json, layout.parse_options) catch return null;
    defer parsed.deinit();
    return parsed.value.tabs.len;
}
