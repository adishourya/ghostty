//! The wire protocol between the spooky daemon and its clients: `spooky`
//! proxies, CLI commands, and ghostty itself (the "controller").
//!
//! Every message is a frame: a one byte tag, a little-endian u32 payload
//! length, then the payload. Pane output and keyboard input are sent as raw
//! bytes inside `output` and `input` frames so the hot path is a memcpy.

const std = @import("std");

pub const max_payload = 1024 * 1024;
pub const header_len = 5;

pub const Tag = enum(u8) {
    // Client to server.

    /// Create a new pane and attach to it. Payload: `New`.
    new = 1,
    /// Attach to an existing pane. Payload: `Attach`, then optionally a
    /// session name to attach to that session's panes instead of `pane`.
    attach = 2,
    /// Bytes to write to the attached pane's pty.
    input = 3,
    /// The client's terminal changed size. Payload: `Size`.
    resize = 4,
    /// Request a human readable listing of all panes.
    list = 5,
    /// Ask the daemon to exit, killing all panes.
    kill_server = 6,
    /// Decide what the next adopting client (a new ghostty window, tab or
    /// split) attaches to. Payload: `Prepare`, then a session name. Used
    /// when no controller is connected.
    prepare = 7,
    /// Ghostty announcing itself as the controller. No payload.
    controller = 8,
    /// From the controller: every window, tab and split it has open, as
    /// JSON (`layout.Report`). Sent whenever it changes.
    layout = 9,
    /// From the controller: the user closed these surfaces (a split or a
    /// tab, not a whole window). Payload: little-endian u64 surface ids.
    closed = 10,
    /// Ask the controller to open a session, pane or new session in a new
    /// window. Payload: `Prepare`, then a name. Fails with `no_controller`
    /// if ghostty isn't connected.
    open = 11,
    /// Rename a session. Payload: old name (empty: the session of pane
    /// `Rename.pane`), a zero byte, then the new name.
    rename = 12,
    /// Delete a session: end its panes and forget it, including panes
    /// waiting to be resurrected. Payload: the session name.
    remove = 13,
    /// The name of a pane's session, as text. Payload: u32 pane id.
    session = 14,

    // Server to client.

    /// The client is attached. Payload: u32 pane id.
    attached = 64,
    /// Bytes the pane wrote to its pty.
    output = 65,
    /// The pane's process exited. Payload: i32 exit code.
    exit = 66,
    /// The request failed. Payload: message.
    err = 67,
    /// Reply to `list`. Payload: text.
    text = 68,
    /// Another client attached to this pane and took it over.
    detached = 69,

    // Server to controller.

    /// Open a window. Payload: JSON `layout.Open`.
    open_window = 70,
    /// Bring a window to the front. Payload: little-endian u64 window id.
    present_window = 71,
    /// Which surfaces show a pane and which windows show a session, so
    /// ghostty can run spooky in new tabs and splits opened from a pane and
    /// show each window's session. Payload: JSON `layout.Surfaces`. Sent
    /// whenever it changes.
    surfaces = 72,

    _,
};

pub const Size = extern struct {
    cols: u16,
    rows: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

/// Payload of `Tag.new`, followed by `cwd_len` bytes of working directory
/// and then the session name as the remainder. An empty session name means
/// the window's session when ghostty is the controller, otherwise the
/// active session: the one most recently typed in.
pub const New = extern struct {
    size: Size,
    cwd_len: u32,
    flags: Flags = .{},
    /// GHOSTTY_SURFACE_ID of the surface the client runs in, or zero.
    surface: u64 = 0,

    pub const Flags = packed struct(u32) {
        /// Attach to a resurrected pane nobody has claimed yet, if there
        /// is one, instead of creating a new pane.
        adopt: bool = false,
        _: u31 = 0,
    };
};

pub const Attach = extern struct {
    size: Size,
    /// Zero to attach by session name instead.
    pane: u32,
    _pad: u32 = 0,
    /// GHOSTTY_SURFACE_ID of the surface the client runs in, or zero.
    surface: u64 = 0,
};

pub const Rename = extern struct {
    pane: u32 = 0,
};

/// Error message the daemon sends for `open` without a controller.
pub const no_controller = "no-controller";

pub const Prepare = extern struct {
    kind: Kind,
    pane: u32 = 0,

    pub const Kind = enum(u32) {
        /// A new pane in the named session (for `open`: a new session).
        new = 0,
        /// The pane with id `pane`.
        pane = 1,
        /// The named session's detached panes, one per window or split.
        session = 2,
        _,
    };
};

pub const Frame = struct {
    tag: Tag,
    payload: []const u8,
};

pub fn writeHeader(buf: *[header_len]u8, tag: Tag, len: usize) void {
    buf[0] = @backingInt(tag);
    std.mem.writeInt(u32, buf[1..5], @intCast(len), .little);
}

/// Append a frame to `out`.
pub fn append(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tag: Tag,
    payload: []const u8,
) !void {
    var hdr: [header_len]u8 = undefined;
    writeHeader(&hdr, tag, payload.len);
    try out.ensureUnusedCapacity(gpa, header_len + payload.len);
    out.appendSliceAssumeCapacity(&hdr);
    out.appendSliceAssumeCapacity(payload);
}

/// Parse one complete frame from the front of `buf`. Returns null if more
/// bytes are needed. The returned payload borrows from `buf`.
pub fn parse(buf: []const u8) error{FrameTooLarge}!?struct { frame: Frame, len: usize } {
    if (buf.len < header_len) return null;
    const len = std.mem.readInt(u32, buf[1..5], .little);
    if (len > max_payload) return error.FrameTooLarge;
    const total = header_len + @as(usize, len);
    if (buf.len < total) return null;
    return .{
        .frame = .{ .tag = @fromBackingInt(@intCast(buf[0])), .payload = buf[header_len..total] },
        .len = total,
    };
}

/// Read a fixed size extern struct from the front of a payload.
pub fn readStruct(comptime T: type, payload: []const u8) ?T {
    if (payload.len < @sizeOf(T)) return null;
    var v: T = undefined;
    @memcpy(std.mem.asBytes(&v), payload[0..@sizeOf(T)]);
    return v;
}

test "frame roundtrip" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try append(gpa, &out, .output, "hello");
    try append(gpa, &out, .exit, "");

    const a = (try parse(out.items)).?;
    try std.testing.expectEqual(Tag.output, a.frame.tag);
    try std.testing.expectEqualStrings("hello", a.frame.payload);

    const b = (try parse(out.items[a.len..])).?;
    try std.testing.expectEqual(Tag.exit, b.frame.tag);
    try std.testing.expectEqual(out.items.len, a.len + b.len);

    try std.testing.expect(try parse(out.items[0..3]) == null);
}
