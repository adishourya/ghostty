//! Persisting panes so they can be resurrected after a reboot.
//!
//! Layout on disk, under the state dir:
//!
//!   state.json        every pane: id, session, cwd, size, foreground command
//!   panes/<id>.snap   libghostty-vt snapshot of the pane's screen + scrollback
//!
//! Files are written to a temporary name and renamed into place so a crash
//! or power loss mid-write leaves the previous version intact.

const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");

const log = std.log.scoped(.persist);

pub const PaneState = struct {
    id: u32,
    session: []const u8,
    cwd: []const u8,
    cols: u16,
    rows: u16,
    /// argv of the program in the foreground when it wasn't the shell.
    command: ?[]const []const u8 = null,
    /// A resume prompt that was restored but not yet answered, as a shell
    /// command line. Carried over so a second reboot doesn't lose it.
    pending_resume: ?[]const u8 = null,
};

pub const SessionState = struct {
    name: []const u8,
    /// `layout.Saved` as JSON: the session's tabs and splits.
    layout: ?[]const u8 = null,
};

pub const State = struct {
    version: u32 = 1,
    panes: []const PaneState,
    sessions: []const SessionState = &.{},
};

pub const Foreground = struct {
    cwd: []u8,
    argv: ?[][]u8,

    pub fn deinit(self: Foreground, gpa: std.mem.Allocator) void {
        gpa.free(self.cwd);
        if (self.argv) |argv| {
            for (argv) |arg| gpa.free(arg);
            gpa.free(argv);
        }
    }
};

/// Inspect what is running in a pane: the working directory and argv of
/// its foreground process group leader, or just the shell's directory when
/// the shell itself is in the foreground.
pub fn foreground(gpa: std.mem.Allocator, master: sys.Fd, shell_pid: c.pid_t) !Foreground {
    const pgid = c.tcgetpgrp(master);
    const pid = if (pgid > 0) pgid else shell_pid;

    var path_buf: [64]u8 = undefined;
    const cwd_path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/cwd", .{pid}, 0);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = c.readlink(cwd_path.ptr, &cwd_buf, cwd_buf.len);
    if (cwd_len <= 0) return error.ProcessGone;
    const cwd = try gpa.dupe(u8, cwd_buf[0..@intCast(cwd_len)]);
    errdefer gpa.free(cwd);

    if (pid == shell_pid) return .{ .cwd = cwd, .argv = null };

    const cmd_path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/cmdline", .{pid}, 0);
    const raw = readFile(gpa, cmd_path) catch return .{ .cwd = cwd, .argv = null };
    defer gpa.free(raw);

    var argv: std.ArrayList([]u8) = .empty;
    errdefer {
        for (argv.items) |arg| gpa.free(arg);
        argv.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, raw, "\x00"), 0);
    while (it.next()) |arg| try argv.append(gpa, try gpa.dupe(u8, arg));
    if (argv.items.len == 0) return .{ .cwd = cwd, .argv = null };
    return .{ .cwd = cwd, .argv = try argv.toOwnedSlice(gpa) };
}

/// Join argv into a line a POSIX-ish shell will parse back into the same
/// words, single-quoting anything that isn't obviously safe.
pub fn shellJoin(gpa: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (argv, 0..) |arg, i| {
        if (i > 0) try out.append(gpa, ' ');
        const safe = arg.len > 0 and for (arg) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-_./=:,+@%", ch) != null))
                break false;
        } else true;
        if (safe) {
            try out.appendSlice(gpa, arg);
            continue;
        }
        try out.append(gpa, '\'');
        for (arg) |ch| {
            if (ch == '\'') try out.appendSlice(gpa, "'\\''") else try out.append(gpa, ch);
        }
        try out.append(gpa, '\'');
    }
    return out.toOwnedSlice(gpa);
}

pub const Paths = struct {
    dir: [std.fs.max_path_bytes]u8 = undefined,
    dir_len: usize = 0,

    pub fn init() !Paths {
        var self: Paths = .{};
        const dir = try sys.stateDir(&self.dir);
        self.dir_len = dir.len;
        self.ensure();
        return self;
    }

    /// Create the directories, in case they were deleted while running.
    pub fn ensure(self: *const Paths) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const panes = std.fmt.bufPrintSentinel(&buf, "{s}/panes", .{self.dir[0..self.dir_len]}, 0) catch return;
        sys.makePath(panes);
    }

    pub fn state(self: *const Paths, buf: []u8) ![:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}/state.json", .{self.dir[0..self.dir_len]}, 0);
    }

    pub fn snapshot(self: *const Paths, buf: []u8, id: u32) ![:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}/panes/{d}.snap", .{ self.dir[0..self.dir_len], id }, 0);
    }
};

pub fn writeState(gpa: std.mem.Allocator, paths: *const Paths, state: State) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, state, .{ .whitespace = .indent_2 });
    defer gpa.free(json);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // state.json is small and is what decides what comes back, so make it
    // durable. Snapshots are best effort.
    try writeFileAtomic(try paths.state(&buf), json, true);
}

pub fn writeSnapshot(paths: *const Paths, id: u32, bytes: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try writeFileAtomic(try paths.snapshot(&buf, id), bytes, false);
}

pub fn removeSnapshot(paths: *const Paths, id: u32) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = paths.snapshot(&buf, id) catch return;
    _ = c.unlink(path.ptr);
}

pub fn readState(gpa: std.mem.Allocator, paths: *const Paths) !?std.json.Parsed(State) {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const bytes = readFile(gpa, try paths.state(&buf)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(bytes);
    return try std.json.parseFromSlice(State, gpa, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn readSnapshot(gpa: std.mem.Allocator, paths: *const Paths, id: u32) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = paths.snapshot(&buf, id) catch return null;
    return readFile(gpa, path) catch null;
}

fn writeFileAtomic(path: [:0]const u8, bytes: []const u8, durable: bool) !void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrintSentinel(&tmp_buf, "{s}.tmp", .{path}, 0);
    const fd = c.open(tmp.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.OpenFailed;
    errdefer _ = c.unlink(tmp.ptr);
    {
        defer sys.close(fd);
        try sys.writeAll(fd, bytes);
        if (durable and c.fsync(fd) != 0) return error.SyncFailed;
    }
    if (c.rename(tmp.ptr, path.ptr) != 0) return error.RenameFailed;
}

fn readFile(gpa: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return if (sys.errno() == c.ENOENT) error.FileNotFound else error.OpenFailed;
    defer sys.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        switch (try sys.read(fd, &buf)) {
            .data => |n| try out.appendSlice(gpa, buf[0..n]),
            .would_block => continue,
            .eof => break,
        }
    }
    return out.toOwnedSlice(gpa);
}

test "shellJoin" {
    const gpa = std.testing.allocator;
    const line = try shellJoin(gpa, &.{ "nvim", "src/main.zig", "it's here", "" });
    defer gpa.free(line);
    try std.testing.expectEqualStrings("nvim src/main.zig 'it'\\''s here' ''", line);
}
