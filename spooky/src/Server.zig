//! The spooky daemon. Owns every pane and outlives the windows showing them.
//!
//! Single threaded: one poll loop over the listening socket, every client
//! socket and every pty master. Pane output is forwarded to the attached
//! client as soon as it is read; there is no rendering, compositing or
//! layout here. Layout belongs to ghostty's own tabs and splits.
//!
//! Off the hot path, the daemon periodically persists every pane (see
//! persist.zig) and resurrects them when it starts after a reboot.
const Server = @This();

const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");
const protocol = @import("protocol.zig");
const persist = @import("persist.zig");
const Pane = @import("Pane.zig");
const sessionpkg = @import("sessions.zig");

const log = std.log.scoped(.server);

/// Stop reading a pane's pty while its client has this much unsent output.
/// The kernel pty buffer then fills and the program blocks, which is the
/// same backpressure it would get from a slow terminal.
const client_high_water = 4 * 1024 * 1024;

/// Deferred output is parsed once no pane has produced output for this
/// long. A momentarily empty pty during a flood must not count as idle.
const idle_ms = 15;

/// How much backlog to parse per loop iteration once idle. Small enough
/// that a keypress arriving meanwhile is not noticeably delayed.
const catch_up_slice = 256 * 1024;

/// How often state.json is rewritten when something changed.
const save_interval_ms = 2_000;

/// Minimum time between snapshots of the same pane. Snapshots include all
/// scrollback so they are the expensive part of saving.
const snapshot_interval_ms = 10_000;

/// How long a `prepare` waits for a ghostty window to show up and claim it.
const prepare_timeout_ms = 30_000;

/// A pane whose shell exited normally is forgotten only after this long.
/// During shutdown the shells can be killed a moment before the daemon
/// gets its own SIGTERM, and they must still come back after the reboot.
const departed_grace_ms = 5_000;

pub const Client = struct {
    fd: sys.Fd,
    in: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    pane: ?*Pane = null,
    /// Close once `out` is flushed.
    closing: bool = false,
    /// GHOSTTY_SURFACE_ID of the surface this client runs in, or zero.
    surface: u64 = 0,
};

/// What the next plain `spooky` should attach to; see `Tag.prepare`.
const Next = struct {
    kind: protocol.Prepare.Kind,
    pane: u32,
    session: []u8,
    expires_ms: i64,
};

/// A pane that is gone but still persisted; see `departed_grace_ms`.
const Departed = struct {
    id: u32,
    session: []u8,
    size: protocol.Size,
    fg: persist.Foreground,
    died_ms: i64,
    /// Killed by a signal: keep until the next restore.
    keep: bool,

    fn deinit(self: Departed, gpa: std.mem.Allocator) void {
        gpa.free(self.session);
        self.fg.deinit(gpa);
    }
};

gpa: std.mem.Allocator,
listen_fd: sys.Fd,
paths: persist.Paths,
clients: std.ArrayList(*Client) = .empty,
panes: std.ArrayList(*Pane) = .empty,
departed: std.ArrayList(Departed) = .empty,
next_pane_id: u32 = 1,
running: bool = true,
/// Forget all persisted state on exit (kill-server).
wipe: bool = false,
/// The set of panes changed since the last save.
state_dirty: bool = true,
last_save_ms: i64 = 0,
/// Monotonic ms of the last pane output, for detecting idleness.
last_output_ms: i64 = 0,
/// The session most recently typed in. New panes from a plain `spooky`
/// (a new ghostty tab or split) join it, since ghostty doesn't tell us
/// which split a new one was opened from.
active_session: []u8 = &.{},
next: ?Next = null,
sessions: std.ArrayList(sessionpkg.Session) = .empty,
/// Ghostty, when connected with `spooky-integration`; see sessions.zig.
controller: ?*Client = null,
/// The last layout ghostty reported, as JSON.
last_report: ?[]u8 = null,
/// Path of this executable, for commands ghostty runs in new windows.
exe_buf: [std.fs.max_path_bytes]u8 = undefined,
exe_len: usize = 0,

var terminate_requested: bool = false;

fn onTerminate(_: c_int) callconv(.c) void {
    @atomicStore(bool, &terminate_requested, true, .seq_cst);
}

