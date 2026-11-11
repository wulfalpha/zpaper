const std = @import("std");
const runtime_mod = @import("runtime.zig");
const Runtime = runtime_mod.Runtime;
const platform = @import("platform.zig");
const u = @import("util.zig");
pub const Paths = struct { state: []const u8, socket: []const u8, lock: []const u8 };
pub fn paths(rt: Runtime, a: u.A, state_dir: []const u8) !Paths {
    try std.Io.Dir.cwd().createDirPath(rt.io, state_dir);
    const hash = std.hash.Wyhash.hash(0, state_dir);
    const runtime = if (rt.env("XDG_RUNTIME_DIR")) |dir|
        try std.fmt.allocPrint(a, "{s}/zpaper-{x}", .{ dir, hash })
    else
        try std.fmt.allocPrint(a, "/tmp/zpaper-{d}-{x}", .{ std.os.linux.getuid(), hash });
    std.Io.Dir.createDirAbsolute(rt.io, runtime, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
    var dir = try std.Io.Dir.openDirAbsolute(rt.io, runtime, .{ .follow_symlinks = false });
    defer dir.close(rt.io);
    try platform.verifyRuntime(dir.handle);
    return .{
        .state = try std.fs.path.join(a, &.{ state_dir, "state.json" }),
        .socket = try std.fs.path.join(a, &.{ runtime, "control.sock" }),
        .lock = try std.fs.path.join(a, &.{ state_dir, "owner.lock" }),
    };
}
pub fn lock(rt: Runtime, path: []const u8) !std.Io.File {
    const f = try std.Io.Dir.createFileAbsolute(rt.io, path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    errdefer f.close(rt.io);
    if (!try f.tryLock(rt.io, .exclusive)) return error.WouldBlock;
    return f;
}
pub fn connect(rt: Runtime, path: []const u8) !?std.Io.net.Stream {
    _ = rt;
    return platform.connectUnix(path);
}
pub fn listen(rt: Runtime, path: []const u8) !std.Io.net.Server {
    // Only called while holding the owner lock.
    std.Io.Dir.deleteFileAbsolute(rt.io, path) catch |err| if (err != error.FileNotFound) return err;
    const addr = try std.Io.net.UnixAddress.init(path);
    return addr.listen(rt.io, .{ .kernel_backlog = 16 });
}
fn ready(fd: std.posix.socket_t, events: i16, timeout_ms: i32) !void {
    var poll = [_]platform.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    if (try platform.poll(&poll, timeout_ms) == 0) return error.SocketTimeout;
}
pub fn send(rt: Runtime, a: u.A, fd: std.posix.socket_t, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    const line = try std.fmt.allocPrint(a, "{s}\n", .{bytes});
    var sent: usize = 0;
    const start = std.Io.Timestamp.now(rt.io, .awake);
    while (sent < line.len) {
        if (start.durationTo(std.Io.Timestamp.now(rt.io, .awake)).toNanoseconds() > 5 * std.time.ns_per_s) return error.SocketTimeout;
        try ready(fd, platform.POLL.OUT, 1000);
        const n = platform.send(fd, line[sent..]) catch |err| {
            if (err == error.WouldBlock) continue;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        sent += n;
    }
}
pub fn receive(rt: Runtime, a: u.A, fd: std.posix.socket_t, timeout_s: u64) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    const start = std.Io.Timestamp.now(rt.io, .awake);
    while (start.durationTo(std.Io.Timestamp.now(rt.io, .awake)).toNanoseconds() < @as(i96, timeout_s) * std.time.ns_per_s) {
        ready(fd, platform.POLL.IN, 1000) catch |err| {
            if (err == error.SocketTimeout) continue;
            return err;
        };
        const n = platform.receive(fd, &buf) catch |err| {
            if (err == error.WouldBlock) continue;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        if (bytes.items.len + n > 1024 * 1024) return error.MessageTooLarge;
        try bytes.appendSlice(a, buf[0..n]);
        if (std.mem.indexOfScalar(u8, bytes.items, '\n')) |end| return bytes.items[0..end];
    }
    return error.SocketTimeout;
}
