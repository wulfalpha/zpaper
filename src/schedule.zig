//! Daily scheduling policy, independent of filesystem, processes, and clock I/O.
const std = @import("std");
const LocalTime = @import("clock.zig").LocalTime;
pub const Rule = struct { minute: u16, collection: []const u8 };
pub const Event = struct {
    day: i64,
    minute: u16,
    collection: []const u8,
    pub fn key(self: Event) i64 {
        return self.day * 1440 + self.minute;
    }
};
pub const Window = struct { current: Event, next: Event, fingerprint: u64 };
pub const Cursor = struct { key: i64, fingerprint: u64, manual: bool = false };

pub fn parseTime(text: []const u8) !u16 {
    if (text.len != 5 or text[2] != ':') return error.ExpectedHHMM;
    for ([_]usize{ 0, 1, 3, 4 }) |i| if (!std.ascii.isDigit(text[i])) return error.ExpectedHHMM;
    const hour = try std.fmt.parseInt(u16, text[0..2], 10);
    const minute = try std.fmt.parseInt(u16, text[3..5], 10);
    if (hour >= 24 or minute >= 60) return error.InvalidTime;
    return hour * 60 + minute;
}
pub fn fingerprint(rules: []const Rule) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (rules) |rule| {
        hash.update(&.{ @intCast(rule.minute >> 8), @truncate(rule.minute) });
        hash.update(rule.collection);
        hash.update(&.{0});
    }
    return hash.final();
}
// Rules must be sorted by minute and unique. Configuration validates this.
pub fn evaluate(rules: []const Rule, local: LocalTime) ?Window {
    if (rules.len == 0) return null;
    var current = Event{ .day = local.day - 1, .minute = rules[rules.len - 1].minute, .collection = rules[rules.len - 1].collection };
    var next = Event{ .day = local.day + 1, .minute = rules[0].minute, .collection = rules[0].collection };
    for (rules) |rule| {
        if (rule.minute <= local.minute) {
            current = .{ .day = local.day, .minute = rule.minute, .collection = rule.collection };
        } else {
            next = .{ .day = local.day, .minute = rule.minute, .collection = rule.collection };
            break;
        }
    }
    return .{ .current = current, .next = next, .fingerprint = fingerprint(rules) };
}
pub fn due(window: Window, cursor: ?Cursor) bool {
    const previous = cursor orelse return true;
    // A repeated local hour must not replay an older event. A changed schedule
    // is a new policy and is reconciled against the current time immediately.
    return previous.fingerprint != window.fingerprint or window.current.key() > previous.key;
}
// Skip already-processed wall times when displaying the next change during a
// repeated hour (or after a backwards clock adjustment).
pub fn nextChange(rules: []const Rule, window: Window, cursor: ?Cursor) Event {
    const previous = cursor orelse return window.next;
    if (previous.fingerprint != window.fingerprint or previous.key < window.next.key()) return window.next;
    const day = @divFloor(previous.key, 1440);
    for (rules) |rule| {
        const event = Event{ .day = day, .minute = rule.minute, .collection = rule.collection };
        if (event.key() > previous.key) return event;
    }
    return .{ .day = day + 1, .minute = rules[0].minute, .collection = rules[0].collection };
}
pub fn acknowledge(window: Window, manual: bool) Cursor {
    return .{ .key = window.current.key(), .fingerprint = window.fingerprint, .manual = manual };
}
pub fn manualOverride(window: Window, previous: ?Cursor) Cursor {
    var cursor = acknowledge(window, true);
    if (previous) |old| if (old.fingerprint == window.fingerprint) {
        cursor.key = @max(cursor.key, old.key);
    };
    return cursor;
}

test "daily boundaries, midnight, catch-up and changed schedules" {
    const rules = [_]Rule{ .{ .minute = 480, .collection = "day" }, .{ .minute = 1200, .collection = "night" } };
    var local = LocalTime{ .day = 100, .minute = 479, .utc_offset_seconds = 0 };
    const early = evaluate(&rules, local).?;
    try std.testing.expectEqual(@as(i64, 99), early.current.day);
    try std.testing.expectEqualStrings("night", early.current.collection);
    try std.testing.expectEqual(@as(u16, 480), early.next.minute);
    local.minute = 480;
    const morning = evaluate(&rules, local).?;
    try std.testing.expectEqualStrings("day", morning.current.collection);
    try std.testing.expect(due(morning, acknowledge(early, false)));
    try std.testing.expect(!due(morning, acknowledge(morning, false)));
    try std.testing.expect(!due(morning, manualOverride(morning, null)));
    local.minute = 1300;
    const evening = evaluate(&rules, local).?;
    try std.testing.expect(due(evening, acknowledge(morning, true)));
    try std.testing.expectEqual(@as(i64, 101), evening.next.day);
    local.day += 4;
    try std.testing.expect(due(evaluate(&rules, local).?, acknowledge(evening, false)));
    const changed = [_]Rule{ .{ .minute = 480, .collection = "work" }, rules[1] };
    try std.testing.expect(due(evaluate(&changed, local).?, acknowledge(evaluate(&rules, local).?, false)));
    try std.testing.expect(evaluate(&.{}, local) == null);
}
test "DST fold and skipped spring hour never replay intermediate events" {
    const rules = [_]Rule{ .{ .minute = 60, .collection = "one" }, .{ .minute = 90, .collection = "two" }, .{ .minute = 150, .collection = "three" } };
    const before = evaluate(&rules, .{ .day = 10, .minute = 119, .utc_offset_seconds = -21600 }).?;
    const folded = evaluate(&rules, .{ .day = 10, .minute = 60, .utc_offset_seconds = -25200 }).?;
    try std.testing.expect(!due(folded, acknowledge(before, false)));
    try std.testing.expectEqual(@as(u16, 150), nextChange(&rules, folded, acknowledge(before, false)).minute);
    try std.testing.expectEqual(before.current.key(), manualOverride(folded, acknowledge(before, false)).key);
    const spring = evaluate(&rules, .{ .day = 10, .minute = 180, .utc_offset_seconds = -21600 }).?;
    try std.testing.expectEqualStrings("three", spring.current.collection);
    try std.testing.expect(due(spring, acknowledge(before, false)));
}
test "strict wall clock times" {
    try std.testing.expectEqual(@as(u16, 0), try parseTime("00:00"));
    try std.testing.expectEqual(@as(u16, 1439), try parseTime("23:59"));
    for ([_][]const u8{ "7:00", "24:00", "12:60", "12:0a", "-1:00", "12:00:00" }) |bad| {
        if (parseTime(bad)) |_| return error.TestUnexpectedResult else |_| {}
    }
}
