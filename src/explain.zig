//! Read-only explanations of recorded state and effective output policy.
const std = @import("std");
const u = @import("util.zig");
const policy = @import("policy.zig");

pub const Output = struct {
    output: []const u8,
    recorded_image: ?[]const u8,
    collection: []const u8,
    collection_available: bool,
    source: enum { active_collection, fixed_collection, global_schedule, named_schedule },
    schedule_name: ?[]const u8,
    schedule: policy.ScheduleInfo,
    held: bool,
    // null: no active hold; -1: indefinite; otherwise Unix seconds.
    hold_until: ?i64,
    interval_seconds: u64,
    rotation_due: ?i64,
};

pub fn describe(ctx: policy.Context, output: []const u8) !Output {
    const assigned = ctx.assigned(output);
    const rule = if (assigned) ctx.cfg.outputRule(output) else null;
    const name = ctx.collectionFor(output);
    const cfg = ctx.cfg.effective(name) catch null;
    const schedule = if (rule) |r| (if (r.schedule.len > 0) try ctx.namedScheduleInfo(ctx.cfg.namedSchedule(r.schedule).?) else policy.ScheduleInfo{ .enabled = false }) else try ctx.scheduleInfo();
    var image: ?[]const u8 = null;
    for (ctx.state.current) |entry| if (u.eql(entry.output, output)) {
        image = if (entry.image.len > 0) entry.image else null;
    };
    var until: ?i64 = null;
    for (ctx.state.holds) |hold| {
        if (!u.eql(hold.output, "*") and !u.eql(hold.output, output)) continue;
        if (hold.until != -1 and hold.until <= ctx.now) continue;
        if (until == -1) continue;
        until = if (hold.until == -1) -1 else @max(until orelse hold.until, hold.until);
    }
    const interval = if (cfg) |c| c.interval else 0;
    const due = if (assigned) ctx.state.dueFor(name) else ctx.state.next_due;
    var info = schedule;
    info.held = until != null;
    return .{
        .output = output,
        .recorded_image = image,
        .collection = name,
        .collection_available = cfg != null,
        .source = if (rule) |r| (if (r.schedule.len > 0) .named_schedule else .fixed_collection) else (if (schedule.enabled) .global_schedule else .active_collection),
        .schedule_name = if (rule) |r| (if (r.schedule.len > 0) r.schedule else null) else null,
        .schedule = info,
        .held = until != null,
        .hold_until = until,
        .interval_seconds = interval,
        .rotation_due = if (interval > 0 and due != null and due.? > 0) due else null,
    };
}

