const std = @import("std");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const u = @import("util.zig");
const clock = @import("clock.zig");
const scheduling = @import("schedule.zig");
const config = @import("config.zig");
const backend = @import("backend.zig");
const state_mod = @import("state.zig");
const picker = @import("picker.zig");
const policy = @import("policy.zig");
const explanation = @import("explain.zig");
const Assignment = state_mod.Assignment;
pub const Action = enum { set, next, previous, hold, @"resume", current, status, explain, history, layouts, search, select, favorite, unfavorite, favorites, random_favorite, exclude, include, list, restore, import_legacy, clear_history, collections, use, schedule, daemon, stop, restart, reload, check };
pub const Request = struct {
    action: Action = .next,
    args: []const []const u8 = &.{},
    output: ?[]const u8 = null,
    json: bool = false,
    config_path: ?[]const u8 = null,
};
pub const Engine = struct {
    rt: Runtime,
    a: u.A,
    cfg: config.Config,
    state: state_mod.State,
    dirty: bool = false,
    wallpaper_applied: bool = false,
    // Injection point for deterministic scheduler/hold tests; never read from env.
    now_override: ?i64 = null,
    daemon: bool = false,
    message: std.ArrayList(u8) = .empty,
    // X11 monitor names, looked up at most once per request.
    x11_monitors: ?[]const []const u8 = null,
    x11_checked: bool = false,
    // Outputs the last successful change applied to, for manual overrides.
    changed_outputs: []const []const u8 = &.{},
    fn now(self: *Engine) i64 {
        return self.now_override orelse clock.now(self.rt);
    }
    fn policyContext(self: *Engine) policy.Context {
        const time = self.now();
        return .{ .cfg = self.cfg, .state = self.state, .now = time, .local = clock.localAt(time) catch null, .per_output = self.perOutput() };
    }
    fn scheduleWindow(self: *Engine) !?scheduling.Window {
        return self.policyContext().scheduleWindow();
    }
    pub fn rememberManualChoice(self: *Engine, action: Action) !void {
        if (!self.dirty) return;
        switch (action) {
            .use, .set, .next, .previous, .select, .random_favorite, .restore => {},
            else => return,
        }
        // A manual change overrides the schedule of each output it changed
        // until that schedule's next change: the global [schedule] for
        // outputs following the active collection, or the output's own
        // [schedule.NAME].
        var global = !self.assignments() or action == .use or self.changed_outputs.len == 0;
        for (self.changed_outputs) |output| {
            const rule = self.cfg.outputRule(output) orelse {
                global = true;
                continue;
            };
            if (rule.schedule.len == 0) continue;
            const window = (try self.namedWindow(rule.schedule)) orelse continue;
            const previous = self.state.scheduleCursor(rule.schedule);
            const cursor = scheduling.manualOverride(window, if (previous) |known| known.cursor else null);
            try self.state.setScheduleCursor(self.a, .{ .name = rule.schedule, .cursor = cursor, .collection = window.current.collection });
        }
        if (global) if (try self.scheduleWindow()) |window| {
            self.state.schedule_cursor = scheduling.manualOverride(window, self.state.schedule_cursor);
        };
    }
    fn resumeGlobal(self: *Engine) !void {
        // Use a clean engine so dirty from this control change does not
        // disguise a failed wallpaper application.
        var scheduled = self.*;
        scheduled.state.schedule_cursor = null;
        _ = scheduled.applySchedule() catch |err| {
            if (scheduled.dirty) {
                self.* = scheduled;
            } else {
                self.message = scheduled.message;
            }
            return err;
        };
        self.* = scheduled;
        // Releasing a manual override persists even when held.
        self.dirty = true;
    }
    // `schedule resume --output NAME`: that monitor's own schedule, or the
    // global schedule for a monitor following the active collection.
    fn resumeOutput(self: *Engine, output: []const u8) !void {
        const connected = try self.current();
        _ = try self.targets(connected, output, false);
        const rule = (if (self.assignments()) self.cfg.outputRule(output) else null) orelse {
            if (self.cfg.schedule.len == 0) return error.NoScheduleConfigured;
            try self.resumeGlobal();
            return self.print("{s} follows the global schedule again (holds still apply)\n", .{output});
        };
        if (rule.schedule.len == 0) return u.fail(self.a, "output {s} has a fixed collection ({s}), not a schedule", .{ output, rule.collection });
        try self.switchScheduled(rule.schedule, (try self.namedWindow(rule.schedule)).?, connected, output);
        try self.print("{s} follows schedule {s} again (holds still apply)\n", .{ output, rule.schedule });
    }
    fn namedWindow(self: *Engine, name: []const u8) !?scheduling.Window {
        return self.policyContext().namedWindow(name);
    }
    fn ackSchedule(self: *Engine, name: []const u8, window: scheduling.Window, manual: bool) !void {
        try self.state.setScheduleCursor(self.a, .{ .name = name, .cursor = scheduling.acknowledge(window, manual), .collection = window.current.collection });
        self.dirty = true;
    }
    // Per-monitor schedules: at each scheduled time, switch the monitors that
    // follow a [schedule.NAME] to its new collection. The first check of a
    // schedule only records it (reload switches reassigned monitors), and a
    // period with the same collection changes nothing.
    pub fn applyOutputSchedules(self: *Engine) !void {
        if (!self.assignments() or self.cfg.schedules.len == 0) return;
        if (self.state.held("*", self.now())) return;
        var connected: ?[]const Assignment = null;
        for (self.cfg.schedules) |schedule| {
            const window = (try self.namedWindow(schedule.name)).?;
            switch (self.policyContext().namedDecision(schedule.name, window)) {
                .wait => continue,
                .acknowledge => {
                    try self.ackSchedule(schedule.name, window, false);
                    continue;
                },
                .change => {},
            }
            if (connected == null) connected = try self.current();
            try self.switchScheduled(schedule.name, window, connected.?, null);
        }
    }
    // Rotate a schedule's connected monitors (or just `only`) to its current
    // collection and record the period. Held monitors keep their image and
    // leave the switch pending; with no monitor connected there is nothing to
    // change, since a monitor that connects later picks from the current
    // collection anyway.
    fn switchScheduled(self: *Engine, name: []const u8, window: scheduling.Window, connected: []const Assignment, only: ?[]const u8) !void {
        const plan = try self.policyContext().scheduleTargets(self.a, name, connected, only);
        if (!plan.found) return self.ackSchedule(name, window, false);
        if (plan.outputs.len == 0) return;
        const filter = try std.mem.join(self.a, ",", plan.outputs);
        const was_dirty = self.dirty;
        self.dirty = false;
        defer self.dirty = self.dirty or was_dirty;
        try self.rotateAssigned(true, filter, false);
        if (!self.dirty) return;
        try self.ackSchedule(name, window, false);
        try self.print("schedule {s}: {d:0>2}:{d:0>2} -> {s} ({s})\n", .{ name, window.current.minute / 60, window.current.minute % 60, window.current.collection, filter });
    }
    // Returns true while a schedule change takes precedence over interval
    // rotation (including a deferred change while all target outputs are held).
    pub fn applySchedule(self: *Engine) !bool {
        const window = (try self.scheduleWindow()) orelse return false;
        const context = self.policyContext();
        // Avoid a backend query when no schedule work is due or a global
        // hold blocks it. Connectivity is an input to the policy decision.
        switch (context.globalDecision(window, true)) {
            .wait => return false,
            .held => return true,
            else => {},
        }
        const decision = context.globalDecision(window, try self.hasUnassignedOutput());
        const before = self.state;
        if (decision == .record) {
            self.state.collection = window.current.collection;
        } else if (decision == .rotate) {
            self.state.collection = window.current.collection;
            self.rotateActive(true) catch |err| {
                if (!self.dirty) {
                    self.state = before;
                } else {
                    self.state.schedule_cursor = scheduling.acknowledge(window, false);
                }
                return err;
            };
            if (!self.dirty) {
                self.state = before;
                return true;
            }
        }
        self.state.schedule_cursor = scheduling.acknowledge(window, false);
        self.dirty = true;
        try self.print("schedule: {d:0>2}:{d:0>2} -> {s}\n", .{ window.current.minute / 60, window.current.minute % 60, window.current.collection });
        return true;
    }
    const ScheduleInfo = policy.ScheduleInfo;
    fn scheduleInfo(self: *Engine) !ScheduleInfo {
        return self.policyContext().scheduleInfo();
    }
    fn namedScheduleInfo(self: *Engine, schedule: config.NamedSchedule) !ScheduleInfo {
        return self.policyContext().namedScheduleInfo(schedule);
    }
    fn scheduleOutputs(self: *Engine, name: []const u8) ![]const []const u8 {
        var outputs: std.ArrayList([]const u8) = .empty;
        for (self.cfg.outputs) |rule| if (u.eql(rule.schedule, name)) {
            try outputs.append(self.a, rule.output);
        };
        return outputs.toOwnedSlice(self.a);
    }
    fn showSchedule(self: *Engine, json: bool) !void {
        const info = try self.scheduleInfo();
        if (json) {
            const Named = struct { name: []const u8, outputs: []const []const u8, rules: []const scheduling.Rule, status: ScheduleInfo };
            var named: std.ArrayList(Named) = .empty;
            for (self.cfg.schedules) |schedule| try named.append(self.a, .{ .name = schedule.name, .outputs = try self.scheduleOutputs(schedule.name), .rules = schedule.rules, .status = try self.namedScheduleInfo(schedule) });
            try self.print("{s}\n", .{try std.json.Stringify.valueAlloc(self.a, .{ .status = info, .rules = self.cfg.schedule, .schedules = named.items }, .{})});
            return;
        }
        if (!info.enabled) {
            try self.print("schedule: not configured\n", .{});
        } else {
            try self.print("schedule: local time{s}{s}\n", .{ if (info.manual_override) "; manual choice until next scheduled change" else "", if (info.held) "; held" else "" });
            try self.printTimetable(self.cfg.schedule, info);
        }
        for (self.cfg.schedules) |schedule| {
            const named = try self.namedScheduleInfo(schedule);
            const outputs = try self.scheduleOutputs(schedule.name);
            try self.print("schedule {s} ({s}): local time{s}{s}\n", .{ schedule.name, if (outputs.len == 0) "no outputs" else try std.mem.join(self.a, ", ", outputs), if (named.manual_override) "; manual choice until next scheduled change" else "", if (named.held) "; held" else "" });
            try self.printTimetable(schedule.rules, named);
        }
    }
    fn printTimetable(self: *Engine, rules: []const scheduling.Rule, info: ScheduleInfo) !void {
        for (rules) |rule| try self.print("  {d:0>2}:{d:0>2} -> {s}\n", .{ rule.minute / 60, rule.minute % 60, rule.collection });
        const next = info.next.?;
        const local = try clock.localAt(self.now());
        try self.print("  current period: {s}{s}; next: {d:0>2}:{d:0>2} {s} -> {s}\n", .{ info.current.?.collection, if (info.pending) " (pending)" else "", next.minute / 60, next.minute % 60, if (next.day == local.day) "today" else if (next.day == local.day + 1) "tomorrow" else try std.fmt.allocPrint(self.a, "in {d} days", .{next.day - local.day}), next.collection });
    }
    pub fn print(self: *Engine, comptime fmt: []const u8, args: anytype) !void {
        try self.message.appendSlice(self.a, try std.fmt.allocPrint(self.a, fmt, args));
    }
    fn collectionName(self: *Engine) []const u8 {
        return self.cfg.selectedName(self.state.collection);
    }
    // Per-monitor assignments only apply where outputs can be targeted.
    fn assignments(self: *Engine) bool {
        return self.cfg.outputs.len > 0 and self.perOutput();
    }
    // Why [output.NAME] sections cannot apply right now, or null if they can.
    // [output.NAME] assignments with the collection each uses now.
    const OutputCollection = struct { output: []const u8, collection: []const u8, schedule: ?[]const u8 = null };
    fn outputCollections(self: *Engine) ![]const OutputCollection {
        if (!self.assignments()) return &.{};
        var list: std.ArrayList(OutputCollection) = .empty;
        for (self.cfg.outputs) |rule| try list.append(self.a, .{ .output = rule.output, .collection = self.assignedCollection(rule.output) orelse "", .schedule = if (rule.schedule.len > 0) rule.schedule else null });
        return list.toOwnedSlice(self.a);
    }
    fn assignmentLabel(self: *Engine, output: []const u8) ![]const u8 {
        if (!self.assigned(output)) return "";
        const rule = self.cfg.outputRule(output).?;
        if (rule.schedule.len > 0) return std.fmt.allocPrint(self.a, " [schedule {s}: {s}]", .{ rule.schedule, self.collectionFor(output) });
        return std.fmt.allocPrint(self.a, " [collection {s}]", .{self.collectionFor(output)});
    }
    pub fn outputsIgnored(self: *Engine) ?[]const u8 {
        if (self.cfg.outputs.len == 0 or self.be().queryable() or self.fehMonitors() != null) return null;
        const prefix = "note: [output.NAME] sections are ignored; ";
        if (self.be().kind != .feh) return prefix ++ "a custom setter sets one wallpaper for every output";
        if (!backend.available(self.rt, self.a, "xrandr")) return prefix ++ "feh needs xrandr (xorg-xrandr) to set each monitor";
        return prefix ++ "xrandr could not list monitors (no X display?), so feh sets one wallpaper for every output";
    }
    // Whether outputs can be targeted one by one: awww/swww, or feh with
    // xrandr to name the X11 monitors. This runs every daemon tick, so it only
    // looks xrandr up in PATH; without a display, feh still falls back to one
    // wallpaper when the monitor list is needed.
    fn perOutput(self: *Engine) bool {
        const b = self.be();
        return b.queryable() or (b.kind == .feh and backend.available(self.rt, self.a, "xrandr"));
    }
    // X11 monitor names in Xinerama order, which is the order feh assigns
    // several images in, or null when feh cannot target monitors.
    fn fehMonitors(self: *Engine) ?[]const []const u8 {
        if (self.be().kind != .feh) return null;
        if (!self.x11_checked) {
            self.x11_checked = true;
            const text = u.run(self.rt, self.a, &.{ "xrandr", "--listmonitors" }, self.cfg.timeout) catch {
                u.diagnostic = "";
                return null;
            };
            const lines = parseMonitors(self.a, text) catch return null;
            self.setMonitors(lines) catch return null;
        }
        return self.x11_monitors;
    }
    fn setMonitors(self: *Engine, lines: []const []const u8) !void {
        self.x11_checked = true;
        self.x11_monitors = null;
        if (lines.len == 0) return;
        const names = try self.a.alloc([]const u8, lines.len);
        for (lines, names) |line, *name| name.* = monitorName(line);
        self.x11_monitors = names;
    }
    // The collection an [output.NAME] section gives a monitor: its fixed
    // collection, or what its [schedule.NAME] selects right now.
    fn assignedCollection(self: *Engine, output: []const u8) ?[]const u8 {
        return self.policyContext().assignedCollection(output);
    }
    fn assigned(self: *Engine, output: []const u8) bool {
        return self.policyContext().assigned(output);
    }
    fn collectionFor(self: *Engine, output: []const u8) []const u8 {
        return self.policyContext().collectionFor(output);
    }
    fn settings(self: *Engine) !config.Config {
        return self.cfg.effective(self.collectionName()) catch return u.fail(self.a, "collection '{s}' is not defined; select one with 'zpaper use NAME'", .{self.collectionName()});
    }
    fn be(self: *Engine) backend.Backend {
        return backend.Backend.init(self.rt, self.a, self.cfg);
    }
    fn current(self: *Engine) ![]const Assignment {
        const b = self.be();
        if (b.queryable()) return b.query();
        // feh cannot report what it shows; use what zpaper recorded for each
        // X11 monitor, or the single image of an older global layout.
        if (self.fehMonitors()) |names| {
            var shared: []const u8 = "";
            for (self.state.current) |entry| if (u.eql(entry.output, "*")) {
                shared = entry.image;
            };
            const outputs = try self.a.alloc(Assignment, names.len);
            for (names, outputs) |name, *out| {
                out.* = .{ .output = name, .image = shared };
                for (self.state.current) |entry| if (u.eql(entry.output, name)) {
                    out.image = entry.image;
                };
            }
            // Sorted by name like the Wayland query, so `set a b` maps images
            // the same way in both sessions. feh itself still gets them in
            // Xinerama order (see apply).
            std.mem.sort(Assignment, outputs, {}, struct {
                fn lessThan(_: void, x: Assignment, y: Assignment) bool {
                    return std.mem.lessThan(u8, x.output, y.output);
                }
            }.lessThan);
            return outputs;
        }
        // A global-only backend cannot assert an old Wayland output mapping.
        for (self.state.current) |entry| if (u.eql(entry.output, "*")) return self.a.dupe(Assignment, &.{entry});
        return &.{};
    }
    fn resetTimer(self: *Engine) !void {
        const cfg = try self.settings();
        self.state.next_due = if (cfg.interval == 0) 0 else self.now() + @as(i64, @intCast(cfg.interval));
        self.dirty = true;
    }
    // A restore at daemon startup, after time away, gives the restored images
    // a full interval instead of an immediate rotation. Running timers, as
    // during a refresh, are left alone.
    fn restartOverdueTimers(self: *Engine) !void {
        const time = self.now();
        if (self.state.next_due != 0 and self.state.next_due <= time) try self.resetTimer();
        for (self.state.collection_due) |entry| if (entry.due != 0 and entry.due <= time) {
            try self.resetCollectionTimer(entry.name);
        };
    }
    fn resetCollectionTimer(self: *Engine, name: []const u8) !void {
        const cfg = self.cfg.effective(name) catch return;
        try self.state.setDue(self.a, name, if (cfg.interval == 0) 0 else self.now() + @as(i64, @intCast(cfg.interval)));
        self.dirty = true;
    }
    // A change restarts the timer of each collection whose outputs changed:
    // the active collection's for unassigned outputs, and each assigned one.
    fn resetTimers(self: *Engine, changed: []const []const u8) !void {
        var active = !self.assignments();
        for (changed) |output| {
            if (self.assigned(output)) {
                try self.resetCollectionTimer(self.collectionFor(output));
            } else active = true;
        }
        if (active) try self.resetTimer();
    }
    fn outputSelected(output: []const u8, filter: ?[]const u8) bool {
        const value = filter orelse return true;
        var names = std.mem.splitScalar(u8, value, ',');
        while (names.next()) |name| if (u.eql(name, output)) return true;
        return false;
    }
    fn targets(self: *Engine, current_outputs: []const Assignment, filter: ?[]const u8, automatic: bool) ![]const []const u8 {
        var outputs: std.ArrayList([]const u8) = .empty;
        if (filter) |value| {
            var names = std.mem.splitScalar(u8, value, ',');
            while (names.next()) |name| {
                if (name.len == 0 or u.contains(outputs.items, name)) return error.InvalidOutput;
                var found = false;
                for (current_outputs) |entry| if (u.eql(entry.output, name)) {
                    found = true;
                    break;
                };
                if (!found) return u.fail(self.a, "output is not connected: {s}", .{name});
                try outputs.append(self.a, name);
            }
        } else if (self.be().queryable() or self.fehMonitors() != null) {
            for (current_outputs) |entry| try outputs.append(self.a, entry.output);
        } else {
            try outputs.append(self.a, "*");
        }
        if (automatic) {
            var free: std.ArrayList([]const u8) = .empty;
            for (outputs.items) |name| if (!self.state.held(name, self.now())) {
                try free.append(self.a, name);
            };
            return free.toOwnedSlice(self.a);
        }
        return outputs.toOwnedSlice(self.a);
    }
    // Apply individually and commit only successful assignments. We cannot make
    // multiple backend invocations atomic; the caller gets an explicit failure.
    // Apply desired images. A restore reapplies what is already recorded, so
    // it is not a new choice: history, seen lists, running timers, the hook
    // and notifications are left alone.
    fn apply(self: *Engine, before: []const Assignment, desired: []const Assignment, navigation: ?usize, restoring: bool) !void {
        _ = try self.settings();
        var after = try self.a.dupe(Assignment, before);
        var successes: usize = 0;
        var failures: usize = 0;
        var changed: std.ArrayList([]const u8) = .empty;
        const b = self.be();
        const x11 = self.fehMonitors();
        if (x11) |names| {
            // feh sets every monitor at once, so compose the whole screen:
            // desired images, then what each monitor shows, then its last
            // recorded image. A failed call changes nothing.
            var fallback: []const u8 = "";
            for (desired) |entry| if (entry.image.len > 0 and u.exists(self.rt, entry.image)) {
                fallback = entry.image;
                break;
            };
            if (fallback.len == 0) fallback = for (before) |entry| {
                if (entry.image.len > 0 and u.exists(self.rt, entry.image)) break entry.image;
            } else "";
            const images = try self.a.alloc([]const u8, names.len);
            for (names, images) |name, *image| {
                image.* = "";
                for (before) |old| if (u.eql(old.output, name) and old.image.len > 0 and u.exists(self.rt, old.image)) {
                    image.* = old.image;
                };
                for (desired) |entry| if (u.eql(entry.output, name) and entry.image.len > 0 and u.exists(self.rt, entry.image)) {
                    image.* = entry.image;
                };
                if (image.len == 0) image.* = self.lastImage(name) orelse fallback;
                if (image.len == 0) return error.NoImagesFound;
            }
            b.applyMonitors(images) catch |err| {
                try self.print("failed: {s}\n", .{if (u.diagnostic.len > 0) u.diagnostic else @errorName(err)});
                u.diagnostic = "";
                return error.LayoutIncomplete;
            };
            // Record images filled in for monitors that had none.
            for (names, images) |name, image| for (after) |*old| if (u.eql(old.output, name) and old.image.len == 0) {
                old.image = image;
            };
        }
        for (desired) |entry| {
            var index: ?usize = null;
            for (after, 0..) |old, i| if (u.eql(old.output, entry.output)) {
                index = i;
                break;
            };
            if (entry.image.len == 0 or ((b.queryable() or x11 != null) and index == null)) {
                failures += 1;
                try self.print("skipped {s}: {s}\n", .{ entry.output, if (entry.image.len == 0) "saved output has no image" else "output is disconnected" });
                continue;
            }
            if (x11 != null) {
                // Already applied above; a missing file was left out.
                if (!u.exists(self.rt, entry.image)) {
                    failures += 1;
                    try self.print("failed {s}: image is missing or not a regular file: {s}\n", .{ entry.output, entry.image });
                    continue;
                }
            } else b.apply(entry.image, entry.output) catch |err| {
                failures += 1;
                try self.print("failed {s}: {s}\n", .{ entry.output, if (u.diagnostic.len > 0) u.diagnostic else @errorName(err) });
                u.diagnostic = "";
                continue;
            };
            successes += 1;
            try changed.append(self.a, entry.output);
            if (index) |i| {
                after[i] = entry;
            } else {
                after = try self.a.dupe(Assignment, try u.append(Assignment, self.a, after, entry));
            }
            try self.print("{s}: {s}\n", .{ entry.output, entry.image });
            if (restoring) continue;
            const timestamp = try std.fmt.allocPrint(self.a, "{d}", .{self.now()});
            try self.state.addImage(self.a, entry.image, timestamp);
            try self.state.markSeen(self.a, self.collectionFor(entry.output), entry.image);
        }
        if (successes > 0 and restoring) {
            self.wallpaper_applied = true;
            if (!state_mod.same(self.state.current, after)) {
                self.state.current = after;
                self.dirty = true;
            }
            try self.restartOverdueTimers();
        } else if (successes > 0) {
            self.wallpaper_applied = true;
            self.state.collection = self.collectionName();
            if (navigation != null and failures == 0 and state_mod.same(after, try self.fit(self.state.layouts[navigation.?].outputs, before))) {
                self.state.cursor = navigation.?;
                self.state.current = after;
            } else {
                if (before.len > 0) try self.state.record(self.rt, self.a, before);
                try self.state.record(self.rt, self.a, after);
            }
            try self.resetTimers(changed.items);
            self.changed_outputs = changed.items;
            for (desired) |entry| if (outputChanged(after, entry)) {
                self.runHook(entry.output, entry.image);
                break;
            };
            if (self.cfg.notify) {
                _ = u.run(self.rt, self.a, &.{ "notify-send", "zpaper", "Wallpaper updated" }, 3) catch {};
                u.diagnostic = "";
            }
        }
        if (failures > 0) return error.LayoutIncomplete;
    }
    fn outputChanged(after: []const Assignment, entry: Assignment) bool {
        for (after) |applied| if (u.eql(applied.output, entry.output)) return u.eql(applied.image, entry.image);
        return false;
    }
    // Run the on_change hook once per wallpaper change, detached through
    // setsid so a slow theme generator never blocks the daemon. %s is the
    // image and %o the output ("*" for global backends); without %s the image
    // is appended. Output and errors go to the hook log, never to the caller.
    fn runHook(self: *Engine, output: []const u8, image: []const u8) void {
        if (self.cfg.on_change.len == 0) return;
        self.spawnHook(output, image) catch |err| {
            self.print("on_change: {s}\n", .{if (u.diagnostic.len > 0) u.diagnostic else @errorName(err)}) catch {};
        };
        u.diagnostic = "";
    }
    fn spawnHook(self: *Engine, output: []const u8, image: []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.a, &.{ "setsid", "-f" });
        var replaced = false;
        for (self.cfg.on_change) |arg| {
            if (std.mem.indexOf(u8, arg, "%s") != null) replaced = true;
            try argv.append(self.a, try expandHook(self.a, arg, image, output));
        }
        if (!replaced) try argv.append(self.a, image);
        const data_dir = try u.absolute(self.rt, self.a, try config.getDataDir(self.rt, self.a));
        try std.Io.Dir.cwd().createDirPath(self.rt.io, data_dir);
        const log_path = try std.fmt.allocPrint(self.a, "{s}/on_change.log", .{data_dir});
        try u.runLogged(self.rt, self.a, argv.items, self.cfg.timeout, log_path);
    }
    fn prepare(self: *Engine) ![]const Assignment {
        try self.be().ready();
        return self.current();
    }
    fn setImages(self: *Engine, paths: []const []const u8, filter: ?[]const u8, automatic: bool) !void {
        if (paths.len == 0) return error.NoImagesFound;
        for (paths) |path| if (!u.exists(self.rt, path)) return u.fail(self.a, "image is missing or not a regular file: {s}", .{path});
        const before = try self.prepare();
        const outputs = try self.targets(before, filter, automatic);
        if (outputs.len == 0) return;
        const desired = try policy.planImages(self.a, outputs, paths);
        try self.apply(before, desired, null, false);
    }
    pub fn rotate(self: *Engine, automatic: bool, filter: ?[]const u8) !void {
        if (automatic and self.state.held("*", self.now())) return;
        if (self.assignments()) return self.rotateAssigned(automatic, filter, false);
        const cfg = try self.settings();
        if (cfg.wallpaper) |path| return self.setImages(&.{path}, filter, automatic);
        const dir = cfg.dir orelse return error.NoDirectoryConfigured;
        const paths = try picker.collect(self.rt, self.a, dir, cfg.recursive);
        const before = self.state;
        const chosen = try self.state.choose(self.rt, self.a, self.collectionName(), paths);
        // A failed setter must not consume a shuffle entry or reset a cycle.
        self.setImages(&.{chosen}, filter, automatic) catch |err| {
            if (!self.dirty) self.state = before;
            return err;
        };
    }
    // Most recent existing image recorded for an output: the current layout
    // first, then the layout timeline from newest to oldest. This lets a
    // monitor that was unplugged during rotation get its own image back.
    fn lastImage(self: *Engine, output: []const u8) ?[]const u8 {
        // A global backend's "*" can use an image recorded for any output.
        const any = !self.be().queryable() and u.eql(output, "*");
        for (self.state.current) |entry| if ((any or u.eql(entry.output, output)) and entry.image.len > 0 and u.exists(self.rt, entry.image)) return entry.image;
        var i = self.state.layouts.len;
        while (i > 0) {
            i -= 1;
            for (self.state.layouts[i].outputs) |entry| if ((any or u.eql(entry.output, output)) and entry.image.len > 0 and u.exists(self.rt, entry.image)) return entry.image;
        }
        return null;
    }
    // After a reload, connected outputs whose collection changed (a section
    // added, changed, or removed) get an image from their new collection now
    // instead of at the next rotation. Held outputs keep theirs.
    pub fn reassign(self: *Engine, previous: config.Config) !void {
        if (!self.perOutput()) return;
        var old = self.*;
        old.cfg = previous;
        var names: std.ArrayList([]const u8) = .empty;
        for (try self.current()) |entry| {
            if (u.eql(self.collectionFor(entry.output), old.collectionFor(entry.output))) continue;
            if (self.state.held(entry.output, self.now())) continue;
            try names.append(self.a, entry.output);
        }
        if (names.items.len == 0) return;
        try self.rotate(false, try std.mem.join(self.a, ",", names.items));
        // Reassigned monitors are on their schedules' current collections.
        for (names.items) |output| if (self.cfg.outputRule(output)) |rule| if (rule.schedule.len > 0) {
            if (try self.namedWindow(rule.schedule)) |window| try self.ackSchedule(rule.schedule, window, false);
        };
    }
    // A layout for these monitor names. Entries for connected monitors are
    // kept, and an old global "*" image covers every monitor. A layout from
    // another session, naming none of these monitors (X11 and Wayland call
    // them differently), gives each monitor its last image recorded under its
    // own name, so switching sessions brings back that session's layout.
    fn fitMonitors(self: *Engine, layout: []const Assignment, names: []const []const u8) ![]const Assignment {
        var matched = false;
        var shared: ?[]const u8 = null;
        var first: ?[]const u8 = null;
        for (layout) |entry| {
            if (u.contains(names, entry.output)) matched = true;
            if (u.eql(entry.output, "*")) shared = entry.image;
            if (first == null and entry.image.len > 0 and u.exists(self.rt, entry.image)) first = entry.image;
        }
        var fitted: std.ArrayList(Assignment) = .empty;
        for (names) |name| {
            var image: ?[]const u8 = null;
            for (layout) |entry| if (u.eql(entry.output, name)) {
                image = entry.image;
            };
            if (image == null) image = shared;
            if (image == null and !matched) image = self.lastImage(name) orelse first;
            if (image) |path| try fitted.append(self.a, .{ .output = name, .image = path });
        }
        return fitted.toOwnedSlice(self.a);
    }
    // A recorded layout made applicable to the current backend. Global
    // backends (feh, custom) set one wallpaper, so a per-output layout from a
    // Wayland session becomes its first existing image on "*". Per-output
    // backends already apply "*" to every output.
    // `connected` is the renderer's current layout (from prepare()).
    fn fit(self: *Engine, layout: []const Assignment, connected: []const Assignment) ![]const Assignment {
        if (self.be().queryable()) {
            // awww/swww apply "*" to every output, and a layout naming any
            // connected output is applied as recorded (reporting the rest as
            // disconnected). Only a layout from another session, naming none
            // of these outputs, is mapped by name.
            const names = try self.a.alloc([]const u8, connected.len);
            for (connected, names) |entry, *name| name.* = entry.output;
            for (layout) |entry| if (u.eql(entry.output, "*") or u.contains(names, entry.output)) return layout;
            return self.fitMonitors(layout, names);
        }
        if (self.fehMonitors()) |names| return self.fitMonitors(layout, names);
        for (layout) |entry| if (u.eql(entry.output, "*")) return self.a.dupe(Assignment, &.{entry});
        var image: []const u8 = if (layout.len > 0) layout[0].image else return layout;
        for (layout) |entry| if (entry.image.len > 0 and u.exists(self.rt, entry.image)) {
            image = entry.image;
            break;
        };
        return self.a.dupe(Assignment, &.{.{ .output = "*", .image = image }});
    }
    // Hotplug and renderer-restart recovery for queryable backends. Outputs
    // that appeared since `previous` (null on the first check) or that show no
    // image get their last recorded image back, or a fresh pick if they never
    // had one. Outputs showing an image are left alone, so changes made
    // outside zpaper are not reverted. Restoring is not a new choice: it does
    // not touch history, shuffle progress, holds, or the rotation timer.
    // Returns the connected output names for the next comparison.
    pub fn reconcile(self: *Engine, previous: ?[]const []const u8) ![]const []const u8 {
        const b = self.be();
        if (b.kind == .feh) return self.reconcileX11(previous);
        if (!b.queryable()) return error.QueryUnsupported;
        const actual = b.query() catch blk: {
            // The renderer may have crashed; ready() restarts it if allowed.
            try b.ready();
            break :blk try b.query();
        };
        var names: std.ArrayList([]const u8) = .empty;
        var recorded = try self.a.dupe(Assignment, self.state.current);
        var new_layout = false;
        var fresh_image: []const u8 = "";
        var changed = false;
        for (actual) |entry| {
            try names.append(self.a, entry.output);
            const appeared = if (previous) |p| !u.contains(p, entry.output) else false;
            if (!appeared and entry.image.len > 0) continue;
            const known = self.lastImage(entry.output);
            const image = known orelse self.pickFrom(self.collectionFor(entry.output)) catch |err| {
                try self.print("new output {s}: {s}\n", .{ entry.output, if (u.diagnostic.len > 0) u.diagnostic else @errorName(err) });
                u.diagnostic = "";
                continue;
            };
            if (u.eql(entry.image, image)) continue;
            b.apply(image, entry.output) catch |err| {
                try self.print("restore {s} failed: {s}\n", .{ entry.output, if (u.diagnostic.len > 0) u.diagnostic else @errorName(err) });
                u.diagnostic = "";
                continue;
            };
            if (known == null) {
                // A fresh pick for a never-seen output is a real new image.
                new_layout = true;
                if (fresh_image.len == 0) fresh_image = image;
                try self.state.addImage(self.a, image, try std.fmt.allocPrint(self.a, "{d}", .{self.now()}));
                try self.state.markSeen(self.a, self.collectionFor(entry.output), image);
                try self.print("new output {s}: {s}\n", .{ entry.output, image });
            } else try self.print("restored {s}: {s}\n", .{ entry.output, image });
            var found = false;
            for (recorded) |*saved| if (u.eql(saved.output, entry.output)) {
                saved.image = image;
                found = true;
            };
            if (!found) recorded = try self.a.dupe(Assignment, try u.append(Assignment, self.a, recorded, .{ .output = entry.output, .image = image }));
            changed = true;
        }
        if (new_layout) {
            try self.state.record(self.rt, self.a, recorded);
            for (recorded) |entry| if (u.eql(entry.image, fresh_image)) {
                self.runHook(entry.output, entry.image);
                break;
            };
        } else if (changed) {
            self.state.current = recorded;
        }
        if (changed) self.dirty = true;
        return names.toOwnedSlice(self.a);
    }
    // feh cannot report what it shows, so watch the X11 monitor layout instead.
    // When monitors are added, removed, resized or moved, rerun feh so the
    // background covers the new screen: each monitor gets its last recorded
    // image, and a monitor zpaper has never seen gets a fresh pick from its
    // collection (a new layout, like on Wayland). Without xrandr this check is
    // unsupported and the daemon skips it.
    fn reconcileX11(self: *Engine, previous: ?[]const []const u8) ![]const []const u8 {
        const text = u.run(self.rt, self.a, &.{ "xrandr", "--listmonitors" }, self.cfg.timeout) catch {
            u.diagnostic = "";
            return error.QueryUnsupported;
        };
        const lines = try parseMonitors(self.a, text);
        const old = previous orelse return lines;
        var same_layout = old.len == lines.len;
        if (same_layout) for (lines) |m| if (!u.contains(old, m)) {
            same_layout = false;
            break;
        };
        if (same_layout) return lines;
        try self.setMonitors(lines);
        const names = self.x11_monitors orelse return lines;
        var shared: ?[]const u8 = null;
        for (self.state.current) |entry| if (u.eql(entry.output, "*") and entry.image.len > 0 and u.exists(self.rt, entry.image)) {
            shared = entry.image;
        };
        const images = try self.a.alloc([]const u8, names.len);
        var fresh: ?[]const u8 = null;
        var fresh_output: []const u8 = "";
        for (names, images) |name, *image| {
            image.* = self.lastImage(name) orelse shared orelse "";
            if (image.len > 0) continue;
            image.* = self.pickFrom(self.collectionFor(name)) catch |err| {
                try self.print("new output {s}: {s}\n", .{ name, if (u.diagnostic.len > 0) u.diagnostic else @errorName(err) });
                u.diagnostic = "";
                continue;
            };
            try self.state.addImage(self.a, image.*, try std.fmt.allocPrint(self.a, "{d}", .{self.now()}));
            try self.state.markSeen(self.a, self.collectionFor(name), image.*);
            try self.print("new output {s}: {s}\n", .{ name, image.* });
            if (fresh == null) {
                fresh = image.*;
                fresh_output = name;
            }
        }
        // A monitor whose pick failed shows another monitor's image.
        const fallback = for (images) |image| {
            if (image.len > 0) break image;
        } else return lines;
        for (images) |*image| if (image.len == 0) {
            image.* = fallback;
        };
        self.be().applyMonitors(images) catch |err| {
            try self.print("restore failed: {s}\n", .{if (u.diagnostic.len > 0) u.diagnostic else @errorName(err)});
            u.diagnostic = "";
            return lines;
        };
        try self.print("monitor layout changed; restored {d} monitor(s)\n", .{names.len});
        // Keep entries for disconnected monitors so they come back later.
        var recorded: std.ArrayList(Assignment) = .empty;
        for (names, images) |name, image| try recorded.append(self.a, .{ .output = name, .image = image });
        for (self.state.current) |entry| if (!u.eql(entry.output, "*") and !u.contains(names, entry.output)) {
            try recorded.append(self.a, entry);
        };
        if (fresh) |image| {
            try self.state.record(self.rt, self.a, recorded.items);
            self.runHook(fresh_output, image);
            self.dirty = true;
        } else if (!state_mod.same(self.state.current, recorded.items)) {
            self.state.current = recorded.items;
            self.dirty = true;
        }
        return lines;
    }
    fn pickFrom(self: *Engine, name: []const u8) ![]const u8 {
        const cfg = self.cfg.effective(name) catch return u.fail(self.a, "collection '{s}' is not defined; select one with 'zpaper use NAME'", .{name});
        if (cfg.wallpaper) |path| return path;
        const dir = cfg.dir orelse return error.NoDirectoryConfigured;
        return self.state.choose(self.rt, self.a, name, try picker.collect(self.rt, self.a, dir, cfg.recursive));
    }
    // Rotate only the outputs that follow the active collection; used by `use`
    // and the schedule so assigned monitors keep their own collections.
    pub fn rotateActive(self: *Engine, automatic: bool) !void {
        if (automatic and self.state.held("*", self.now())) return;
        if (self.assignments()) return self.rotateAssigned(automatic, null, true);
        return self.rotate(automatic, null);
    }
    // Interval rotation for collections assigned to outputs. Each collection
    // has its own deadline and rotates only its connected, unheld outputs.
    // Returns true when a due collection could not change anything (held or
    // failed), so the daemon can back off instead of re-checking every tick.
    pub fn rotateDue(self: *Engine) !bool {
        if (!self.assignments() or self.state.held("*", self.now())) return false;
        var stalled = false;
        var connected: ?[]const Assignment = null;
        // Each assigned collection once, including those schedules select now.
        var names: std.ArrayList([]const u8) = .empty;
        for (self.cfg.outputs) |rule| if (self.assignedCollection(rule.output)) |name| if (!u.contains(names.items, name)) {
            try names.append(self.a, name);
        };
        for (names.items) |name| {
            const cfg = self.cfg.effective(name) catch continue;
            if (cfg.interval == 0) continue;
            const due = self.state.dueFor(name) orelse {
                try self.resetCollectionTimer(name);
                continue;
            };
            if (self.now() < due) continue;
            if (connected == null) connected = try self.current();
            var filter: std.ArrayList(u8) = .empty;
            for (connected.?) |entry| if (self.assignedCollection(entry.output)) |assigned_name| if (u.eql(assigned_name, name)) {
                if (filter.items.len > 0) try filter.append(self.a, ',');
                try filter.appendSlice(self.a, entry.output);
            };
            if (filter.items.len == 0) {
                try self.resetCollectionTimer(name);
                continue;
            }
            const was_dirty = self.dirty;
            self.dirty = false;
            self.rotateAssigned(true, filter.items, false) catch |err| {
                try self.print("rotation {s}: {s}\n", .{ name, if (u.diagnostic.len > 0) u.diagnostic else @errorName(err) });
                u.diagnostic = "";
            };
            if (!self.dirty) stalled = true;
            self.dirty = self.dirty or was_dirty;
        }
        return stalled;
    }
    // True when some connected output follows the active collection.
    fn hasUnassignedOutput(self: *Engine) !bool {
        if (!self.assignments()) return true;
        for (try self.current()) |entry| if (!self.assigned(entry.output)) return true;
        return false;
    }
    // Each collection picks one image per rotation, shared by the outputs that
    // draw from it (matching the single-image behaviour without assignments).
    fn rotateAssigned(self: *Engine, automatic: bool, filter: ?[]const u8, active_only: bool) !void {
        const before_state = self.state;
        errdefer if (!self.dirty) {
            self.state = before_state;
        };
        _ = try self.settings();
        const before = try self.prepare();
        const outputs = try self.targets(before, filter, automatic);
        const Pick = struct { collection: []const u8, image: []const u8 };
        var picks: std.ArrayList(Pick) = .empty;
        var desired: std.ArrayList(Assignment) = .empty;
        const plan = try self.policyContext().planRotation(self.a, before, outputs, automatic, active_only);
        if (plan.reset_active_timer) return self.resetTimer();
        for (plan.targets) |target| {
            const output = target.output;
            const name = target.collection;
            const image = for (picks.items) |pick| {
                if (u.eql(pick.collection, name)) break pick.image;
            } else blk: {
                const chosen = try self.pickFrom(name);
                try picks.append(self.a, .{ .collection = name, .image = chosen });
                break :blk chosen;
            };
            try desired.append(self.a, .{ .output = output, .image = image });
        }
        if (desired.items.len == 0) return;
        try self.apply(before, desired.items, null, false);
    }
    fn navigate(self: *Engine, index: usize) !void {
        const before = try self.prepare();
        const desired = try self.fit(self.state.layouts[index].outputs, before);
        try self.apply(before, desired, index, false);
    }
    pub fn execute(self: *Engine, req: Request) !void {
        const arg = if (req.args.len > 0) req.args[0] else "";
        switch (req.action) {
            .explain => {
                var context = self.policyContext();
                // A configured xrandr executable is not enough if no X display
                // is available. Explain the backend's actual targeting ability.
                context.per_output = self.be().queryable() or self.fehMonitors() != null;
                try self.message.appendSlice(self.a, try explanation.render(self.a, context, self.daemon, req.output, req.json, self.outputsIgnored()));
            },
            .schedule => {
                if (!u.eql(arg, "resume")) return self.showSchedule(req.json);
                if (req.output) |output| return self.resumeOutput(output);
                if (self.cfg.schedule.len == 0 and self.cfg.schedules.len == 0) return error.NoScheduleConfigured;
                if (self.cfg.schedule.len > 0) try self.resumeGlobal();
                if (self.assignments() and self.cfg.schedules.len > 0) {
                    const connected = try self.current();
                    for (self.cfg.schedules) |schedule| try self.switchScheduled(schedule.name, (try self.namedWindow(schedule.name)).?, connected, null);
                }
                try self.print("following schedule (holds still apply)\n", .{});
            },
            .use => {
                _ = self.cfg.effective(arg) catch return u.fail(self.a, "unknown collection '{s}'; run 'zpaper collections'", .{arg});
                const before = self.state;
                self.state.collection = arg;
                self.rotateActive(false) catch |err| {
                    if (!self.dirty) {
                        self.state = before;
                    } else {
                        try self.print("active collection: {s} (some outputs failed)\n", .{arg});
                    }
                    return err;
                };
                // Switching is a new choice even if two collections overlap.
                if (self.state.layouts.len > 0) self.state.layouts = self.state.layouts[0 .. self.state.cursor + 1];
                if (!self.dirty) {
                    // Every connected monitor has its own collection.
                    self.dirty = true;
                    try self.print("active collection: {s} (every connected output has its own collection)\n", .{arg});
                } else try self.print("active collection: {s}\n", .{arg});
            },
            .collections => {
                const Entry = struct { name: []const u8, active: bool, dir: ?[]const u8, wallpaper: ?[]const u8, interval_seconds: u64, recursive: bool, outputs: []const []const u8 };
                var entries: std.ArrayList(Entry) = .empty;
                var names: std.ArrayList([]const u8) = .empty;
                try names.append(self.a, "default");
                for (self.cfg.collections) |collection| try names.append(self.a, collection.name);
                for (names.items) |name| {
                    const cfg = try self.cfg.effective(name);
                    var assigned_outputs: std.ArrayList([]const u8) = .empty;
                    if (self.assignments()) for (self.cfg.outputs) |rule| if (u.eql(self.assignedCollection(rule.output) orelse "", name)) {
                        try assigned_outputs.append(self.a, rule.output);
                    };
                    try entries.append(self.a, .{ .name = name, .active = u.eql(name, self.collectionName()), .dir = cfg.dir, .wallpaper = cfg.wallpaper, .interval_seconds = cfg.interval, .recursive = cfg.recursive, .outputs = try assigned_outputs.toOwnedSlice(self.a) });
                }
                if (req.json) {
                    try self.print("{s}\n", .{try std.json.Stringify.valueAlloc(self.a, entries.items, .{})});
                } else for (entries.items) |entry| {
                    try self.print("{s}{s}: {s}; interval {d}s{s}{s}\n", .{ if (entry.active) "* " else "  ", entry.name, entry.wallpaper orelse entry.dir orelse "(no source configured)", entry.interval_seconds, if (entry.recursive) "; recursive" else "", if (entry.outputs.len > 0) try std.fmt.allocPrint(self.a, "; outputs {s}", .{try std.mem.join(self.a, ",", entry.outputs)}) else "" });
                }
            },
            .set => try self.setImages(req.args, req.output, false),
            .next => {
                if (req.output == null and self.state.layouts.len > 0 and self.state.cursor + 1 < self.state.layouts.len) {
                    try self.navigate(self.state.cursor + 1);
                } else try self.rotate(false, req.output);
            },
            .previous => {
                if (self.state.layouts.len == 0 or self.state.cursor == 0) return error.NoPreviousLayout;
                try self.navigate(self.state.cursor - 1);
            },
            .restore => {
                if (self.state.current.len == 0) return self.rotate(false, null);
                const before = try self.prepare();
                const desired = try self.fit(self.state.current, before);
                try self.apply(before, desired, null, true);
            },
            .hold => {
                const seconds = if (arg.len == 0) 0 else try u.duration(arg, 60);
                if (arg.len > 0 and seconds == 0) return error.InvalidDuration;
                const until: i64 = if (seconds == 0) -1 else self.now() + @as(i64, @intCast(seconds));
                const names: []const []const u8 = if (req.output == null) &.{"*"} else try self.targets(try self.current(), req.output, false);
                var holds: std.ArrayList(state_mod.Hold) = .empty;
                for (self.state.holds) |h| if (!u.contains(names, h.output)) {
                    try holds.append(self.a, h);
                };
                for (names) |name| try holds.append(self.a, .{ .output = name, .until = until });
                self.state.holds = try holds.toOwnedSlice(self.a);
                self.dirty = true;
                try self.print("held {s}{s}\n", .{ req.output orelse "all outputs", if (until == -1) " until resumed" else try std.fmt.allocPrint(self.a, " for {d}s", .{seconds}) });
            },
            .@"resume" => {
                var holds: std.ArrayList(state_mod.Hold) = .empty;
                if (req.output != null) {
                    for (self.state.holds) |h| if (!outputSelected(h.output, req.output)) {
                        try holds.append(self.a, h);
                    };
                }
                self.state.holds = try holds.toOwnedSlice(self.a);
                try self.resetTimer();
                try self.print("rotation resumed for {s}\n", .{req.output orelse "all outputs"});
                if (req.output != null and self.state.held("*", self.now())) try self.print("global hold is still active; use 'zpaper resume' to release it\n", .{});
            },
            .current, .status => {
                const b = self.be();
                const actual = if (req.action == .current) try self.current() else self.state.current;
                const cfg = self.cfg.effective(self.collectionName()) catch null;
                const interval = if (cfg) |c| c.interval else 0;
                if (req.json) {
                    try self.print("{s}\n", .{try std.json.Stringify.valueAlloc(self.a, .{
                        .daemon = self.daemon,
                        .version = @import("build_options").version,
                        .backend = @tagName(b.kind),
                        .source = if (req.action == .current and b.queryable()) "backend" else "recorded",
                        .outputs = actual,
                        .holds = self.state.holds,
                        .next_due = self.state.next_due,
                        .interval_seconds = interval,
                        .collection = self.collectionName(),
                        .collection_available = cfg != null,
                        .output_collections = try self.outputCollections(),
                        .collection_due = if (self.assignments()) self.state.collection_due else &.{},
                        .schedule = try self.scheduleInfo(),
                    }, .{})});
                } else {
                    try self.print("daemon: {s}\nbackend: {s}\nstate: {s}\n", .{ if (self.daemon) "running (" ++ @import("build_options").version ++ ")" else "not running", @tagName(b.kind), if (req.action == .current and b.queryable()) "backend query" else "last recorded" });
                    try self.print("collection: {s}{s}\n", .{ self.collectionName(), if (cfg == null) " (not defined; use another collection)" else "" });
                    const schedule_info = try self.scheduleInfo();
                    if (self.outputsIgnored()) |note| try self.print("{s}\n", .{note});
                    if (schedule_info.enabled) try self.print("schedule: {s}{s}\n", .{ schedule_info.current.?.collection, if (schedule_info.manual_override) " (manual choice until next change)" else if (schedule_info.pending) " (pending)" else "" });
                    for (actual) |entry| try self.print("{s}: {s}{s}\n", .{ entry.output, if (entry.image.len == 0) "(no image)" else entry.image, try self.assignmentLabel(entry.output) });
                    for (self.state.holds) |h| if (h.until == -1 or h.until > self.now()) {
                        try self.print("hold {s}: {s}\n", .{ h.output, if (h.until == -1) "until resumed" else try std.fmt.allocPrint(self.a, "{d}s remaining", .{h.until - self.now()}) });
                    };
                    if (interval == 0) {
                        try self.print("rotation: disabled\n", .{});
                    } else {
                        try self.print("rotation: every {d}s; next due in {d}s (holds take precedence)\n", .{ interval, @max(0, self.state.next_due - self.now()) });
                    }
                    if (self.assignments()) for (self.state.collection_due) |entry| {
                        const assigned_cfg = self.cfg.effective(entry.name) catch continue;
                        var in_use = false;
                        for (self.cfg.outputs) |rule| if (u.eql(self.assignedCollection(rule.output) orelse "", entry.name)) {
                            in_use = true;
                        };
                        if (!in_use or assigned_cfg.interval == 0) continue;
                        try self.print("rotation {s}: every {d}s; next due in {d}s\n", .{ entry.name, assigned_cfg.interval, @max(0, entry.due - self.now()) });
                    };
                }
            },
            .history, .search => {
                if (req.json) {
                    try self.print("{s}\n", .{try std.json.Stringify.valueAlloc(self.a, self.state.images, .{})});
                } else for (self.state.images, 0..) |entry, i| {
                    if (req.action == .search and std.mem.indexOf(u8, entry.path, arg) == null) continue;
                    try self.print("{d}. [{s}] {s}{s}\n", .{ i + 1, entry.time, entry.path, if (u.exists(self.rt, entry.path)) "" else " (missing)" });
                }
            },
            .layouts => {
                if (req.json) {
                    try self.print("{s}\n", .{try std.json.Stringify.valueAlloc(self.a, .{ .cursor = self.state.cursor, .layouts = self.state.layouts }, .{})});
                } else for (self.state.layouts, 0..) |layout, i| {
                    try self.print("{d}.{s} [{d}]\n", .{ i + 1, if (i == self.state.cursor) " current" else "", layout.time });
                    for (layout.outputs) |entry| try self.print("  {s}: {s}\n", .{ entry.output, entry.image });
                }
            },
            .select => {
                const index = std.fmt.parseInt(usize, arg, 10) catch return error.InvalidIndex;
                if (index == 0 or index > self.state.images.len) return error.InvalidIndex;
                try self.setImages(&.{self.state.images[index - 1].path}, req.output, false);
            },
            .favorite, .unfavorite, .exclude, .include => {
                var paths: std.ArrayList([]const u8) = .empty;
                if (req.args.len > 0) {
                    try paths.appendSlice(self.a, req.args);
                } else {
                    const outputs = try self.current();
                    for (outputs) |entry| if (entry.image.len > 0 and outputSelected(entry.output, req.output)) {
                        try paths.append(self.a, entry.image);
                    };
                }
                if (paths.items.len == 0) return error.NoCurrentWallpaper;
                const is_favorite = req.action == .favorite or req.action == .unfavorite;
                const remove = req.action == .unfavorite or req.action == .include;
                var list = if (is_favorite) self.state.favorites else self.state.excluded;
                if (remove) {
                    var keep: std.ArrayList([]const u8) = .empty;
                    for (list) |path| if (!u.contains(paths.items, path)) {
                        try keep.append(self.a, path);
                    };
                    list = try keep.toOwnedSlice(self.a);
                } else for (paths.items) |path| {
                    if (!u.contains(list, path)) list = try u.append([]const u8, self.a, list, path);
                }
                if (is_favorite) {
                    self.state.favorites = list;
                } else {
                    self.state.excluded = list;
                }
                self.dirty = true;
                try self.print("{s}: {d} image(s)\n", .{ @tagName(req.action), paths.items.len });
            },
            .favorites => {
                if (req.json) {
                    try self.print("{s}\n", .{try std.json.Stringify.valueAlloc(self.a, self.state.favorites, .{})});
                } else for (self.state.favorites, 0..) |path, i| try self.print("{d}. {s}{s}\n", .{ i + 1, path, if (u.exists(self.rt, path)) "" else " (missing)" });
            },
            .random_favorite => {
                var valid: std.ArrayList([]const u8) = .empty;
                for (self.state.favorites) |path| if (u.exists(self.rt, path) and !u.contains(self.state.excluded, path)) {
                    try valid.append(self.a, path);
                };
                if (valid.items.len == 0) return error.NoFavorites;
                const path = valid.items[self.rt.randomLessThan(usize, valid.items.len)];
                try self.setImages(&.{path}, req.output, false);
            },
            .list => {
                const cfg = if (arg.len == 0) try self.settings() else self.cfg.effective(arg) catch return u.fail(self.a, "unknown collection '{s}'", .{arg});
                const dir = cfg.dir orelse return error.NoDirectoryConfigured;
                const paths = try picker.collect(self.rt, self.a, dir, cfg.recursive);
                std.mem.sort([]u8, paths, {}, struct {
                    fn less(_: void, x: []u8, y: []u8) bool {
                        return std.mem.lessThan(u8, x, y);
                    }
                }.less);
                if (req.json) {
                    try self.print("{s}\n", .{try std.json.Stringify.valueAlloc(self.a, paths, .{})});
                } else for (paths) |path| try self.print("{s}\n", .{path});
            },
            .clear_history => {
                self.state.images = &.{};
                self.state.layouts = &.{};
                self.state.cursor = 0;
                self.dirty = true;
                try self.print("history cleared\n", .{});
            },
            .import_legacy => try self.importLegacy(if (arg.len > 0) arg else try u.absolute(self.rt, self.a, "~/.cache")),
            else => return error.InvalidCommand,
        }
    }
    fn importLegacy(self: *Engine, dir: []const u8) !void {
        var imported: usize = 0;
        const history_path = try std.fs.path.join(self.a, &.{ dir, "wallpaper_history" });
        const bytes = u.read(self.rt, self.a, history_path, 4 * 1024 * 1024) catch |err| if (err == error.FileNotFound) "" else return err;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const bar = std.mem.indexOfScalar(u8, line, '|') orelse continue;
            const path = line[bar + 1 ..];
            if (!std.fs.path.isAbsolute(path)) {
                try self.print("skipped ambiguous legacy path: {s}\n", .{path});
                continue;
            }
            var found = false;
            for (self.state.images) |entry| if (u.eql(entry.path, path)) {
                found = true;
                break;
            };
            if (!found and self.state.images.len < 100) {
                self.state.images = try u.append(state_mod.Image, self.a, self.state.images, .{ .time = line[0..bar], .path = path });
                imported += 1;
            }
        }
        const favorite_path = try std.fs.path.join(self.a, &.{ dir, "wallpaper_favorites" });
        const favorites = u.read(self.rt, self.a, favorite_path, 4 * 1024 * 1024) catch |err| if (err == error.FileNotFound) "" else return err;
        lines = std.mem.splitScalar(u8, favorites, '\n');
        while (lines.next()) |raw| {
            const path = std.mem.trimEnd(u8, raw, "\r");
            if (path.len == 0) continue;
            if (!std.fs.path.isAbsolute(path)) {
                try self.print("skipped ambiguous legacy path: {s}\n", .{path});
                continue;
            }
            if (!u.contains(self.state.favorites, path)) {
                self.state.favorites = try u.append([]const u8, self.a, self.state.favorites, path);
                imported += 1;
            }
        }
        self.dirty = imported > 0;
        try self.print("imported {d} history/favorite entries; original files unchanged\n", .{imported});
    }
};
// One entry per monitor from `xrandr --listmonitors`, without the index
// column so renumbering alone is not a change: "+*eDP-1 1920/344x1080/194+0+0  eDP-1".
// The monitor name: the last column of a parseMonitors entry.
fn monitorName(line: []const u8) []const u8 {
    const space = std.mem.lastIndexOfAny(u8, line, " \t") orelse return line;
    return line[space + 1 ..];
}
pub fn parseMonitors(a: u.A, text: []const u8) ![]const []const u8 {
    var monitors: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "Monitors:")) continue;
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        try monitors.append(a, std.mem.trim(u8, line[colon + 2 ..], " \t"));
    }
    return monitors.toOwnedSlice(a);
}
test "xrandr monitor list ignores header and index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const monitors = try parseMonitors(arena.allocator(), "Monitors: 2\n 0: +*eDP-1 1920/344x1080/194+0+0  eDP-1\n 1: +HDMI-1 2560/597x1440/336+1920+0  HDMI-1\n");
    try std.testing.expectEqual(@as(usize, 2), monitors.len);
    try std.testing.expectEqualStrings("+*eDP-1 1920/344x1080/194+0+0  eDP-1", monitors[0]);
    try std.testing.expectEqualStrings("+HDMI-1 2560/597x1440/336+1920+0  HDMI-1", monitors[1]);
    try std.testing.expectEqualStrings("eDP-1", monitorName(monitors[0]));
    try std.testing.expectEqualStrings("HDMI-A-0", monitorName("+*HDMI-A-0 1920/597x1080/336+0+0  HDMI-A-0"));
}
// Single pass so a path containing "%o" is never expanded a second time.
fn expandHook(a: u.A, arg: []const u8, image: []const u8, output: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < arg.len) : (i += 1) {
        if (arg[i] == '%' and i + 1 < arg.len and (arg[i + 1] == 's' or arg[i + 1] == 'o')) {
            try out.appendSlice(a, if (arg[i + 1] == 's') image else output);
            i += 1;
        } else try out.append(a, arg[i]);
    }
    return out.toOwnedSlice(a);
}
test "hook placeholders expand once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/p/%o.png on DP-1", try expandHook(a, "%s on %o", "/p/%o.png", "DP-1"));
    try std.testing.expectEqualStrings("--image=/x.png", try expandHook(a, "--image=%s", "/x.png", "*"));
    try std.testing.expectEqualStrings("100%", try expandHook(a, "100%", "/x.png", "*"));
}