pub fn run(gpa: std.mem.Allocator) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    sys.makePath(try sys.runtimeDir(&dir_buf));
    const path = try sys.socketPath(&path_buf);

    // Refuse to start if another daemon already answers on the socket.
    if (sys.connectUnix(path)) |fd| {
        sys.close(fd);
        return error.AlreadyRunning;
    } else |_| {}

    sys.ignoreSignal(c.SIGPIPE);
    sys.ignoreSignal(c.SIGHUP);
    // No SA_RESTART: poll must return EINTR so the loop sees the flag.
    var sa = std.mem.zeroes(c.struct_sigaction);
    sa.__sigaction_handler.sa_handler = &onTerminate;
    _ = c.sigaction(c.SIGTERM, &sa, null);
    _ = c.sigaction(c.SIGINT, &sa, null);

    var self: Server = .{
        .gpa = gpa,
        .listen_fd = try sys.listenUnix(path),
        .paths = try .init(),
    };
    defer self.deinit();
    log.info("listening on {s}", .{path});

    const exe_len = c.readlink("/proc/self/exe", &self.exe_buf, self.exe_buf.len);
    self.exe_len = if (exe_len > 0) @intCast(exe_len) else 0;
    // A rebuilt binary leaves the running one marked deleted; the path
    // still names the new build.
    const deleted = " (deleted)";
    if (std.mem.endsWith(u8, self.exe(), deleted)) self.exe_len -= deleted.len;

    self.restore();

    while (self.running and !@atomicLoad(bool, &terminate_requested, .seq_cst)) {
        try self.tick();
    }

    if (self.wipe) {
        self.wipeState();
    } else {
        // Shutdown or reboot: everything is about to die, save it all.
        self.save(true);
    }
    _ = c.unlink(path.ptr);
}

fn deinit(self: *Server) void {
    for (self.clients.items) |client| self.freeClient(client);
    self.clients.deinit(self.gpa);
    for (self.panes.items) |pane| pane.destroy(self.gpa);
    self.panes.deinit(self.gpa);
    for (self.departed.items) |d| d.deinit(self.gpa);
    self.departed.deinit(self.gpa);
    self.gpa.free(self.active_session);
    self.clearNext();
    for (self.sessions.items) |s| s.deinit(self.gpa);
    self.sessions.deinit(self.gpa);
    if (self.last_report) |r| self.gpa.free(r);
    sys.close(self.listen_fd);
}

fn tick(self: *Server) !void {
    var fds: std.ArrayList(c.struct_pollfd) = .empty;
    defer fds.deinit(self.gpa);

    try fds.append(self.gpa, .{ .fd = self.listen_fd, .events = c.POLLIN, .revents = 0 });
    for (self.clients.items) |client| {
        var events: c_short = c.POLLIN;
        if (client.out.items.len > 0) events |= c.POLLOUT;
        try fds.append(self.gpa, .{ .fd = client.fd, .events = events, .revents = 0 });
    }
    for (self.panes.items) |pane| {
        var events: c_short = 0;
        const backed_up = if (pane.client) |cl| cl.out.items.len > client_high_water else false;
        if (!backed_up) events |= c.POLLIN;
        if (pane.pending_in.items.len > 0) events |= c.POLLOUT;
        try fds.append(self.gpa, .{ .fd = pane.master, .events = events, .revents = 0 });
    }

    const backlogged = for (self.panes.items) |pane| {
        if (pane.backlog.items.len > 0) break true;
    } else false;
    const timeout: c_int = if (backlogged)
        @intCast(std.math.clamp(self.last_output_ms + idle_ms - nowMs(), 0, idle_ms))
    else
        save_interval_ms;
    const n = c.poll(fds.items.ptr, @intCast(fds.items.len), timeout);
    if (n < 0) {
        if (sys.errno() == c.EINTR) return;
        return error.PollFailed;
    }

    // Snapshot the lists: handlers below may append or remove entries.
    const clients = try self.gpa.dupe(*Client, self.clients.items);
    defer self.gpa.free(clients);
    const panes = try self.gpa.dupe(*Pane, self.panes.items);
    defer self.gpa.free(panes);

    if (n > 0) {
        for (panes, fds.items[1 + clients.len ..]) |pane, pfd| {
            if (pfd.revents == 0) continue;
            self.handlePane(pane, pfd.revents);
        }
        for (clients, fds.items[1..][0..clients.len]) |client, pfd| {
            if (pfd.revents == 0) continue;
            self.handleClient(client, pfd.revents);
        }
        if (fds.items[0].revents & c.POLLIN != 0) self.accept();
    }

    // Nothing is streaming: catch the VT state up on deferred output.
    if (backlogged and nowMs() - self.last_output_ms >= idle_ms) {
        for (self.panes.items) |pane| pane.catchUp(catch_up_slice);
    }

    self.reap();
    self.sweep();
    if (nowMs() - self.last_save_ms >= save_interval_ms) self.save(false);
}

