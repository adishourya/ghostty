//! A pane is one pty and the process running in it, owned by the daemon.
//!
//! Output from the pty is forwarded byte-for-byte to the attached client
//! and, off to the side, fed into a libghostty-vt terminal. The terminal is
//! never rendered: it exists so the screen can be replayed when a client
//! (re)attaches and so it can be snapshotted to disk.
const Pane = @This();

const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");
const persist = @import("persist.zig");

const log = std.log.scoped(.pane);

gpa: std.mem.Allocator,
id: u32,
session: []u8,
master: sys.Fd,
pid: c.pid_t,
term: c.GhosttyTerminal,
size: protocol.Size,

/// The client currently attached, if any.
client: ?*Server.Client = null,

/// The ghostty surface the pane was last shown in, or zero.
surface: u64 = 0,

/// Bytes waiting to be written to the pty (input or query replies).
pending_in: std.ArrayList(u8) = .empty,

/// Output already forwarded to the client but not yet parsed into `term`.
/// Parsing is deferred while output is streaming so it never slows the
/// passthrough; see `feed` and `catchUp`.
backlog: std.ArrayList(u8) = .empty,

/// Set once the pty has hung up or the process has been reaped.
dead: bool = false,
exit_code: i32 = 0,
/// True if the process was killed by a signal rather than exiting.
killed: bool = false,
/// Ended because the user closed its split or tab; don't resurrect it.
closed_by_user: bool = false,
/// The user closed its split or tab while the client in it was still
/// running: hang up once that client goes away. See `sessions.handleClosed`.
close_on_detach: bool = false,

/// Output arrived since the last snapshot was written to disk.
dirty: bool = true,
/// Monotonic ms of the last snapshot written to disk.
last_snapshot_ms: i64 = 0,

/// What was running in the pane at the last save. Kept because it can no
/// longer be read from /proc once the process is gone.
fg: ?persist.Foreground = null,

/// Detached and waiting to be picked up by the next plain `spooky` (a new
/// ghostty window, tab or split). Set for panes resurrected from disk and
/// for a session's panes after `spooky attach -s`.
claimable: bool = false,

/// For a pane resurrected after a reboot: the shell command line that was
/// running in the foreground. The user is offered to run it again on attach.
resume_cmd: ?[]u8 = null,

/// Lines of scrollback kept in memory and persisted.
const scrollback_lines: usize = 10_000;
const scrollback_bytes: usize = 16 * 1024 * 1024;

pub const Options = struct {
    id: u32,
    session: []const u8,
    size: protocol.Size,
    cwd: ?[]const u8 = null,
    /// A snapshot to restore the screen and scrollback from.
    snapshot: ?[]const u8 = null,
    /// See `resume_cmd`.
    resume_cmd: ?[]const u8 = null,
    /// See `claimable`.
    claimable: bool = false,
};

pub fn create(gpa: std.mem.Allocator, opts: Options) !*Pane {
    const self = try gpa.create(Pane);
    errdefer gpa.destroy(self);

    const session = try gpa.dupe(u8, opts.session);
    errdefer gpa.free(session);

    const term = try initTerminal(opts);
    errdefer c.ghostty_terminal_free(term);

    const resume_cmd: ?[]u8 = if (opts.resume_cmd) |cmd| try gpa.dupe(u8, cmd) else null;
    errdefer if (resume_cmd) |cmd| gpa.free(cmd);

    var ws: c.struct_winsize = .{
        .ws_row = opts.size.rows,
        .ws_col = opts.size.cols,
        .ws_xpixel = opts.size.xpixel,
        .ws_ypixel = opts.size.ypixel,
    };
    var master: c_int = -1;
    var slave: c_int = -1;
    if (c.openpty(&master, &slave, null, null, &ws) != 0) return error.OpenPty;

    // Same as ghostty: the kernel needs IUTF8 to erase multi-byte
    // characters correctly in canonical mode.
    var attrs: c.struct_termios = undefined;
    if (c.tcgetattr(master, &attrs) == 0) {
        attrs.c_iflag |= c.IUTF8;
        _ = c.tcsetattr(master, c.TCSANOW, &attrs);
    }

    const pid = c.fork();
    if (pid < 0) {
        sys.close(master);
        sys.close(slave);
        return error.ForkFailed;
    }
    if (pid == 0) execChild(master, slave, opts);

    sys.close(slave);
    sys.setNonblock(master);
    sys.setCloexec(master);

    self.* = .{
        .gpa = gpa,
        .id = opts.id,
        .session = session,
        .master = master,
        .pid = pid,
        .term = term,
        .size = opts.size,
        .resume_cmd = resume_cmd,
        .claimable = opts.claimable,
    };

    // Query replies (DA, DSR, ...) are normally answered by the real
    // terminal the client runs in. While detached nobody would answer,
    // so the VT state answers instead; see `writePty`.
    _ = c.ghostty_terminal_set(term, c.GHOSTTY_TERMINAL_OPT_USERDATA, self);
    _ = c.ghostty_terminal_set(term, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @as(?*const anyopaque, @ptrCast(&writePty)));

    return self;
}

