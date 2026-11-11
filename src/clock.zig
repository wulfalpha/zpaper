//! Wall-clock access is isolated here for the Zig 0.16 I/O migration.
const std = @import("std");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("time.h");
    @cInclude("stdlib.h");
});

pub const LocalTime = struct {
    // Civil day number, independent of the day's UTC offset.
    day: i64,
    minute: u16,
    utc_offset_seconds: i64,
};
pub fn now(rt: Runtime) i64 {
    return std.Io.Timestamp.now(rt.io, .real).toSeconds();
}
pub fn localAt(timestamp: i64) !LocalTime {
    const time: c.time_t = @intCast(timestamp);
    var local: c.struct_tm = undefined;
    c.tzset();
    if (c.localtime_r(&time, &local) == null) return error.InvalidLocalTime;
    const offset: i64 = @intCast(local.tm_gmtoff);
    return .{
        .day = @divFloor(timestamp + offset, 86400),
        .minute = @intCast(local.tm_hour * 60 + local.tm_min),
        .utc_offset_seconds = offset,
    };
}

test "local civil time follows DST without assuming a 24 hour day" {
    const a = std.testing.allocator;
    const old = if (runtime.testing().env("TZ")) |value| try a.dupeZ(u8, value) else null;
    defer {
        if (old) |value| {
            _ = c.setenv("TZ", value, 1);
            a.free(value);
        } else {
            _ = c.unsetenv("TZ");
        }
        c.tzset();
    }
    // POSIX TZ rules avoid depending on an installed zoneinfo database in tests.
    try std.testing.expectEqual(@as(c_int, 0), c.setenv("TZ", "MST7MDT,M3.2.0,M11.1.0", 1));
    const spring_before = try localAt(1772960340); // 2026-03-08 08:59 UTC
    const spring_after = try localAt(1772960400);
    try std.testing.expectEqual(@as(u16, 119), spring_before.minute);
    try std.testing.expectEqual(@as(u16, 180), spring_after.minute);
    try std.testing.expectEqual(spring_before.day, spring_after.day);
    const fall_before = try localAt(1793519940); // 2026-11-01 07:59 UTC
    const fall_after = try localAt(1793520000);
    try std.testing.expectEqual(@as(u16, 119), fall_before.minute);
    try std.testing.expectEqual(@as(u16, 60), fall_after.minute);
    try std.testing.expectEqual(fall_before.day, fall_after.day);
}