fn accept(self: *Server) void {
    while (true) {
        const fd = c.accept4(self.listen_fd, .{ .__sockaddr__ = null }, null, c.SOCK_CLOEXEC | c.SOCK_NONBLOCK);
        if (fd < 0) return;
        const client = self.gpa.create(Client) catch {
            sys.close(fd);
            return;
        };
        client.* = .{ .fd = fd };
        self.clients.append(self.gpa, client) catch {
            sys.close(fd);
            self.gpa.destroy(client);
            return;
        };
    }
}

fn handlePane(self: *Server, pane: *Pane, revents: c_short) void {
    if (pane.dead) return;

    if (revents & c.POLLOUT != 0) {
        sys.flush(pane.master, &pane.pending_in) catch {};
    }

    if (revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) {
        var buf: [64 * 1024]u8 = undefined;
        // Bound the work per tick so one chatty pane can't starve others.
        var budget: usize = 4;
        while (budget > 0) : (budget -= 1) {
            const res = sys.read(pane.master, &buf) catch .eof;
            switch (res) {
                .would_block => break,
                .eof => {
                    paneHungUp(pane);
                    return;
                },
                .data => |len| {
                    self.last_output_ms = nowMs();
                    const bytes = buf[0..len];
                    if (pane.client) |client| {
                        self.send(client, .output, bytes);
                    }
                    pane.feed(bytes);
                },
            }
        }
    }
}

fn paneHungUp(pane: *Pane) void {
    if (pane.dead) return;
    sys.close(pane.master);
    var status: c_int = 0;
    if (c.waitpid(pane.pid, &status, 0) == pane.pid) markDead(pane, status) else pane.dead = true;
}

fn markDead(pane: *Pane, status: c_int) void {
    pane.dead = true;
    pane.exit_code = sys.exitCode(status);
    pane.killed = status & 0x7f != 0;
}

/// Reap children whose pty is still held open by a grandchild.
fn reap(self: *Server) void {
    while (true) {
        var status: c_int = 0;
        const pid = c.waitpid(-1, &status, c.WNOHANG);
        if (pid <= 0) return;
        for (self.panes.items) |pane| {
            if (pane.pid != pid or pane.dead) continue;
            sys.close(pane.master);
            markDead(pane, status);
        }
    }
}

/// Remove dead panes and closed clients.
fn sweep(self: *Server) void {
    var i: usize = 0;
    while (i < self.panes.items.len) {
        const pane = self.panes.items[i];
        if (!pane.dead) {
            i += 1;
            continue;
        }
        log.info("pane {d} exited code={d} killed={}", .{ pane.id, pane.exit_code, pane.killed });
        if (pane.client) |client| {
            var code: [4]u8 = undefined;
            std.mem.writeInt(i32, &code, pane.exit_code, .little);
            self.send(client, .exit, &code);
            client.pane = null;
            client.closing = true;
        }
        _ = self.panes.orderedRemove(i);
        self.depart(pane);
        pane.destroy(self.gpa);
        self.state_dirty = true;
    }

    i = 0;
    while (i < self.clients.items.len) {
        const client = self.clients.items[i];
        if (client.fd >= 0 and !(client.closing and client.out.items.len == 0)) {
            i += 1;
            continue;
        }
        _ = self.clients.orderedRemove(i);
        self.freeClient(client);
    }

    sessionpkg.prune(self);
}

