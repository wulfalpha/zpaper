const std = @import("std");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
pub const A = std.mem.Allocator;
pub threadlocal var diagnostic: []const u8 = "";

pub fn fail(a: A, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, CommandFailed } {
    diagnostic = std.fmt.allocPrint(a, fmt, args) catch return error.OutOfMemory;
    return error.CommandFailed;
}
pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn contains(xs: []const []const u8, x: []const u8) bool {
    for (xs) |v| if (eql(v, x)) return true;
    return false;
}
pub fn append(comptime T: type, a: A, xs: []const T, x: T) ![]const T {
    const out = try a.alloc(T, xs.len + 1);
    @memcpy(out[0..xs.len], xs);
    out[xs.len] = x;
    return out;
}
pub fn absolute(rt: Runtime, a: A, path: []const u8) ![]const u8 {
    if (eql(path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const home = rt.env("HOME") orelse return error.NoHomeDir;
        return std.fs.path.resolve(a, &.{ try std.process.currentPathAlloc(rt.io, a), home, if (path.len > 2) path[2..] else "." });
    }
    return std.fs.path.resolve(a, &.{ try std.process.currentPathAlloc(rt.io, a), path });
}
pub fn read(rt: Runtime, a: A, path: []const u8, limit: usize) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(rt.io, path, a, .limited(limit));
}
pub fn exists(rt: Runtime, path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    const f = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch return false;
    defer f.close(rt.io);
    const s = f.stat(rt.io) catch return false;
    return s.kind == .file;
}
pub fn atomicWrite(rt: Runtime, a: A, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp-{x}", .{ path, rt.randomInt(u64) });
    const f = try std.Io.Dir.createFileAbsolute(rt.io, tmp, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer f.close(rt.io);
    errdefer std.Io.Dir.deleteFileAbsolute(rt.io, tmp) catch {};
    try f.writeStreamingAll(rt.io, data);
    try f.sync(rt.io);
    try std.Io.Dir.renameAbsolute(tmp, path, rt.io);
    var dir = try std.Io.Dir.openDirAbsolute(rt.io, std.fs.path.dirname(path).?, .{ .iterate = true });
    defer dir.close(rt.io);
    try @import("platform.zig").syncDir(dir.handle);
}
// Tokenization is deliberately not a shell: quotes and escapes group arguments,
// but variables, pipes, command substitution and globbing are never evaluated.
pub fn words(a: A, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var quote: u8 = 0;
    var escape = false;
    var started = false;
    for (text) |c| {
        if (escape) {
            try word.append(a, c);
            escape = false;
            continue;
        }
        if (c == '\\' and quote != '\'') {
            escape = true;
            started = true;
            continue;
        }
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else {
                try word.append(a, c);
            }
        } else if (c == '\'' or c == '"') {
            quote = c;
            started = true;
        } else if (c == ' ' or c == '\t') {
            if (started) {
                try out.append(a, try word.toOwnedSlice(a));
                started = false;
            }
        } else {
            try word.append(a, c);
            started = true;
        }
    }
    if (quote != 0 or escape) return error.UnclosedQuote;
    if (started) try out.append(a, try word.toOwnedSlice(a));
    return out.toOwnedSlice(a);
}
pub fn duration(text: []const u8, bare_unit: u64) !u64 {
    if (text.len == 0) return error.InvalidDuration;
    const last = text[text.len - 1];
    if (std.ascii.isAlphabetic(last) and std.mem.indexOfScalar(u8, "smhd", last) == null) return error.InvalidDuration;
    const unit: u64 = switch (last) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => bare_unit,
    };
    const number = if (std.ascii.isAlphabetic(last)) text[0 .. text.len - 1] else text;
    const n = std.fmt.parseInt(u64, number, 10) catch return error.InvalidDuration;
    const seconds = std.math.mul(u64, n, unit) catch return error.InvalidDuration;
    if (seconds > 365 * 86400) return error.InvalidDuration;
    return seconds;
}

