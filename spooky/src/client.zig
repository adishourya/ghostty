//! `spooky attach`: a thin proxy between the terminal it runs in and a pane
//! in the daemon. Keystrokes go up unmodified, pane output comes down
//! unmodified, so the hosting terminal (ghostty) sees exactly what the
//! program wrote: images, OSCs, synchronized output and all.

const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");
const protocol = @import("protocol.zig");
const Pane = @import("Pane.zig");

/// Start a new pane in `session` (empty: the active session), or with
/// `adopt`, first try to pick up a waiting pane.
pub fn new(gpa: std.mem.Allocator, session: []const u8, flags: protocol.New.Flags) !u8 {
    const fd = try connectOrSpawn();
    defer sys.close(fd);

    var cwd_buf: [4096]u8 = undefined;
    const cwd: []const u8 = if (c.getcwd(&cwd_buf, cwd_buf.len)) |p| std.mem.span(p) else "";

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    const req: protocol.New = .{
        .size = termSize(),
        .cwd_len = @intCast(cwd.len),
        .flags = flags,
        .surface = surfaceId(),
    };
    try payload.appendSlice(gpa, std.mem.asBytes(&req));
    try payload.appendSlice(gpa, cwd);
    try payload.appendSlice(gpa, session);

    return session_loop(gpa, fd, .new, payload.items);
}

/// Attach to pane `id`, or with id 0, to the first detached pane of
/// `session`, leaving the session's other detached panes for the next
/// windows and splits to pick up.
pub fn attach(gpa: std.mem.Allocator, id: u32, session: []const u8) !u8 {
    const fd = try connectOrSpawn();
    defer sys.close(fd);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    const req: protocol.Attach = .{ .size = termSize(), .pane = id, .surface = surfaceId() };
    try payload.appendSlice(gpa, std.mem.asBytes(&req));
    try payload.appendSlice(gpa, session);
    return session_loop(gpa, fd, .attach, payload.items);
}

/// The id of the pane this process is running inside, if any. Checks the
/// controlling tty rather than trusting the environment alone, which a
/// ghostty started from inside a pane would inherit.
pub fn insidePane() ?u32 {
    const id = c.getenv("SPOOKY_PANE") orelse return null;
    const want = c.getenv("SPOOKY_TTY") orelse return null;
    const tty = c.ttyname(0) orelse return null;
    if (!std.mem.eql(u8, std.mem.span(want), std.mem.span(tty))) return null;
    return std.fmt.parseInt(u32, std.mem.span(id), 10) catch null;
}

/// The ghostty surface this process runs in, from GHOSTTY_SURFACE_ID.
fn surfaceId() u64 {
    const env = std.mem.span(c.getenv("GHOSTTY_SURFACE_ID") orelse return 0);
    const hex = if (std.mem.startsWith(u8, env, "0x")) env[2..] else env;
    return std.fmt.parseInt(u64, hex, 16) catch 0;
}

/// From inside a pane: rather than nesting a spooky inside it, have
/// ghostty open a window for `kind`. Ghostty does this itself when it's
/// connected with `spooky-integration`; otherwise the daemon is told what
/// the next window should show and `ghostty +new-window` opens one.
pub fn openWindow(gpa: std.mem.Allocator, kind: protocol.Prepare.Kind, pane: u32, session: []const u8) !u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    const req: protocol.Prepare = .{ .kind = kind, .pane = pane };
    try payload.appendSlice(gpa, std.mem.asBytes(&req));
    try payload.appendSlice(gpa, session);

    {
        const fd = try connectOrSpawn();
        defer sys.close(fd);
        const err = try requestPayload(gpa, fd, .open, payload.items) orelse return 0;
        defer gpa.free(err);
        if (!std.mem.eql(u8, err, protocol.no_controller)) {
            std.debug.print("spooky: {s}\n", .{err});
            return 1;
        }
    }

    const fd = try connectOrSpawn();
    defer sys.close(fd);
    if (try requestPayload(gpa, fd, .prepare, payload.items)) |err| {
        defer gpa.free(err);
        std.debug.print("spooky: {s}\n", .{err});
        return 1;
    }

    const ghostty: [*:0]const u8 = c.getenv("SPOOKY_GHOSTTY") orelse "ghostty";
    const pid = c.fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ ghostty, "+new-window", null };
        _ = c.execvp(ghostty, @ptrCast(&argv));
        c._exit(127);
    }
    var status: c_int = 0;
    if (pid < 0 or c.waitpid(pid, &status, 0) != pid or status != 0) {
        std.debug.print(
            \\spooky: couldn't open a window with `{s} +new-window`.
            \\Open a new ghostty tab or split within 30s instead; it will pick this up.
            \\
        , .{std.mem.span(ghostty)});
        return 1;
    }
    return 0;
}