/// Keep a dead pane's last known state around; see `Departed`.
fn depart(self: *Server, pane: *Pane) void {
    if (pane.closed_by_user) {
        persist.removeSnapshot(&self.paths, pane.id);
        return;
    }
    const fg = pane.fg orelse {
        persist.removeSnapshot(&self.paths, pane.id);
        return;
    };
    const session = self.gpa.dupe(u8, pane.session) catch return;
    self.departed.append(self.gpa, .{
        .id = pane.id,
        .session = session,
        .size = pane.size,
        .fg = fg,
        .died_ms = nowMs(),
        .keep = pane.killed,
    }) catch {
        self.gpa.free(session);
        return;
    };
    pane.fg = null;
}

fn freeClient(self: *Server, client: *Client) void {
    sessionpkg.controllerGone(self, client);
    if (client.pane) |pane| pane.detach();
    if (client.fd >= 0) sys.close(client.fd);
    client.in.deinit(self.gpa);
    client.out.deinit(self.gpa);
    self.gpa.destroy(client);
}

fn dropClient(client: *Client) void {
    if (client.pane) |pane| pane.detach();
    client.pane = null;
    if (client.fd >= 0) sys.close(client.fd);
    client.fd = -1;
}

fn handleClient(self: *Server, client: *Client, revents: c_short) void {
    if (client.fd < 0) return;

    if (revents & c.POLLOUT != 0) {
        sys.flush(client.fd, &client.out) catch return dropClient(client);
    }

    if (revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const res = sys.read(client.fd, &buf) catch return dropClient(client);
            switch (res) {
                .would_block => break,
                .eof => return dropClient(client),
                .data => |len| client.in.appendSlice(self.gpa, buf[0..len]) catch
                    return dropClient(client),
            }
        }

        var off: usize = 0;
        while (true) {
            const parsed = protocol.parse(client.in.items[off..]) catch
                return dropClient(client);
            const p = parsed orelse break;
            self.handleFrame(client, p.frame);
            off += p.len;
            if (client.fd < 0) return;
        }
        sys.consume(&client.in, off);
    }
}

