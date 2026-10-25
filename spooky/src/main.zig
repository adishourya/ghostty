const std = @import("std");
const c = @import("c");
const Server = @import("Server.zig");
const client = @import("client.zig");

pub const std_options: std.Options = .{
    // SPOOKY_DEBUG=1 in the daemon's environment logs protocol details.
    .log_level = .debug,
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (level == .debug and c.getenv("SPOOKY_DEBUG") == null) return;
    std.log.defaultLog(level, scope, format, args);
}

const usage =
    \\usage: spooky [command]
    \\
    \\  (none)               start a new pane (use as ghostty's `command`)
    \\  new [NAME]           open a new session in a new window
    \\  attach NAME          reopen a session's window, tabs and splits
    \\  attach -p ID         attach to one pane
    \\  rename [OLD] NEW     rename a session (default: this pane's)
    \\  rm NAME...           delete sessions: end their panes and forget them
    \\  ls [-p]              list sessions, or with -p, panes
    \\  restart-server       save everything and restart the daemon (to upgrade)
    \\  kill-server          stop the daemon and every pane, forgetting them
    \\  daemon               run the daemon in the foreground
    \\
    \\Inside a spooky pane, `new` and `attach` open a new ghostty window
    \\instead of nesting.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const inside = client.insidePane();

    if (args.len < 2) {
        if (inside) |id| {
            std.debug.print(
                \\spooky: already inside spooky pane {d}.
                \\Use `spooky new [NAME]` or `spooky attach NAME` to open another window.
                \\
            , .{id});
            std.process.exit(1);
        }
        std.process.exit(try client.new(gpa, "", .{ .adopt = true }));
    }
    const cmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "daemon")) {
        return Server.run(gpa);
    } else if (std.mem.eql(u8, cmd, "new")) {
        // `new NAME` and the older `new -s NAME`.
        const session = flag(rest, "-s") orelse positional(rest) orelse "";
        if (inside != null) std.process.exit(try client.openWindow(gpa, .new, 0, session));
        std.process.exit(try client.new(gpa, session, .{}));
    } else if (std.mem.eql(u8, cmd, "attach")) {
        if (flag(rest, "-p")) |arg| {
            const id = std.fmt.parseInt(u32, arg, 10) catch return fatal("invalid pane id");
            if (id == 0) return fatal("invalid pane id");
            if (inside) |self_id| {
                if (self_id == id) return fatal("already attached to that pane, it's this one");
                std.process.exit(try client.openWindow(gpa, .pane, id, ""));
            }
            std.process.exit(try client.attach(gpa, id, ""));
        }
        const session = flag(rest, "-s") orelse positional(rest) orelse
            return fatal("attach needs a session name (see `spooky ls`) or -p PANE_ID");
        if (session.len == 0) return fatal("attach needs a session name");
        if (inside != null) std.process.exit(try client.openWindow(gpa, .session, 0, session));
        std.process.exit(try client.attachSession(gpa, session));
    } else if (std.mem.eql(u8, cmd, "rename")) {
        switch (rest.len) {
            1 => {
                const id = inside orelse return fatal("not inside a spooky pane; use `spooky rename OLD NEW`");
                std.process.exit(try client.rename(gpa, id, "", rest[0]));
            },
            2 => std.process.exit(try client.rename(gpa, 0, rest[0], rest[1])),
            else => return fatal("usage: spooky rename [OLD] NEW"),
        }
    } else if (std.mem.eql(u8, cmd, "rm")) {
        if (rest.len == 0) return fatal("usage: spooky rm NAME... (see `spooky ls`)");
        var status: u8 = 0;
        for (rest) |name| status |= try client.remove(gpa, name);
        std.process.exit(status);
    } else if (std.mem.eql(u8, cmd, "ls")) {
        try client.list(gpa, flag(rest, "-p") != null);
    } else if (std.mem.eql(u8, cmd, "restart-server")) {
        try client.restartServer();
    } else if (std.mem.eql(u8, cmd, "kill-server")) {
        try client.killServer(gpa);
    } else {
        std.debug.print(usage, .{});
        std.process.exit(2);
    }
}

/// The value after `name` in `args`, "" if it's the last argument.
fn flag(args: []const [:0]const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        if (!std.mem.eql(u8, arg, name)) continue;
        return if (i + 1 < args.len) args[i + 1] else "";
    }
    return null;
}

/// The first argument that isn't a flag.
fn positional(args: []const [:0]const u8) ?[]const u8 {
    for (args) |arg| {
        if (arg.len > 0 and arg[0] != '-') return arg;
    }
    return null;
}

fn fatal(msg: []const u8) void {
    std.debug.print("spooky: {s}\n", .{msg});
    std.process.exit(1);
}

test {
    _ = @import("protocol.zig");
    _ = @import("persist.zig");
    _ = @import("layout.zig");
}