/// `spooky ls`, or with `panes`, `spooky ls -p`.
pub fn list(gpa: std.mem.Allocator, panes: bool) !void {
    // Starting the daemon here brings back saved sessions after a reboot.
    const fd = try connectOrSpawn();
    defer sys.close(fd);
    _ = try printReply(gpa, fd, .list, if (panes) "panes" else "");
}

/// Rename session `old`, or the current pane's session if `old` is empty.
pub fn rename(gpa: std.mem.Allocator, pane: u32, old: []const u8, new_name: []const u8) !u8 {
    const fd = try connectOrSpawn();
    defer sys.close(fd);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    const req: protocol.Rename = .{ .pane = pane };
    try payload.appendSlice(gpa, std.mem.asBytes(&req));
    try payload.appendSlice(gpa, old);
    try payload.append(gpa, 0);
    try payload.appendSlice(gpa, new_name);
    return printReply(gpa, fd, .rename, payload.items);
}

/// Stop the daemon the way a shutdown would: it saves every pane and
/// session first, and the next spooky starts a new daemon that brings them
/// back. Works with older daemons too, so it can be used to upgrade.
pub fn restartServer() !void {
    const fd = connect() catch {
        std.debug.print("spooky: no daemon running\n", .{});
        return;
    };
    defer sys.close(fd);
    var cred: c.struct_ucred = undefined;
    var len: c.socklen_t = @sizeOf(c.struct_ucred);
    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_PEERCRED, &cred, &len) != 0 or cred.pid <= 0)
        return error.NoDaemonPid;
    if (c.kill(cred.pid, c.SIGTERM) != 0) return error.KillFailed;

    var tries: usize = 0;
    while (tries < 500 and c.kill(cred.pid, 0) == 0) : (tries += 1) {
        const ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 10 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
    std.debug.print("spooky: daemon stopped and saved; `spooky ls` starts the new one\n", .{});
}

pub fn killServer(gpa: std.mem.Allocator) !void {
    const fd = connect() catch return;
    defer sys.close(fd);
    _ = try printReply(gpa, fd, .kill_server, "");
}

/// Send a request, print its reply, and return an exit code.
fn printReply(gpa: std.mem.Allocator, fd: sys.Fd, tag: protocol.Tag, payload: []const u8) !u8 {
    const err = try requestPayload(gpa, fd, tag, payload) orelse return 0;
    defer gpa.free(err);
    std.debug.print("spooky: {s}\n", .{err});
    return 1;
}

/// Send a request and print any text reply. Returns the error message if
/// the request failed; the caller frees it.
fn requestPayload(gpa: std.mem.Allocator, fd: sys.Fd, tag: protocol.Tag, payload: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try protocol.append(gpa, &out, tag, payload);
    try sys.writeAll(fd, out.items);

    var in: std.ArrayList(u8) = .empty;
    defer in.deinit(gpa);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        switch (try sys.read(fd, &buf)) {
            .data => |n| try in.appendSlice(gpa, buf[0..n]),
            .would_block => continue,
            .eof => break,
        }
    }
    var off: usize = 0;
    while (try protocol.parse(in.items[off..])) |p| : (off += p.len) {
        switch (p.frame.tag) {
            .text => try sys.writeAll(1, p.frame.payload),
            .err => return try gpa.dupe(u8, p.frame.payload),
            else => {},
        }
    }
    return null;
}

fn connect() !sys.Fd {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    return sys.connectUnix(try sys.socketPath(&path_buf));
}

fn connectOrSpawn() !sys.Fd {
    if (connect()) |fd| return fd else |_| {}
    try spawnDaemon();
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (connect()) |fd| return fd else |_| {}
        const ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 10 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
    return error.DaemonDidNotStart;
}

/// Double fork so the daemon is reparented to init and survives the
/// terminal that started it. Its stderr goes to a log in the state dir.
fn spawnDaemon() !void {
    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state = try sys.stateDir(&state_buf);
    sys.makePath(state);
    var log_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = try std.fmt.bufPrintSentinel(&log_buf, "{s}/daemon.log", .{state}, 0);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setsid();
        if (c.fork() != 0) c._exit(0);

        const null_fd = c.open("/dev/null", c.O_RDWR);
        const log_fd = c.open(log_path.ptr, c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_uint, 0o600));
        _ = c.dup2(null_fd, 0);
        _ = c.dup2(null_fd, 1);
        _ = c.dup2(if (log_fd >= 0) log_fd else null_fd, 2);
        _ = c.chdir("/");

        const argv = [_:null]?[*:0]const u8{ "spooky", "daemon", null };
        _ = c.execv("/proc/self/exe", @ptrCast(&argv));
        c._exit(127);
    }
    _ = c.waitpid(pid, null, 0);
}