fn handleFrame(self: *Server, client: *Client, frame: protocol.Frame) void {
    switch (frame.tag) {
        .input => if (client.pane) |pane| {
            self.setActive(pane.session);
            var input = frame.payload;
            if (pane.resume_cmd != null) input = self.answerResume(client, pane, input);
            pane.pending_in.appendSlice(self.gpa, input) catch {};
            sys.flush(pane.master, &pane.pending_in) catch {};
        },

        .resize => if (client.pane) |pane| {
            const size = protocol.readStruct(protocol.Size, frame.payload) orelse return;
            pane.resize(size);
        },

        .new => {
            const req = protocol.readStruct(protocol.New, frame.payload) orelse
                return self.fail(client, "malformed new request");
            const rest = frame.payload[@sizeOf(protocol.New)..];
            if (req.cwd_len > rest.len) return self.fail(client, "malformed new request");
            const cwd = rest[0..req.cwd_len];
            var session = rest[req.cwd_len..];
            client.surface = req.surface;

            // Only set up by `spooky new/attach` inside a pane when ghostty
            // isn't the controller; see `Tag.prepare`.
            if (req.flags.adopt) if (self.takeNext()) |next| {
                defer self.gpa.free(next.session);
                self.setActive(next.session);
                switch (next.kind) {
                    .pane => if (self.findPane(next.pane)) |pane|
                        return self.attach(client, pane, req.size),
                    .session => if (self.claimable(next.session)) |pane|
                        return self.attach(client, pane, req.size),
                    else => {},
                }
            };

            // Further windows and splits pick up the rest of a session
            // after `spooky attach NAME`. Ghostty as the controller
            // reopens whole layouts instead.
            if (req.flags.adopt and self.controller == null) {
                if (self.claimable(self.active())) |pane| return self.attach(client, pane, req.size);
            }

            // With ghostty as the controller, the window the pane shows up
            // in decides its session.
            if (session.len == 0 and self.controller == null) session = self.active();
            if (session.len > 0) {
                self.setActive(session);
                _ = sessionpkg.ensure(self, session) catch {};
            }

            const pane = Pane.create(self.gpa, .{
                .id = self.next_pane_id,
                .session = session,
                .size = req.size,
                .cwd = if (cwd.len > 0) cwd else null,
            }) catch |err| {
                log.err("failed to create pane: {}", .{err});
                return self.fail(client, "failed to create pane");
            };
            self.panes.append(self.gpa, pane) catch {
                pane.destroy(self.gpa);
                return self.fail(client, "out of memory");
            };
            self.next_pane_id += 1;
            self.state_dirty = true;
            self.attach(client, pane, req.size);
        },

        .attach => {
            const req = protocol.readStruct(protocol.Attach, frame.payload) orelse
                return self.fail(client, "malformed attach request");
            client.surface = req.surface;
            if (req.pane != 0) {
                const pane = self.findPane(req.pane) orelse return self.fail(client, "no such pane");
                return self.attach(client, pane, req.size);
            }
            const session = frame.payload[@sizeOf(protocol.Attach)..];
            if (!self.claimSession(session)) return self.failNoDetached(client, session);
            self.setActive(session);
            self.attach(client, self.claimable(session).?, req.size);
        },

        .prepare => {
            const req = protocol.readStruct(protocol.Prepare, frame.payload) orelse
                return self.fail(client, "malformed prepare request");
            const session = frame.payload[@sizeOf(protocol.Prepare)..];
            switch (req.kind) {
                .new => {},
                .pane => if (self.findPane(req.pane) == null) return self.fail(client, "no such pane"),
                .session => if (!self.claimSession(session)) return self.failNoDetached(client, session),
                _ => return self.fail(client, "malformed prepare request"),
            }
            self.clearNext();
            const owned = self.gpa.dupe(u8, session) catch return self.fail(client, "out of memory");
            self.next = .{
                .kind = req.kind,
                .pane = req.pane,
                .session = owned,
                .expires_ms = nowMs() + prepare_timeout_ms,
            };
            self.send(client, .text, "");
            client.closing = true;
        },

        .list => {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(self.gpa);
            if (std.mem.eql(u8, frame.payload, "panes"))
                self.listPanes(&text) catch {}
            else
                sessionpkg.list(self, &text) catch {};
            self.send(client, .text, text.items);
            client.closing = true;
        },

        .controller => sessionpkg.controllerConnected(self, client),
        .layout => if (client == self.controller) sessionpkg.handleReport(self, frame.payload),
        .closed => if (client == self.controller) sessionpkg.handleClosed(self, frame.payload),
        .rename => sessionpkg.rename(self, client, frame.payload),
        .open => {
            const req = protocol.readStruct(protocol.Prepare, frame.payload) orelse
                return self.fail(client, "malformed open request");
            sessionpkg.open(self, client, req.kind, req.pane, frame.payload[@sizeOf(protocol.Prepare)..]);
        },

        .kill_server => {
            self.running = false;
            self.wipe = true;
            client.closing = true;
        },

        else => self.fail(client, "unexpected message"),
    }
}

fn attach(self: *Server, client: *Client, pane: *Pane, size: protocol.Size) void {
    if (pane.client) |old| {
        // Only one view per pane: the newest attach wins.
        self.send(old, .detached, "");
        old.pane = null;
        old.closing = true;
    }
    if (client.pane) |prev| prev.detach();

    pane.client = client;
    pane.claimable = false;
    // Shown again, so a pending close of the old surface no longer applies.
    pane.close_on_detach = false;
    client.pane = pane;
    if (client.surface != 0) pane.surface = client.surface;

    var id: [4]u8 = undefined;
    std.mem.writeInt(u32, &id, pane.id, .little);
    self.send(client, .attached, &id);

    // Resize first so the replay matches the client's grid. Programs
    // get SIGWINCH from this and redraw on their own as well.
    pane.resize(size);
    self.sendReplay(client, pane);
    if (pane.resume_cmd) |cmd| self.sendResumePrompt(client, pane, cmd);

    // A layout report may have named this surface before it connected.
    if (client.surface != 0) sessionpkg.applyReport(self);
}

/// Clear the client's screen and scrollback and recreate the pane's
/// screen on it.
fn sendReplay(self: *Server, client: *Client, pane: *Pane) void {
    self.send(client, .output, "\x1b[!p\x1b[H\x1b[2J\x1b[3J");
    const replay = pane.replay() catch |err| {
        log.warn("replay failed for pane {d}: {}", .{ pane.id, err });
        return;
    };
    defer Pane.freeBuf(replay);
    var rest: []const u8 = replay;
    while (rest.len > 0) {
        const chunk = rest[0..@min(rest.len, protocol.max_payload)];
        self.send(client, .output, chunk);
        rest = rest[chunk.len..];
    }
}

