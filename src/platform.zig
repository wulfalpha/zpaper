//! Linux primitives not covered by the portable I/O API: signals, process-group
//! cleanup, descriptor polling, runtime-directory ownership and directory fsync.
const std = @import("std");
const c = @cImport({
    // translate-c cannot lower glibc's fortified variadic fcntl wrappers in
    // optimized builds. Import the underlying declarations; Zig checks buffers.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/wait.h");
    @cInclude("errno.h");
    @cInclude("spawn.h");
});
pub const poll = std.posix.poll;
pub const pollfd = std.posix.pollfd;
pub const POLL = std.posix.POLL;
pub const SIG = std.posix.SIG;
pub fn signals(handler: *const fn (SIG) callconv(.c) void) void {
    const action = std.posix.Sigaction{ .handler = .{ .handler = handler }, .mask = std.posix.sigemptyset(), .flags = 0 };
    for ([_]SIG{ .TERM, .INT, .USR1 }) |sig| std.posix.sigaction(sig, &action, null);
}
pub fn syncDir(fd: c_int) !void {
    while (c.fsync(fd) != 0) {
        if (std.posix.errno(-1) != .INTR) return error.DirectorySyncFailed;
    }
}
pub fn verifyRuntime(fd: c_int) !void {
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return error.StatFailed;
    if (st.st_uid != c.getuid() or st.st_mode & 0o077 != 0) return error.UnsafeRuntimeDirectory;
}
pub fn killGroup(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, .KILL) catch {};
}
pub fn waitNoHang(pid: std.posix.pid_t) !?u32 {
    var status: c_int = 0;
    while (true) {
        const result = c.waitpid(pid, &status, c.WNOHANG);
        if (result > 0) return @bitCast(status);
        if (result == 0) return null;
        if (std.posix.errno(result) != .INTR) return error.WaitFailed;
    }
}
pub fn readReady(fd: c_int, buf: []u8) !usize {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n >= 0) return @intCast(n);
        if (std.posix.errno(n) != .INTR) return error.ReadFailed;
    }
}
pub fn send(fd: c_int, bytes: []const u8) !usize {
    while (true) {
        const n = c.send(fd, bytes.ptr, bytes.len, c.MSG_NOSIGNAL | c.MSG_DONTWAIT);
        if (n >= 0) return @intCast(n);
        switch (std.posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.SendFailed,
        }
    }
}
pub fn receive(fd: c_int, bytes: []u8) !usize {
    while (true) {
        const n = c.recv(fd, bytes.ptr, bytes.len, c.MSG_DONTWAIT);
        if (n >= 0) return @intCast(n);
        switch (std.posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.ReceiveFailed,
        }
    }
}
// Zig 0.16's UnixAddress.connect maps ECONNREFUSED to Unexpected. We need to
// distinguish a stale socket from permission/protocol failures before taking
// the owner lock. Keep this narrow workaround until std exposes that error.
pub fn connectUnix(path: []const u8) !?std.Io.net.Stream {
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    if (path.len >= addr.sun_path.len) return error.NameTooLong;
    addr.sun_family = c.AF_UNIX;
    @memcpy(@as([*]u8, @ptrCast(&addr.sun_path))[0..path.len], path);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    var owned = true;
    defer if (owned) {
        _ = c.close(fd);
    };
    while (std.c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) {
        switch (std.posix.errno(-1)) {
            .INTR => continue,
            .NOENT, .CONNREFUSED => return null,
            .ACCES, .PERM => return error.AccessDenied,
            else => return error.ConnectFailed,
        }
    }
    owned = false;
    return .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .loopback(0) } } };
}

// The installed 0.16 Threaded.processSpawnPosix returns exec errors without
// closing the captured pipes or reaping the failed child. posix_spawnp reports
// these errors synchronously and reaps that child before returning. Keep this
// workaround here; the caller still owns a normal std.process.Child/Io.File.
pub fn spawnCommand(a: std.mem.Allocator, environ: std.process.Environ, argv: []const []const u8, log_path: ?[]const u8) !std.process.Child {
    const args = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, args) |arg, *dest| dest.* = (try a.dupeZ(u8, arg)).ptr;
    const out = try capturePipe();
    errdefer closeRaw(out[0]);
    defer closeRaw(out[1]);
    const err = try capturePipe();
    errdefer closeRaw(err[0]);
    defer closeRaw(err[1]);
    var actions: c.posix_spawn_file_actions_t = undefined;
    try spawnResult(c.posix_spawn_file_actions_init(&actions));
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    try spawnResult(c.posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", c.O_RDONLY, 0));
    if (log_path) |path| {
        const path_z = try a.dupeZ(u8, path);
        try spawnResult(c.posix_spawn_file_actions_addopen(&actions, 1, path_z.ptr, c.O_WRONLY | c.O_CREAT | c.O_APPEND, 0o600));
        try spawnResult(c.posix_spawn_file_actions_adddup2(&actions, 1, 2));
    } else {
        try spawnResult(c.posix_spawn_file_actions_adddup2(&actions, out[1], 1));
        try spawnResult(c.posix_spawn_file_actions_adddup2(&actions, err[1], 2));
    }
    // When logging, both capture pipes reach EOF immediately. The bounded
    // runner can still wait for the launcher without owning the daemon's log.
    for ([_]c_int{ out[0], out[1], err[0], err[1] }) |fd|
        try spawnResult(c.posix_spawn_file_actions_addclose(&actions, fd));
    var attributes: c.posix_spawnattr_t = undefined;
    try spawnResult(c.posix_spawnattr_init(&attributes));
    defer _ = c.posix_spawnattr_destroy(&attributes);
    try spawnResult(c.posix_spawnattr_setflags(&attributes, c.POSIX_SPAWN_SETPGROUP));
    try spawnResult(c.posix_spawnattr_setpgroup(&attributes, 0));
    var pid: c.pid_t = undefined;
    try spawnResult(c.posix_spawnp(&pid, args[0].?, &actions, &attributes, @ptrCast(@constCast(args.ptr)), @ptrCast(@constCast(environ.block.slice.ptr))));
    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = .{ .handle = out[0], .flags = .{ .nonblocking = false } },
        .stderr = .{ .handle = err[0], .flags = .{ .nonblocking = false } },
        .request_resource_usage_statistics = false,
    };
}
fn spawnResult(code: c_int) !void {
    if (code == 0) return;
    return switch (code) {
        c.ENOENT => error.FileNotFound,
        c.EACCES, c.EPERM => error.AccessDenied,
        c.ENOEXEC => error.InvalidExecutable,
        c.ENOMEM => error.OutOfMemory,
        else => error.SpawnFailed,
    };
}
fn closeRaw(fd: c_int) void {
    _ = c.close(fd);
}
fn capturePipe() ![2]c_int {
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return error.PipeFailed;
    errdefer for (fds) |fd| closeRaw(fd);
    // Keep action sources distinct from stdin/stdout/stderr even when a caller
    // launched zpaper with one of those standard descriptors closed.
    for (&fds) |*fd| if (fd.* <= 2) {
        const replacement = c.fcntl(fd.*, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
        if (replacement < 0) return error.PipeFailed;
        closeRaw(fd.*);
        fd.* = replacement;
    };
    return fds;
}
