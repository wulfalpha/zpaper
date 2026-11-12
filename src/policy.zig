//! Output and scheduling policy. No filesystem, process, or clock access:
//! callers supply configuration, recorded state, time and backend capabilities.
const std = @import("std");
const u = @import("util.zig");
const config = @import("config.zig");
const state_mod = @import("state.zig");
const scheduling = @import("schedule.zig");
const LocalTime = @import("clock.zig").LocalTime;
const Assignment = state_mod.Assignment;

pub const ScheduleInfo = struct {
    enabled: bool,
    timezone: []const u8 = "local",
    current: ?scheduling.Event = null,
    next: ?scheduling.Event = null,
    manual_override: bool = false,
    held: bool = false,
    pending: bool = false,
};

pub const Context = struct {
    cfg: config.Config,
    state: state_mod.State,
    now: i64,
    local: ?LocalTime,
    per_output: bool,

    pub fn collectionName(self: Context) []const u8 {
        return self.cfg.selectedName(self.state.collection);
    }
    pub fn assigned(self: Context, output: []const u8) bool {
        return self.per_output and self.cfg.outputRule(output) != null;
    }
    pub fn assignedCollection(self: Context, output: []const u8) ?[]const u8 {
        const rule = self.cfg.outputRule(output) orelse return null;
        if (rule.collection.len > 0) return rule.collection;
        const schedule = self.cfg.namedSchedule(rule.schedule) orelse return null;
        const local = self.local orelse return schedule.rules[0].collection;
        return scheduling.evaluate(schedule.rules, local).?.current.collection;
    }
    pub fn collectionFor(self: Context, output: []const u8) []const u8 {
        if (self.per_output) if (self.assignedCollection(output)) |name| return name;
        return self.collectionName();
    }
    pub fn scheduleWindow(self: Context) !?scheduling.Window {
        if (self.cfg.schedule.len == 0) return null;
        return scheduling.evaluate(self.cfg.schedule, self.local orelse return error.InvalidLocalTime);
    }
    pub fn namedWindow(self: Context, name: []const u8) !?scheduling.Window {
        const schedule = self.cfg.namedSchedule(name) orelse return null;
        return scheduling.evaluate(schedule.rules, self.local orelse return error.InvalidLocalTime);
    }
    pub const GlobalDecision = enum { wait, held, acknowledge, record, rotate };
    pub fn globalDecision(self: Context, window: scheduling.Window, has_unassigned: bool) GlobalDecision {
        if (!scheduling.due(window, self.state.schedule_cursor)) return .wait;
        if (self.state.held("*", self.now)) return .held;
        if (!has_unassigned) return .record;
        if (!u.eql(self.collectionName(), window.current.collection) or self.state.current.len == 0) return .rotate;
        return .acknowledge;
    }
    pub const ScheduleTargets = struct { outputs: []const []const u8, found: bool };
    pub fn scheduleTargets(self: Context, a: u.A, name: []const u8, connected: []const Assignment, only: ?[]const u8) !ScheduleTargets {
        var outputs: std.ArrayList([]const u8) = .empty;
        var found = false;
        for (connected) |entry| {
            const rule = self.cfg.outputRule(entry.output) orelse continue;
            if (!u.eql(rule.schedule, name)) continue;
            if (only) |output| if (!u.eql(output, entry.output)) continue;
            found = true;
            if (self.state.held(entry.output, self.now)) continue;
            try outputs.append(a, entry.output);
        }
        return .{ .outputs = try outputs.toOwnedSlice(a), .found = found };
    }
    pub const NamedDecision = enum { wait, acknowledge, change };
    pub fn namedDecision(self: Context, name: []const u8, window: scheduling.Window) NamedDecision {
        const previous = self.state.scheduleCursor(name) orelse return .acknowledge;
        if (!scheduling.due(window, previous.cursor)) return .wait;
        if (u.eql(previous.collection, window.current.collection)) return .acknowledge;
        return .change;
    }
    pub const RotationTarget = struct { output: []const u8, collection: []const u8 };
    pub const RotationPlan = struct { targets: []const RotationTarget, reset_active_timer: bool = false };
    // The engine validates the requested output names before planning. The
    // plan chooses collections and respects holds but never consumes shuffle
    // progress; only the application layer can commit successful changes.
    pub fn planRotation(self: Context, a: u.A, connected: []const Assignment, outputs: []const []const u8, automatic: bool, active_only: bool) !RotationPlan {
        if (active_only and automatic) {
            var unassigned = false;
            for (connected) |entry| if (!self.assigned(entry.output)) {
                unassigned = true;
            };
            if (!unassigned) return .{ .targets = &.{}, .reset_active_timer = true };
        }
        var targets: std.ArrayList(RotationTarget) = .empty;
        for (outputs) |output| {
            if (active_only and self.assigned(output)) continue;
            if (automatic and self.state.held(output, self.now)) continue;
            try targets.append(a, .{ .output = output, .collection = self.collectionFor(output) });
        }
        return .{ .targets = try targets.toOwnedSlice(a) };
    }
    pub fn scheduleInfo(self: Context) !ScheduleInfo {
        const window = (try self.scheduleWindow()) orelse return .{ .enabled = false };
        const pending = scheduling.due(window, self.state.schedule_cursor);
        return .{ .enabled = true, .current = window.current, .next = scheduling.nextChange(self.cfg.schedule, window, self.state.schedule_cursor), .manual_override = if (self.state.schedule_cursor) |cursor| cursor.manual and !pending else false, .held = self.state.held("*", self.now), .pending = pending };
    }
    pub fn namedScheduleInfo(self: Context, schedule: config.NamedSchedule) !ScheduleInfo {
        const window = (try self.namedWindow(schedule.name)).?;
        const previous = self.state.scheduleCursor(schedule.name);
        const cursor = if (previous) |known| known.cursor else null;
        const pending = if (previous) |known| scheduling.due(window, cursor) and !u.eql(known.collection, window.current.collection) else false;
        var held = self.state.held("*", self.now);
        if (!held) {
            var any = false;
            held = true;
            for (self.cfg.outputs) |rule| if (u.eql(rule.schedule, schedule.name)) {
                any = true;
                if (!self.state.held(rule.output, self.now)) held = false;
            };
            held = held and any;
        }
        return .{ .enabled = true, .current = window.current, .next = scheduling.nextChange(schedule.rules, window, cursor), .manual_override = if (cursor) |c| c.manual and !pending else false, .held = held, .pending = pending };
    }
};