/// Draw the resume prompt on the client's bottom row. It is shown only to
/// the client and never enters the pane's VT state.
fn sendResumePrompt(self: *Server, client: *Client, pane: *Pane, cmd: []const u8) void {
    var buf: [1024]u8 = undefined;
    const max_cmd = @min(cmd.len, @as(usize, pane.size.cols) -| 40, 512);
    const shown = cmd[0..max_cmd];
    const prompt = std.fmt.bufPrint(
        &buf,
        "\x1b7\x1b[{d};1H\x1b[2K\x1b[7m \u{23CE} Enter: resume \x1b[1m{s}{s}\x1b[22m   Esc: shell \x1b[0m\x1b8",
        .{ pane.size.rows, shown, if (shown.len < cmd.len) "\u{2026}" else "" },
    ) catch return;
    self.send(client, .output, prompt);
}

/// Handle a keypress while the resume prompt is up. Enter types the saved
/// command into the new shell, anything else dismisses the prompt. Returns
/// the input that should still reach the shell.
fn answerResume(self: *Server, client: *Client, pane: *Pane, input: []const u8) []const u8 {
    const cmd = pane.resume_cmd orelse return input;
    if (input.len == 0) return input;
    pane.resume_cmd = null;
    defer self.gpa.free(cmd);

    // Repaint to remove the prompt.
    self.sendReplay(client, pane);

    switch (input[0]) {
        '\r', '\n' => {
            pane.pending_in.appendSlice(self.gpa, cmd) catch {};
            pane.pending_in.append(self.gpa, '\r') catch {};
            return input[1..];
        },
        // A lone Esc just dismisses; an escape sequence (arrow key, ...)
        // dismisses and is passed on.
        0x1b => return if (input.len == 1) input[1..] else input,
        else => return input,
    }
}

pub fn findPane(self: *Server, id: u32) ?*Pane {
    for (self.panes.items) |pane| {
        if (pane.id == id and !pane.dead) return pane;
    }
    return null;
}

/// The first detached pane waiting to be claimed, in `session` if given.
fn claimable(self: *Server, session: ?[]const u8) ?*Pane {
    for (self.panes.items) |pane| {
        if (!pane.claimable or pane.client != null or pane.dead) continue;
        if (session) |name| if (!std.mem.eql(u8, pane.session, name)) continue;
        return pane;
    }
    return null;
}

/// Mark a session's detached panes claimable. False if it has none.
fn claimSession(self: *Server, session: []const u8) bool {
    var any = false;
    for (self.panes.items) |pane| {
        if (pane.client != null or pane.dead or !std.mem.eql(u8, pane.session, session)) continue;
        pane.claimable = true;
        any = true;
    }
    return any;
}

fn active(self: *Server) []const u8 {
    return if (self.active_session.len > 0) self.active_session else "default";
}

fn setActive(self: *Server, session: []const u8) void {
    if (session.len == 0 or std.mem.eql(u8, self.active_session, session)) return;
    const owned = self.gpa.dupe(u8, session) catch return;
    self.gpa.free(self.active_session);
    self.active_session = owned;
}

fn takeNext(self: *Server) ?Next {
    const next = self.next orelse return null;
    self.next = null;
    if (nowMs() > next.expires_ms) {
        self.gpa.free(next.session);
        return null;
    }
    return next;
}

fn clearNext(self: *Server) void {
    if (self.next) |next| self.gpa.free(next.session);
    self.next = null;
}

fn failNoDetached(self: *Server, client: *Client, session: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "no detached panes in session '{s}' (start one with: spooky new -s {s})", .{
        session[0..@min(session.len, 64)],
        session[0..@min(session.len, 64)],
    }) catch "no detached panes in that session";
    self.fail(client, msg);
}

pub fn exe(self: *const Server) []const u8 {
    return if (self.exe_len > 0) self.exe_buf[0..self.exe_len] else "spooky";
}

pub fn fail(self: *Server, client: *Client, msg: []const u8) void {
    self.send(client, .err, msg);
    client.closing = true;
}

