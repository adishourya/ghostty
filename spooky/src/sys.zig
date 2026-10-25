//! Thin helpers over libc used by both the daemon and the client.

const std = @import("std");
const c = @import("c");

pub const Fd = c_int;

pub fn errno() c_int {
    return c.__errno_location().*;
}

pub fn close(fd: Fd) void {
    _ = c.close(fd);
}

pub fn setNonblock(fd: Fd) void {
    const flags = c.fcntl(fd, c.F_GETFL);
    _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
}

pub fn setCloexec(fd: Fd) void {
    const flags = c.fcntl(fd, c.F_GETFD);
    _ = c.fcntl(fd, c.F_SETFD, flags | c.FD_CLOEXEC);
}

/// Write as much of `buf` as possible without blocking. Returns the number
/// of bytes written; 0 if the fd would block.
pub fn writeSome(fd: Fd, buf: []const u8) error{WriteFailed}!usize {
    while (true) {
        const n = c.write(fd, buf.ptr, buf.len);
        if (n >= 0) return @intCast(n);
        switch (errno()) {
            c.EINTR => continue,
            c.EAGAIN => return 0,
            else => return error.WriteFailed,
        }
    }
}

/// Blocking write of the whole buffer. Used by the client on its own tty.
pub fn writeAll(fd: Fd, buf: []const u8) error{WriteFailed}!void {
    var rest = buf;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n < 0) {
            switch (errno()) {
                c.EINTR => continue,
                c.EAGAIN => {
                    var pfd: c.struct_pollfd = .{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
                    _ = c.poll(&pfd, 1, -1);
                    continue;
                },
                else => return error.WriteFailed,
            }
        }
        rest = rest[@intCast(n)..];
    }
}

pub const ReadResult = union(enum) {
    data: usize,
    would_block,
    eof,
};

pub fn read(fd: Fd, buf: []u8) error{ReadFailed}!ReadResult {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n > 0) return .{ .data = @intCast(n) };
        if (n == 0) return .eof;
        switch (errno()) {
            c.EINTR => continue,
            c.EAGAIN => return .would_block,
            // A pty master returns EIO once every slave fd is closed.
            c.EIO => return .eof,
            else => return error.ReadFailed,
        }
    }
}

/// Drop the first `n` bytes of a byte list.
pub fn consume(list: *std.ArrayList(u8), n: usize) void {
    if (n == 0) return;
    const rest = list.items.len - n;
    std.mem.copyForwards(u8, list.items[0..rest], list.items[n..]);
    list.shrinkRetainingCapacity(rest);
}

/// Flush a pending output buffer to a non-blocking fd.
pub fn flush(fd: Fd, list: *std.ArrayList(u8)) error{WriteFailed}!void {
    while (list.items.len > 0) {
        const n = try writeSome(fd, list.items);
        if (n == 0) return;
        consume(list, n);
    }
}

/// Directory for the daemon socket. `$XDG_RUNTIME_DIR/spooky` if set,
/// otherwise `/tmp/spooky-$UID`.
pub fn runtimeDir(buf: []u8) ![:0]const u8 {
    if (c.getenv("XDG_RUNTIME_DIR")) |dir| {
        return std.fmt.bufPrintSentinel(buf, "{s}/spooky", .{std.mem.span(dir)}, 0);
    }
    return std.fmt.bufPrintSentinel(buf, "/tmp/spooky-{d}", .{c.getuid()}, 0);
}

/// Directory for persisted session state, which must survive a reboot.
/// `$XDG_STATE_HOME/spooky`, otherwise `~/.local/state/spooky`.
pub fn stateDir(buf: []u8) ![:0]const u8 {
    if (c.getenv("XDG_STATE_HOME")) |dir| {
        return std.fmt.bufPrintSentinel(buf, "{s}/spooky", .{std.mem.span(dir)}, 0);
    }
    const home = c.getenv("HOME") orelse return error.NoHome;
    return std.fmt.bufPrintSentinel(buf, "{s}/.local/state/spooky", .{std.mem.span(home)}, 0);
}

/// mkdir -p with mode 0700 for every created component.
pub fn makePath(path: [:0]const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            _ = c.mkdir(@ptrCast(&buf), 0o700);
        }
    }
}

/// `$SPOOKY_SOCKET` if set, otherwise `default.sock` in the runtime dir.
pub fn socketPath(buf: []u8) ![:0]const u8 {
    if (c.getenv("SPOOKY_SOCKET")) |path| {
        return std.fmt.bufPrintSentinel(buf, "{s}", .{std.mem.span(path)}, 0);
    }
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try runtimeDir(&dir_buf);
    return std.fmt.bufPrintSentinel(buf, "{s}/default.sock", .{dir}, 0);
}

fn unixAddr(path: []const u8) !c.struct_sockaddr_un {
    var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) return error.PathTooLong;
    @memcpy(addr.sun_path[0..path.len], path);
    return addr;
}

pub fn connectUnix(path: []const u8) !Fd {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer close(fd);
    const addr = try unixAddr(path);
    if (c.connect(fd, .{ .__sockaddr__ = @ptrCast(&addr) }, @sizeOf(c.struct_sockaddr_un)) != 0)
        return error.ConnectFailed;
    return fd;
}

pub fn listenUnix(path: [:0]const u8) !Fd {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer close(fd);
    const addr = try unixAddr(path);
    _ = c.unlink(path.ptr);
    if (c.bind(fd, .{ .__sockaddr__ = @ptrCast(&addr) }, @sizeOf(c.struct_sockaddr_un)) != 0)
        return error.BindFailed;
    if (c.listen(fd, 16) != 0) return error.ListenFailed;
    setNonblock(fd);
    return fd;
}

pub fn ignoreSignal(sig: c_int) void {
    _ = c.signal(sig, c.SIG_IGN);
}

pub fn defaultSignal(sig: c_int) void {
    _ = c.signal(sig, c.SIG_DFL);
}

/// Decode a waitpid status into an exit code, using 128+signal for
/// signaled processes like shells do.
pub fn exitCode(status: c_int) i32 {
    const sig = status & 0x7f;
    if (sig == 0) return (status >> 8) & 0xff;
    return 128 + sig;
}