fn termSize() protocol.Size {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(1, c.TIOCGWINSZ, &ws) != 0 or ws.ws_col == 0 or ws.ws_row == 0)
        return .{ .cols = 80, .rows = 24 };
    return .{ .cols = ws.ws_col, .rows = ws.ws_row, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
}

var winch_pipe: [2]c_int = .{ -1, -1 };

fn onWinch(_: c_int) callconv(.c) void {
    const b: u8 = 0;
    _ = c.write(winch_pipe[1], &b, 1);
}

const RawMode = struct {
    saved: ?c.struct_termios = null,

    fn enable() RawMode {
        var attrs: c.struct_termios = undefined;
        if (c.isatty(0) == 0 or c.tcgetattr(0, &attrs) != 0) return .{};
        const saved = attrs;
        c.cfmakeraw(&attrs);
        _ = c.tcsetattr(0, c.TCSANOW, &attrs);
        return .{ .saved = saved };
    }

    fn restore(self: RawMode) void {
        if (self.saved) |attrs| _ = c.tcsetattr(0, c.TCSANOW, &attrs);
    }
};

fn session_loop(gpa: std.mem.Allocator, fd: sys.Fd, tag: protocol.Tag, payload: []const u8) !u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try protocol.append(gpa, &out, tag, payload);
    try sys.writeAll(fd, out.items);
    out.clearRetainingCapacity();

    if (c.pipe2(&winch_pipe, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return error.PipeFailed;
    _ = c.signal(c.SIGWINCH, &onWinch);
    sys.ignoreSignal(c.SIGPIPE);

    const raw = RawMode.enable();
    var message: ?[]const u8 = null;
    var message_buf: [256]u8 = undefined;
    var code: u8 = 0;
    var attached = false;
    var stdin_open = true;
    defer {
        // Leave the user's terminal usable after detaching.
        if (attached and c.isatty(1) != 0) sys.writeAll(1, Pane.restore_modes) catch {};
        raw.restore();
        if (message) |m| std.debug.print("[spooky: {s}]\n", .{m});
    }

    var in: std.ArrayList(u8) = .empty;
    defer in.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;

    while (true) {
        var fds = [_]c.struct_pollfd{
            // A negative fd is ignored by poll.
            .{ .fd = if (stdin_open) 0 else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = winch_pipe[0], .events = c.POLLIN, .revents = 0 },
        };
        if (c.poll(&fds, fds.len, -1) < 0) {
            if (sys.errno() == c.EINTR) continue;
            return error.PollFailed;
        }

        if (fds[2].revents != 0) {
            while (sys.read(winch_pipe[0], &buf) catch .eof == .data) {}
            const size = termSize();
            try protocol.append(gpa, &out, .resize, std.mem.asBytes(&size));
        }

        if (fds[0].revents != 0) {
            switch (try sys.read(0, &buf)) {
                .data => |n| try protocol.append(gpa, &out, .input, buf[0..n]),
                .would_block => {},
                // Not a terminal (e.g. /dev/null): keep showing output. A
                // real terminal closing sends SIGHUP, which ends us.
                .eof => stdin_open = false,
            }
        }

        if (out.items.len > 0) {
            sys.writeAll(fd, out.items) catch {
                message = "lost connection to daemon";
                return 1;
            };
            out.clearRetainingCapacity();
        }

        if (fds[1].revents != 0) {
            switch (try sys.read(fd, &buf)) {
                .data => |n| try in.appendSlice(gpa, buf[0..n]),
                .would_block => {},
                .eof => {
                    message = "daemon closed the connection";
                    return 1;
                },
            }

            var off: usize = 0;
            defer sys.consume(&in, off);
            while (try protocol.parse(in.items[off..])) |p| {
                off += p.len;
                switch (p.frame.tag) {
                    // The hosting terminal is gone; the pane lives on.
                    .output => sys.writeAll(1, p.frame.payload) catch return 0,
                    .attached => attached = true,
                    .exit => {
                        const status = protocol.readStruct(i32, p.frame.payload) orelse 0;
                        code = @truncate(@as(u32, @bitCast(status)));
                        return code;
                    },
                    .detached => {
                        message = "attached elsewhere";
                        return 0;
                    },
                    .err => {
                        const len = @min(p.frame.payload.len, message_buf.len);
                        @memcpy(message_buf[0..len], p.frame.payload[0..len]);
                        message = message_buf[0..len];
                        return 1;
                    },
                    else => {},
                }
            }
        }
    }
}