pub fn destroy(self: *Pane, gpa: std.mem.Allocator) void {
    if (!self.dead) {
        _ = c.kill(self.pid, c.SIGHUP);
        sys.close(self.master);
    }
    c.ghostty_terminal_free(self.term);
    if (self.resume_cmd) |cmd| gpa.free(cmd);
    if (self.fg) |fg| fg.deinit(gpa);
    self.pending_in.deinit(gpa);
    self.backlog.deinit(gpa);
    gpa.free(self.session);
    gpa.destroy(self);
}

fn initTerminal(opts: Options) !c.GhosttyTerminal {
    var term: c.GhosttyTerminal = null;
    if (opts.snapshot) |snap| restore: {
        var decoder: c.GhosttySnapshotDecoder = null;
        if (c.ghostty_snapshot_decoder_new_buf(null, &decoder, snap.ptr, snap.len) != c.GHOSTTY_SUCCESS)
            break :restore;
        defer c.ghostty_snapshot_decoder_free(decoder);
        if (c.ghostty_snapshot_decoder_decode(decoder, &term) != c.GHOSTTY_SUCCESS) {
            log.warn("pane {d}: snapshot is corrupt, starting fresh", .{opts.id});
            term = null;
            break :restore;
        }

        // The program that owned this screen is gone. Leave the alternate
        // screen and drop modes it set so the new shell starts clean on
        // the primary screen, below the restored scrollback.
        c.ghostty_terminal_vt_write(term, restore_modes.ptr, restore_modes.len);
        const banner = "\r\n\x1b[2m\u{2500}\u{2500} restored by spooky \u{2500}\u{2500}\x1b[0m\r\n";
        c.ghostty_terminal_vt_write(term, banner.ptr, banner.len);
        _ = c.ghostty_terminal_resize(term, opts.size.cols, opts.size.rows, 0, 0);
    }
    if (term == null) {
        if (c.ghostty_terminal_new(null, &term, opts.size.cols, opts.size.rows) != c.GHOSTTY_SUCCESS)
            return error.TerminalInit;
    }

    _ = c.ghostty_terminal_set(term, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback_lines);
    _ = c.ghostty_terminal_set(term, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback_bytes);
    return term;
}

/// Undo what full screen programs commonly leave enabled: alt screen,
/// mouse reporting, focus events, bracketed paste, kitty keyboard flags,
/// hidden cursor and SGR state.
pub const restore_modes = "\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l" ++
    "\x1b[?1004l\x1b[?2004l\x1b[=0;1u\x1b[?25h\x1b[0m";

fn execChild(master: c_int, slave: c_int, opts: Options) noreturn {
    sys.close(master);
    _ = c.setsid();
    _ = c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0));
    _ = c.dup2(slave, 0);
    _ = c.dup2(slave, 1);
    _ = c.dup2(slave, 2);
    if (slave > 2) sys.close(slave);

    // The daemon ignores these; the child must not inherit that.
    sys.defaultSignal(c.SIGPIPE);
    sys.defaultSignal(c.SIGHUP);
    sys.defaultSignal(c.SIGCHLD);

    if (opts.cwd) |cwd| {
        var buf: [4096]u8 = undefined;
        if (cwd.len < buf.len) {
            @memcpy(buf[0..cwd.len], cwd);
            buf[cwd.len] = 0;
            _ = c.chdir(@ptrCast(&buf));
        }
    }

    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrintSentinel(&id_buf, "{d}", .{opts.id}, 0) catch unreachable;
    _ = c.setenv("SPOOKY_PANE", id_str.ptr, 1);
    // Lets spooky tell it is running inside this pane even if the env was
    // inherited elsewhere, e.g. by a ghostty launched from this shell.
    if (c.ttyname(0)) |tty| _ = c.setenv("SPOOKY_TTY", tty, 1);

    const shell: [*:0]const u8 = c.getenv("SHELL") orelse "/bin/sh";
    const argv = [_:null]?[*:0]const u8{ shell, null };
    _ = c.execvp(shell, @ptrCast(&argv));
    c._exit(127);
}

fn writePty(
    _: c.GhosttyTerminal,
    userdata: ?*anyopaque,
    data: [*c]const u8,
    len: usize,
) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(userdata));
    if (self.client != null) return;
    self.pending_in.appendSlice(self.gpa, data[0..len]) catch {};
}

/// Past this much backlog, parse inline anyway to bound memory. A long
/// flood then runs at parser speed instead of passthrough speed.
const max_backlog = 32 * 1024 * 1024;