pub fn planImages(a: u.A, outputs: []const []const u8, paths: []const []const u8) ![]const Assignment {
    if (paths.len == 0) return error.NoImagesFound;
    if (paths.len > outputs.len) return error.TooManyImages;
    var desired: std.ArrayList(Assignment) = .empty;
    for (outputs, 0..) |output, i| {
        if (paths.len > 1 and i >= paths.len) break;
        try desired.append(a, .{ .output = output, .image = paths[if (paths.len == 1) 0 else i] });
    }
    return desired.toOwnedSlice(a);
}

test "rotation plans separate assigned collections, holds and manual choices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]scheduling.Rule{.{ .minute = 0, .collection = "night" }};
    var ctx = Context{
        .cfg = .{ .outputs = &.{ .{ .output = "DP-1", .collection = "work" }, .{ .output = "DP-2", .schedule = "daily" } }, .schedules = &.{.{ .name = "daily", .rules = &rules }} },
        .state = .{ .holds = &.{.{ .output = "DP-2", .until = 200 }} },
        .now = 100,
        .local = .{ .day = 1, .minute = 500, .utc_offset_seconds = 0 },
        .per_output = true,
    };
    const connected = [_]Assignment{ .{ .output = "DP-1", .image = "a" }, .{ .output = "DP-2", .image = "b" }, .{ .output = "DP-3", .image = "c" } };
    const outputs = [_][]const u8{ "DP-1", "DP-2", "DP-3" };
    const automatic = try ctx.planRotation(a, &connected, &outputs, true, false);
    try std.testing.expectEqual(@as(usize, 2), automatic.targets.len);
    try std.testing.expectEqualStrings("work", automatic.targets[0].collection);
    try std.testing.expectEqualStrings("default", automatic.targets[1].collection);
    const manual = try ctx.planRotation(a, &connected, &outputs, false, false);
    try std.testing.expectEqualStrings("night", manual.targets[1].collection);
    const active = try ctx.planRotation(a, &connected, &outputs, true, true);
    try std.testing.expectEqual(@as(usize, 1), active.targets.len);
    try std.testing.expectEqualStrings("DP-3", active.targets[0].output);
    try std.testing.expect((try ctx.planRotation(a, connected[0..2], outputs[0..2], true, true)).reset_active_timer);
    ctx.per_output = false;
    try std.testing.expectEqualStrings("default", ctx.collectionFor("DP-1"));
    // Planning never consumes shuffle progress or changes a recorded image.
    try std.testing.expectEqual(@as(usize, 0), ctx.state.seen.len);
}

test "schedule decisions preserve pending holds, first observation and manual overrides" {
    const rules = [_]scheduling.Rule{.{ .minute = 0, .collection = "work" }};
    var ctx = Context{ .cfg = .{ .schedule = &rules }, .state = .{}, .now = 100, .local = .{ .day = 1, .minute = 500, .utc_offset_seconds = 0 }, .per_output = true };
    const window = (try ctx.scheduleWindow()).?;
    try std.testing.expectEqual(Context.GlobalDecision.rotate, ctx.globalDecision(window, true));
    try std.testing.expectEqual(Context.GlobalDecision.record, ctx.globalDecision(window, false));
    ctx.state.holds = &.{.{ .until = -1 }};
    try std.testing.expectEqual(Context.GlobalDecision.held, ctx.globalDecision(window, true));
    ctx.state.holds = &.{};
    ctx.state.schedule_cursor = scheduling.manualOverride(window, null);
    try std.testing.expectEqual(Context.GlobalDecision.wait, ctx.globalDecision(window, true));
    try std.testing.expectEqual(Context.NamedDecision.acknowledge, ctx.namedDecision("daily", window));
    ctx.state.schedule_cursors = &.{.{ .name = "daily", .collection = "other", .cursor = .{ .key = 0, .fingerprint = 0 } }};
    try std.testing.expectEqual(Context.NamedDecision.change, ctx.namedDecision("daily", window));
}

test "image plans preserve requested order and leave remaining monitors alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outputs = [_][]const u8{ "DP-2", "DP-1", "DP-3" };
    const plan = try planImages(a, &outputs, &.{ "a", "b" });
    try std.testing.expectEqual(@as(usize, 2), plan.len);
    try std.testing.expectEqualStrings("DP-2", plan[0].output);
    try std.testing.expectEqualStrings("b", plan[1].image);
    try std.testing.expectEqual(@as(usize, 3), (try planImages(a, &outputs, &.{"a"})).len);
    try std.testing.expectError(error.TooManyImages, planImages(a, outputs[0..1], &.{ "a", "b" }));
}
