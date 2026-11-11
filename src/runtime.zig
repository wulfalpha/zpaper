//! Process-owned I/O and environment, passed explicitly to effectful operations.
const std = @import("std");
pub const Runtime = struct {
    io: std.Io,
    environ: std.process.Environ,
    pub fn env(self: Runtime, name: []const u8) ?[]const u8 {
        return self.environ.getPosix(name);
    }
    pub fn sleep(self: Runtime, milliseconds: i64) !void {
        try self.io.sleep(.fromMilliseconds(milliseconds), .awake);
    }
    pub fn randomInt(self: Runtime, comptime T: type) T {
        var io = self.io;
        return std.Random.init(&io, fillRandom).int(T);
    }
    pub fn randomLessThan(self: Runtime, comptime T: type, limit: T) T {
        var io = self.io;
        return std.Random.init(&io, fillRandom).uintLessThan(T, limit);
    }
    fn fillRandom(io: *std.Io, bytes: []u8) void {
        io.random(bytes);
    }
};
pub fn testing() Runtime {
    return .{ .io = std.testing.io, .environ = std.testing.environ };
}