pub fn render(a: u.A, ctx: policy.Context, daemon: bool, filter: ?[]const u8, json: bool, ignored: ?[]const u8) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    if (ctx.per_output) {
        for (ctx.state.current) |entry| if (!u.contains(names.items, entry.output)) {
            try names.append(a, entry.output);
        };
        for (ctx.cfg.outputs) |rule| if (!u.contains(names.items, rule.output)) {
            try names.append(a, rule.output);
        };
    } else try names.append(a, "*");
    var selected: std.ArrayList([]const u8) = .empty;
    if (filter) |value| {
        var parts = std.mem.splitScalar(u8, value, ',');
        while (parts.next()) |name| {
            if (name.len == 0 or u.contains(selected.items, name)) return error.InvalidOutput;
            if (!u.contains(names.items, name)) return u.fail(a, "output is not recorded or configured: {s}", .{name});
            try selected.append(a, name);
        }
    } else try selected.appendSlice(a, names.items);
    var outputs: std.ArrayList(Output) = .empty;
    for (selected.items) |name| try outputs.append(a, try describe(ctx, name));
    if (json) return std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, .{
        .daemon = daemon,
        .source = "recorded",
        .timezone = "local",
        .outputs = outputs.items,
        .note = ignored,
    }, .{})});
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "Recorded wallpapers and current policy (connection status is not reported).\n");
    if (!daemon) try text.appendSlice(a, "Daemon is not running; automatic changes require 'zpaper daemon'.\n");
    if (ignored) |note| try text.appendSlice(a, try std.fmt.allocPrint(a, "{s}\n", .{note}));
    if (outputs.items.len == 0) try text.appendSlice(a, "No recorded or configured outputs; set a wallpaper or start the daemon first.\n");
    for (outputs.items) |out| {
        try text.appendSlice(a, try std.fmt.allocPrint(a, "{s}:\n  recorded image: {s}\n  collection: {s}{s} ({s})\n", .{
            out.output, out.recorded_image orelse "none", out.collection, if (out.collection_available) "" else " [not defined]",
            switch (out.source) {
                .active_collection => "active collection",
                .fixed_collection => "fixed output assignment",
                .global_schedule => "active collection; global schedule",
                .named_schedule => "named schedule",
            },
        }));
        if (out.hold_until) |until| {
            if (until == -1) try text.appendSlice(a, "  held indefinitely; automatic changes wait for resume\n") else try text.appendSlice(a, try std.fmt.allocPrint(a, "  held for {d}s more; automatic changes wait for expiry or resume\n", .{until - ctx.now}));
        }
        if (out.schedule.enabled) {
            const info = out.schedule;
            const next = info.next.?;
            const day = next.day - ctx.local.?.day;
            try text.appendSlice(a, try std.fmt.allocPrint(a, "  schedule: {s}; current period selects {s}{s}\n", .{ out.schedule_name orelse "global", info.current.?.collection, if (info.pending) " (pending)" else "" }));
            try text.appendSlice(a, try std.fmt.allocPrint(a, "  {s}: {d:0>2}:{d:0>2} {s} -> {s} (local time; holds take precedence)\n", .{
                if (info.manual_override) "manual choice until scheduled change" else "next scheduled change",
                next.minute / 60,
                next.minute % 60,
                if (day == 0) "today" else if (day == 1) "tomorrow" else try std.fmt.allocPrint(a, "in {d} days", .{day}),
                next.collection,
            }));
        }
        if (out.interval_seconds == 0) {
            try text.appendSlice(a, "  interval rotation: disabled\n");
        } else if (out.rotation_due) |due| {
            try text.appendSlice(a, try std.fmt.allocPrint(a, "  interval rotation: every {d}s; due in {d}s{s}\n", .{ out.interval_seconds, @max(0, due - ctx.now), if (out.held) " (held)" else "" }));
        } else try text.appendSlice(a, try std.fmt.allocPrint(a, "  interval rotation: every {d}s; timer not started\n", .{out.interval_seconds}));
    }
    return text.toOwnedSlice(a);
}

test "explanations combine holds and separate manual schedule override from interval rotation" {
    const rules = [_]@import("schedule.zig").Rule{ .{ .minute = 0, .collection = "default" }, .{ .minute = 1200, .collection = "default" } };
    var ctx = policy.Context{ .cfg = .{ .schedule = &rules, .interval = 60 }, .state = .{ .next_due = 150 }, .now = 100, .local = .{ .day = 1, .minute = 600, .utc_offset_seconds = 0 }, .per_output = true };
    ctx.state.schedule_cursor = @import("schedule.zig").manualOverride((try ctx.scheduleWindow()).?, null);
    ctx.state.holds = &.{ .{ .output = "*", .until = 200 }, .{ .output = "DP-1", .until = 300 }, .{ .output = "DP-2", .until = -1 } };
    const first = try describe(ctx, "DP-1");
    try std.testing.expectEqual(@as(?i64, 300), first.hold_until);
    try std.testing.expect(first.schedule.manual_override);
    try std.testing.expectEqual(@as(?i64, 150), first.rotation_due);
    try std.testing.expectEqual(@as(?i64, -1), (try describe(ctx, "DP-2")).hold_until);
    ctx.now = 400;
    try std.testing.expect(!(try describe(ctx, "DP-1")).held);
    try std.testing.expectEqual(@as(u16, 1200), first.schedule.next.?.minute);
}
