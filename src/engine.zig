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
const Assignment = state_mod.Assignment;
pub const Action = enum { set, next, previous, hold, @"resume", current, status, history, layouts, search, select, favorite, unfavorite, favorites, random_favorite, exclude, include, list, restore, import_legacy, clear_history, collections, use, schedule, daemon, stop, reload, check };
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
    fn now(self: *Engine) i64 {
        return self.now_override orelse clock.now(self.rt);
    }
    fn scheduleWindow(self: *Engine) !?scheduling.Window {
        if (self.cfg.schedule.len == 0) return null;
        return scheduling.evaluate(self.cfg.schedule, try clock.localAt(self.now()));
    }
    pub fn rememberManualChoice(self: *Engine, action: Action) !void {
        if (!self.dirty) return;
        switch (action) {
            .use, .set, .next, .previous, .select, .random_favorite, .restore => {},
            else => return,
        }
        if (try self.scheduleWindow()) |window| self.state.schedule_cursor = scheduling.manualOverride(window, self.state.schedule_cursor);
    }
    // Returns true while a schedule change takes precedence over interval
    // rotation (including a deferred change while all target outputs are held).
    pub fn applySchedule(self: *Engine) !bool {
        const window = (try self.scheduleWindow()) orelse return false;
        if (!scheduling.due(window, self.state.schedule_cursor)) return false;
        if (self.state.held("*", self.now())) return true;
        const before = self.state;
        if (!u.eql(self.collectionName(), window.current.collection) or self.state.current.len == 0) {
            self.state.collection = window.current.collection;
            self.rotate(true, null) catch |err| {
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
    const ScheduleInfo = struct {
        enabled: bool,
        timezone: []const u8 = "local",
        current: ?scheduling.Event = null,
        next: ?scheduling.Event = null,
        manual_override: bool = false,
        held: bool = false,
        pending: bool = false,
    };
    fn scheduleInfo(self: *Engine) !ScheduleInfo {
        const window = (try self.scheduleWindow()) orelse return .{ .enabled = false };
        const pending = scheduling.due(window, self.state.schedule_cursor);
        return .{ .enabled = true, .current = window.current, .next = scheduling.nextChange(self.cfg.schedule, window, self.state.schedule_cursor), .manual_override = if (self.state.schedule_cursor) |cursor| cursor.manual and !pending else false, .held = self.state.held("*", self.now()), .pending = pending };
    }
    fn showSchedule(self: *Engine, json: bool) !void {
        const info = try self.scheduleInfo();
        if (json) {
            try self.print("{s}\n", .{try std.json.Stringify.valueAlloc(self.a, .{ .status = info, .rules = self.cfg.schedule }, .{})});
            return;
        }
        if (!info.enabled) {
            try self.print("schedule: not configured\n", .{});
            return;
        }
        try self.print("schedule: local time{s}{s}\n", .{ if (info.manual_override) "; manual choice until next scheduled change" else "", if (info.held) "; held" else "" });
        for (self.cfg.schedule) |rule| try self.print("  {d:0>2}:{d:0>2} -> {s}\n", .{ rule.minute / 60, rule.minute % 60, rule.collection });
        const next = info.next.?;
        const local = try clock.localAt(self.now());
        try self.print("current period: {s}; next: {d:0>2}:{d:0>2} {s} -> {s}\n", .{ info.current.?.collection, next.minute / 60, next.minute % 60, if (next.day == local.day) "today" else if (next.day == local.day + 1) "tomorrow" else try std.fmt.allocPrint(self.a, "in {d} days", .{next.day - local.day}), next.collection });
    }
    pub fn print(self: *Engine, comptime fmt: []const u8, args: anytype) !void {
        try self.message.appendSlice(self.a, try std.fmt.allocPrint(self.a, fmt, args));
    }
    fn collectionName(self: *Engine) []const u8 {
        return self.cfg.selectedName(self.state.collection);
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
        // A global-only backend cannot assert an old Wayland output mapping.
        for (self.state.current) |entry| if (u.eql(entry.output, "*")) return self.a.dupe(Assignment, &.{entry});
        return &.{};
    }
    fn resetTimer(self: *Engine) !void {
        const cfg = try self.settings();
        self.state.next_due = if (cfg.interval == 0) 0 else self.now() + @as(i64, @intCast(cfg.interval));
        self.dirty = true;
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
        } else if (self.be().queryable()) {
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
    fn apply(self: *Engine, before: []const Assignment, desired: []const Assignment, navigation: ?usize) !void {
        _ = try self.settings();
        var after = try self.a.dupe(Assignment, before);
        var successes: usize = 0;
        var failures: usize = 0;
        const b = self.be();
        for (desired) |entry| {
            var index: ?usize = null;
            for (after, 0..) |old, i| if (u.eql(old.output, entry.output)) {
                index = i;
                break;
            };
            if (entry.image.len == 0 or (b.queryable() and index == null)) {
                failures += 1;
                try self.print("skipped {s}: {s}\n", .{ entry.output, if (entry.image.len == 0) "saved output has no image" else "output is disconnected" });
                continue;
            }
            b.apply(entry.image, entry.output) catch |err| {
                failures += 1;
                try self.print("failed {s}: {s}\n", .{ entry.output, if (u.diagnostic.len > 0) u.diagnostic else @errorName(err) });
                u.diagnostic = "";
                continue;
            };
            successes += 1;
            if (index) |i| {
                after[i] = entry;
            } else {
                after = try self.a.dupe(Assignment, try u.append(Assignment, self.a, after, entry));
            }
            try self.print("{s}: {s}\n", .{ entry.output, entry.image });
            const timestamp = try std.fmt.allocPrint(self.a, "{d}", .{self.now()});
            try self.state.addImage(self.a, entry.image, timestamp);
            try self.state.markSeen(self.a, self.collectionName(), entry.image);
        }
        if (successes > 0) {
            self.wallpaper_applied = true;
            self.state.collection = self.collectionName();
            if (navigation != null and failures == 0 and state_mod.same(after, self.state.layouts[navigation.?].outputs)) {
                self.state.cursor = navigation.?;
                self.state.current = after;
            } else {
                if (before.len > 0) try self.state.record(self.rt, self.a, before);
                try self.state.record(self.rt, self.a, after);
            }
            try self.resetTimer();
            if (self.cfg.notify) {
                _ = u.run(self.rt, self.a, &.{ "notify-send", "zpaper", "Wallpaper updated" }, 3) catch {};
                u.diagnostic = "";
            }
        }
        if (failures > 0) return error.LayoutIncomplete;
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
        if (paths.len > outputs.len) return error.TooManyImages;
        var desired: std.ArrayList(Assignment) = .empty;
        for (outputs, 0..) |output, i| {
            if (paths.len > 1 and i >= paths.len) break;
            try desired.append(self.a, .{ .output = output, .image = paths[if (paths.len == 1) 0 else i] });
        }
        try self.apply(before, desired.items, null);
    }
    pub fn rotate(self: *Engine, automatic: bool, filter: ?[]const u8) !void {
        if (automatic and self.state.held("*", self.now())) return;
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
    fn navigate(self: *Engine, index: usize) !void {
        const desired = self.state.layouts[index].outputs;
        const before = try self.prepare();
        try self.apply(before, desired, index);
    }
    pub fn execute(self: *Engine, req: Request) !void {
        const arg = if (req.args.len > 0) req.args[0] else "";
        switch (req.action) {
            .schedule => {
                if (u.eql(arg, "resume")) {
                    if (self.cfg.schedule.len == 0) return error.NoScheduleConfigured;
                    // Use a clean engine so dirty from this control change does
                    // not disguise a failed wallpaper application.
                    var scheduled = self.*;
                    scheduled.state.schedule_cursor = null;
                    const changed = scheduled.applySchedule() catch |err| {
                        if (scheduled.dirty) {
                            self.* = scheduled;
                        } else {
                            self.message = scheduled.message;
                        }
                        return err;
                    };
                    _ = changed;
                    self.* = scheduled;
                    // Releasing a manual override persists even when held.
                    self.dirty = true;
                    try self.print("following schedule (holds still apply)\n", .{});
                } else try self.showSchedule(req.json);
            },
            .use => {
                _ = self.cfg.effective(arg) catch return u.fail(self.a, "unknown collection '{s}'; run 'zpaper collections'", .{arg});
                const before = self.state;
                self.state.collection = arg;
                self.rotate(false, null) catch |err| {
                    if (!self.dirty) {
                        self.state = before;
                    } else {
                        try self.print("active collection: {s} (some outputs failed)\n", .{arg});
                    }
                    return err;
                };
                // Switching is a new choice even if two collections overlap.
                if (self.state.layouts.len > 0) self.state.layouts = self.state.layouts[0 .. self.state.cursor + 1];
                try self.print("active collection: {s}\n", .{arg});
            },
            .collections => {
                const Entry = struct { name: []const u8, active: bool, dir: ?[]const u8, wallpaper: ?[]const u8, interval_seconds: u64, recursive: bool };
                var entries: std.ArrayList(Entry) = .empty;
                var names: std.ArrayList([]const u8) = .empty;
                try names.append(self.a, "default");
                for (self.cfg.collections) |collection| try names.append(self.a, collection.name);
                for (names.items) |name| {
                    const cfg = try self.cfg.effective(name);
                    try entries.append(self.a, .{ .name = name, .active = u.eql(name, self.collectionName()), .dir = cfg.dir, .wallpaper = cfg.wallpaper, .interval_seconds = cfg.interval, .recursive = cfg.recursive });
                }
                if (req.json) {
                    try self.print("{s}\n", .{try std.json.Stringify.valueAlloc(self.a, entries.items, .{})});
                } else for (entries.items) |entry| {
                    try self.print("{s}{s}: {s}; interval {d}s{s}\n", .{ if (entry.active) "* " else "  ", entry.name, entry.wallpaper orelse entry.dir orelse "(no source configured)", entry.interval_seconds, if (entry.recursive) "; recursive" else "" });
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
                const desired = self.state.current;
                const before = try self.prepare();
                try self.apply(before, desired, null);
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
                        .backend = @tagName(b.kind),
                        .source = if (req.action == .current and b.queryable()) "backend" else "recorded",
                        .outputs = actual,
                        .holds = self.state.holds,
                        .next_due = self.state.next_due,
                        .interval_seconds = interval,
                        .collection = self.collectionName(),
                        .collection_available = cfg != null,
                        .schedule = try self.scheduleInfo(),
                    }, .{})});
                } else {
                    try self.print("daemon: {s}\nbackend: {s}\nstate: {s}\n", .{ if (self.daemon) "running" else "not running", @tagName(b.kind), if (req.action == .current and b.queryable()) "backend query" else "last recorded" });
                    try self.print("collection: {s}{s}\n", .{ self.collectionName(), if (cfg == null) " (not defined; use another collection)" else "" });
                    const schedule_info = try self.scheduleInfo();
                    if (schedule_info.enabled) try self.print("schedule: {s}{s}\n", .{ schedule_info.current.?.collection, if (schedule_info.manual_override) " (manual choice until next change)" else if (schedule_info.pending) " (pending)" else "" });
                    for (actual) |entry| try self.print("{s}: {s}\n", .{ entry.output, if (entry.image.len == 0) "(no image)" else entry.image });
                    for (self.state.holds) |h| if (h.until == -1 or h.until > self.now()) {
                        try self.print("hold {s}: {s}\n", .{ h.output, if (h.until == -1) "until resumed" else try std.fmt.allocPrint(self.a, "{d}s remaining", .{h.until - self.now()}) });
                    };
                    if (interval == 0) {
                        try self.print("rotation: disabled\n", .{});
                    } else {
                        try self.print("rotation: every {d}s; next due in {d}s (holds take precedence)\n", .{ interval, @max(0, self.state.next_due - self.now()) });
                    }
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