pub fn send(self: *Server, client: *Client, tag: protocol.Tag, payload: []const u8) void {
    if (client.fd < 0) return;
    protocol.append(self.gpa, &client.out, tag, payload) catch return dropClient(client);
    sys.flush(client.fd, &client.out) catch return dropClient(client);
}

/// A table of live panes grouped by session, active session first.
fn listPanes(self: *Server, out: *std.ArrayList(u8)) !void {
    var panes: std.ArrayList(*Pane) = .empty;
    defer panes.deinit(self.gpa);
    var width: usize = "SESSION".len;
    for (self.panes.items) |pane| {
        if (pane.dead) continue;
        try panes.append(self.gpa, pane);
        width = @max(width, pane.session.len + 1);
    }
    if (panes.items.len == 0) return;

    const Order = struct {
        active: []const u8,
        fn lessThan(ctx: @This(), a: *Pane, b: *Pane) bool {
            const a_active = std.mem.eql(u8, a.session, ctx.active);
            const b_active = std.mem.eql(u8, b.session, ctx.active);
            if (a_active != b_active) return a_active;
            return switch (std.mem.order(u8, a.session, b.session)) {
                .lt => true,
                .gt => false,
                .eq => a.id < b.id,
            };
        }
    };
    std.mem.sort(*Pane, panes.items, Order{ .active = self.active() }, Order.lessThan);

    try out.print(self.gpa, "{s}", .{"SESSION"});
    try out.appendNTimes(self.gpa, ' ', width - "SESSION".len);
    try out.appendSlice(self.gpa, "   ID  STATE     SIZE     COMMAND\n");
    for (panes.items) |pane| {
        const line_start = out.items.len;
        const is_active = std.mem.eql(u8, pane.session, self.active());
        try out.print(self.gpa, "{s}{s}", .{ pane.session, if (is_active) "*" else "" });
        try out.appendNTimes(self.gpa, ' ', width - pane.session.len - @intFromBool(is_active));

        var size_buf: [16]u8 = undefined;
        const size = std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ pane.size.cols, pane.size.rows }) catch "";
        const state = if (pane.client != null) "attached" else if (pane.claimable) "waiting" else "detached";
        try out.print(self.gpa, " {d:>4}  {s:<8}  {s:<7}  ", .{ pane.id, state, size });

        if (pane.fg) |fg| if (fg.argv) |argv| {
            try out.appendSlice(self.gpa, std.fs.path.basename(argv[0]));
            for (argv[1..]) |arg| {
                if (out.items.len - line_start > 100) {
                    try out.appendSlice(self.gpa, " \u{2026}");
                    break;
                }
                try out.print(self.gpa, " {s}", .{arg});
            }
        };
        try out.append(self.gpa, '\n');
    }
    try out.appendSlice(self.gpa, "\n* active session: new tabs and splits join it\n");
}

// Persistence ---------------------------------------------------------------

/// Write state.json and any stale snapshots. With `all`, every pane is
/// snapshotted regardless of the rate limit (used on shutdown).
fn save(self: *Server, all: bool) void {
    const now = nowMs();
    self.last_save_ms = now;
    self.paths.ensure();

    for (self.panes.items) |pane| {
        if (pane.dead) continue;

        if (persist.foreground(self.gpa, pane.master, pane.pid)) |fg| {
            if (pane.fg) |old| {
                if (!sameForeground(old, fg)) self.state_dirty = true;
                old.deinit(self.gpa);
            } else self.state_dirty = true;
            pane.fg = fg;
        } else |_| {}

        if (!pane.dirty) continue;
        if (!all and now - pane.last_snapshot_ms < snapshot_interval_ms) continue;
        const snap = pane.snapshot() catch continue;
        defer Pane.freeBuf(snap);
        persist.writeSnapshot(&self.paths, pane.id, snap) catch |err| {
            log.warn("pane {d}: writing snapshot failed: {}", .{ pane.id, err });
            continue;
        };
        pane.dirty = false;
        pane.last_snapshot_ms = now;
    }

    // Forget panes that exited normally once their grace period is over,
    // unless we are shutting down: then they may have been killed by it.
    if (!all) {
        var i: usize = 0;
        while (i < self.departed.items.len) {
            const d = self.departed.items[i];
            if (d.keep or now - d.died_ms < departed_grace_ms) {
                i += 1;
                continue;
            }
            persist.removeSnapshot(&self.paths, d.id);
            d.deinit(self.gpa);
            _ = self.departed.orderedRemove(i);
            self.state_dirty = true;
        }
    }

    if (!self.state_dirty and !all) return;

    var entries: std.ArrayList(persist.PaneState) = .empty;
    defer entries.deinit(self.gpa);
    for (self.panes.items) |pane| {
        if (pane.dead) continue;
        const fg = pane.fg orelse continue;
        var ps = paneState(pane.id, pane.session, pane.size, fg);
        if (fg.argv == null) ps.pending_resume = pane.resume_cmd;
        entries.append(self.gpa, ps) catch return;
    }
    for (self.departed.items) |d| {
        entries.append(self.gpa, paneState(d.id, d.session, d.size, d.fg)) catch return;
    }

    var saved_sessions: std.ArrayList(persist.SessionState) = .empty;
    defer saved_sessions.deinit(self.gpa);
    for (self.sessions.items) |s| {
        saved_sessions.append(self.gpa, .{ .name = s.name, .layout = s.layout }) catch return;
    }

    persist.writeState(self.gpa, &self.paths, .{
        .panes = entries.items,
        .sessions = saved_sessions.items,
    }) catch |err| {
        log.warn("writing state failed: {}", .{err});
        return;
    };
    self.state_dirty = false;
}