pub fn run(rt: Runtime, a: A, argv: []const []const u8, timeout_s: u64) ![]const u8 {
    return runWithLog(rt, a, argv, timeout_s, null);
}
/// The launched daemon must not inherit capture pipes owned by a short-lived
/// request. Persist its output so it remains writable after the launcher exits.
pub fn runLogged(rt: Runtime, a: A, argv: []const []const u8, timeout_s: u64, log_path: []const u8) !void {
    _ = try runWithLog(rt, a, argv, timeout_s, log_path);
}
fn runWithLog(rt: Runtime, a: A, argv: []const []const u8, timeout_s: u64, log_path: ?[]const u8) ![]const u8 {
    try rt.checkCancelled();
    if (argv.len == 0) return error.EmptyCommand;
    const platform = @import("platform.zig");
    var child = platform.spawnCommand(a, rt.environ, argv, log_path) catch |err| return fail(a, "cannot execute {s}: {s}", .{ argv[0], @errorName(err) });
    const pid = child.id.?;
    var status: ?u32 = null;
    var complete = false;
    // Even if the parent has exited, descendants can still hold its pipes open.
    // Kill the entire group on every incomplete run, then reap the parent once.
    defer {
        if (!complete) platform.killGroup(pid);
        if (status == null) {
            child.kill(rt.io);
        } else {
            child.stdout.?.close(rt.io);
            child.stderr.?.close(rt.io);
        }
    }
    var outputs: [2]std.ArrayList(u8) = .{ .empty, .empty };
    var fds = [_]platform.pollfd{
        .{ .fd = child.stdout.?.handle, .events = platform.POLL.IN, .revents = 0 },
        .{ .fd = child.stderr.?.handle, .events = platform.POLL.IN, .revents = 0 },
    };
    const start = std.Io.Timestamp.now(rt.io, .awake);
    while (true) {
        try rt.checkCancelled();
        _ = try platform.poll(&fds, 50);
        for (&fds, &outputs) |*fd, *output| {
            if (fd.fd < 0 or fd.revents == 0) continue;
            var buffer: [8192]u8 = undefined;
            const n = try platform.readReady(fd.fd, &buffer);
            if (n == 0) {
                fd.fd = -1;
                continue;
            }
            if (output.items.len + n > 1024 * 1024)
                return fail(a, "{s}: output exceeds 1 MiB", .{argv[0]});
            try output.appendSlice(a, buffer[0..n]);
        }
        if (status == null) status = try platform.waitNoHang(pid);
        if (status != null and fds[0].fd < 0 and fds[1].fd < 0) break;
        if (start.durationTo(std.Io.Timestamp.now(rt.io, .awake)).toNanoseconds() >= @as(i96, timeout_s) * std.time.ns_per_s)
            return fail(a, "{s}: timed out after {d}s", .{ argv[0], timeout_s });
    }
    complete = true;
    const stderr_text = outputs[1].items[0..@min(outputs[1].items.len, 8192)];
    if (!std.posix.W.IFEXITED(status.?)) return fail(a, "{s} terminated: {s}", .{ argv[0], stderr_text });
    const code = std.posix.W.EXITSTATUS(status.?);
    if (code != 0) return fail(a, "{s} exited {d}: {s}", .{ argv[0], code, stderr_text });
    return outputs[0].items;
}

test "quoted argv and durations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try words(arena.allocator(), "tool 'a b' \"x%s\" empty\\ value ''");
    try std.testing.expectEqual(@as(usize, 5), args.len);
    try std.testing.expectEqualStrings("a b", args[1]);
    try std.testing.expectEqualStrings("x%s", args[2]);
    try std.testing.expectEqualStrings("", args[4]);
    try std.testing.expectError(error.UnclosedQuote, words(arena.allocator(), "'bad"));
    try std.testing.expectEqual(@as(u64, 7200), try duration("2h", 60));
    try std.testing.expectEqual(@as(u64, 1800), try duration("30", 60));
    try std.testing.expectError(error.InvalidDuration, duration("5x", 60));
}

test "relative command paths are resolved against the client working directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try absolute(runtime.testing(), a, "pictures/../image.png");
    try std.testing.expect(std.fs.path.isAbsolute(path));
    const expected = try std.fs.path.join(a, &.{ try std.process.currentPathAlloc(std.testing.io, a), "image.png" });
    try std.testing.expectEqualStrings(expected, path);
    try std.testing.expect(!exists(runtime.testing(), "relative/path.png"));
}