/// Queue bytes the process wrote for the VT state. While detached there is
/// no passthrough to protect and queries must be answered promptly by the
/// VT state, so those are parsed right away.
pub fn feed(self: *Pane, bytes: []const u8) void {
    if (self.client == null and self.backlog.items.len == 0) {
        self.parse(bytes);
        return;
    }
    self.backlog.appendSlice(self.gpa, bytes) catch {
        self.catchUp(null);
        self.parse(bytes);
        return;
    };
    if (self.backlog.items.len > max_backlog) self.catchUp(self.backlog.items.len - max_backlog / 2);
}

/// End the pane as a terminal would when its window closes: hang up the
/// shell and whatever runs in the foreground.
pub fn hangup(self: *Pane) void {
    self.closed_by_user = true;
    const fg = c.tcgetpgrp(self.master);
    if (fg > 0) _ = c.kill(-fg, c.SIGHUP);
    _ = c.kill(-self.pid, c.SIGHUP);
}

/// Forget the attached client. Deferred output is parsed first, while the
/// client is still set, because the client's terminal already answered any
/// queries in it and the VT state must not answer them a second time.
pub fn detach(self: *Pane) void {
    self.catchUp(null);
    self.client = null;
    if (self.close_on_detach and !self.dead) self.hangup();
}

/// Parse up to `limit` bytes of backlog, or all of it.
pub fn catchUp(self: *Pane, limit: ?usize) void {
    const n = @min(self.backlog.items.len, limit orelse self.backlog.items.len);
    if (n == 0) return;
    self.parse(self.backlog.items[0..n]);
    sys.consume(&self.backlog, n);
}

fn parse(self: *Pane, bytes: []const u8) void {
    c.ghostty_terminal_vt_write(self.term, bytes.ptr, bytes.len);
    self.dirty = true;
}

/// Encode the full terminal state for persisting. Fails if the parser is
/// in the middle of an escape sequence; try again on the next save.
/// Caller frees with `freeBuf`.
pub fn snapshot(self: *Pane) ![]u8 {
    self.catchUp(null);
    var ptr: [*c]u8 = null;
    var len: usize = 0;
    if (c.ghostty_snapshot_encode_alloc(self.term, null, &ptr, &len) != c.GHOSTTY_SUCCESS)
        return error.SnapshotFailed;
    if (ptr == null) return &.{};
    return ptr[0..len];
}

pub fn resize(self: *Pane, size: protocol.Size) void {
    if (size.cols == 0 or size.rows == 0) return;
    // Output so far was produced for the old size.
    self.catchUp(null);
    self.size = size;
    var ws: c.struct_winsize = .{
        .ws_row = size.rows,
        .ws_col = size.cols,
        .ws_xpixel = size.xpixel,
        .ws_ypixel = size.ypixel,
    };
    _ = c.ioctl(self.master, c.TIOCSWINSZ, &ws);
    _ = c.ghostty_terminal_resize(
        self.term,
        size.cols,
        size.rows,
        size.xpixel / size.cols,
        size.ypixel / size.rows,
    );
}

/// Encode the current screen (with scrollback, modes and cursor) as VT
/// sequences that recreate it in a fresh terminal. Caller frees with
/// `freeBuf`.
pub fn replay(self: *Pane) ![]u8 {
    self.catchUp(null);
    var opts = std.mem.zeroes(c.GhosttyFormatterTerminalOptions);
    opts.size = @sizeOf(c.GhosttyFormatterTerminalOptions);
    opts.emit = c.GHOSTTY_FORMATTER_FORMAT_VT;
    // Keep trailing blank rows so the absolute cursor position lines up.
    opts.trim = false;
    opts.extra.size = @sizeOf(c.GhosttyFormatterTerminalExtra);
    // The palette is left alone so the user's theme wins.
    opts.extra.modes = true;
    opts.extra.scrolling_region = true;
    opts.extra.tabstops = true;
    opts.extra.pwd = true;
    opts.extra.keyboard = true;
    opts.extra.screen = .{
        .size = @sizeOf(c.GhosttyFormatterScreenExtra),
        .cursor = true,
        .style = true,
        .hyperlink = true,
        .protection = true,
        .kitty_keyboard = true,
        .charsets = true,
    };

    var formatter: c.GhosttyFormatter = null;
    if (c.ghostty_formatter_terminal_new(null, &formatter, self.term, opts) != c.GHOSTTY_SUCCESS)
        return error.FormatterInit;
    defer c.ghostty_formatter_free(formatter);

    var ptr: [*c]u8 = null;
    var len: usize = 0;
    if (c.ghostty_formatter_format_alloc(formatter, null, &ptr, &len) != c.GHOSTTY_SUCCESS)
        return error.FormatFailed;
    if (ptr == null) return &.{};
    return ptr[0..len];
}

pub fn freeBuf(buf: []u8) void {
    if (buf.len == 0) return;
    c.ghostty_free(null, buf.ptr, buf.len);
}