fn paneState(id: u32, session: []const u8, size: protocol.Size, fg: persist.Foreground) persist.PaneState {
    return .{
        .id = id,
        .session = session,
        .cwd = fg.cwd,
        .cols = size.cols,
        .rows = size.rows,
        .command = if (fg.argv) |argv| @ptrCast(argv) else null,
    };
}

fn sameForeground(a: persist.Foreground, b: persist.Foreground) bool {
    if (!std.mem.eql(u8, a.cwd, b.cwd)) return false;
    const aa = a.argv orelse return b.argv == null;
    const ba = b.argv orelse return false;
    if (aa.len != ba.len) return false;
    for (aa, ba) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Bring back every pane from the last saved state. Each gets a fresh
/// shell in its old directory, its old screen and scrollback, and, if a
/// program was running, a prompt offering to start it again.
fn restore(self: *Server) void {
    const parsed = persist.readState(self.gpa, &self.paths) catch |err| {
        log.warn("reading state failed: {}", .{err});
        return;
    } orelse return;
    defer parsed.deinit();

    for (parsed.value.sessions) |ss| {
        const session = sessionpkg.ensure(self, ss.name) catch continue;
        if (ss.layout) |l| session.layout = self.gpa.dupe(u8, l) catch null;
    }

    for (parsed.value.panes) |ps| {
        const snap = persist.readSnapshot(self.gpa, &self.paths, ps.id);
        defer if (snap) |s| self.gpa.free(s);

        const resume_cmd: ?[]u8 = if (ps.command) |argv|
            persist.shellJoin(self.gpa, argv) catch null
        else if (ps.pending_resume) |cmd|
            self.gpa.dupe(u8, cmd) catch null
        else
            null;
        defer if (resume_cmd) |cmd| self.gpa.free(cmd);

        const pane = Pane.create(self.gpa, .{
            .id = ps.id,
            .session = ps.session,
            .size = .{ .cols = @max(ps.cols, 1), .rows = @max(ps.rows, 1) },
            .cwd = ps.cwd,
            .snapshot = snap,
            .resume_cmd = resume_cmd,
            .claimable = false,
        }) catch |err| {
            log.err("restoring pane {d} failed: {}", .{ ps.id, err });
            continue;
        };
        self.panes.append(self.gpa, pane) catch {
            pane.destroy(self.gpa);
            continue;
        };
        self.next_pane_id = @max(self.next_pane_id, ps.id + 1);
        log.info("restored pane {d} in {s}{s}{s}", .{
            ps.id,
            ps.cwd,
            if (resume_cmd != null) ", offering: " else "",
            resume_cmd orelse "",
        });
    }
    self.state_dirty = true;
}

fn wipeState(self: *Server) void {
    for (self.panes.items) |pane| persist.removeSnapshot(&self.paths, pane.id);
    for (self.departed.items) |d| persist.removeSnapshot(&self.paths, d.id);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = self.paths.state(&buf) catch return;
    _ = c.unlink(path.ptr);
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}
