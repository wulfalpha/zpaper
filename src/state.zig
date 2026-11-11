const std = @import("std");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const u = @import("util.zig");
const clock = @import("clock.zig");
const scheduling = @import("schedule.zig");
pub const Assignment = struct { output: []const u8, image: []const u8 };
pub const Layout = struct { time: i64, outputs: []const Assignment };
pub const Image = struct { time: []const u8, path: []const u8 };
pub const Hold = struct { output: []const u8 = "*", until: i64 = -1 };
pub const Progress = struct { name: []const u8, seen: []const []const u8 = &.{} };
pub const State = struct {
    version: u32 = 3,
    schedule_cursor: ?scheduling.Cursor = null,
    collection: ?[]const u8 = null,
    collection_progress: []const Progress = &.{},
    current: []const Assignment = &.{},
    layouts: []const Layout = &.{},
    cursor: usize = 0,
    images: []const Image = &.{},
    favorites: []const []const u8 = &.{},
    excluded: []const []const u8 = &.{},
    seen: []const []const u8 = &.{},
    holds: []const Hold = &.{},
    next_due: i64 = 0,

    pub fn seenFor(self: State, name: []const u8) []const []const u8 {
        if (u.eql(name, "default")) return self.seen;
        for (self.collection_progress) |progress| if (u.eql(progress.name, name)) return progress.seen;
        return &.{};
    }
    pub fn setSeen(self: *State, a: u.A, name: []const u8, paths: []const []const u8) !void {
        if (u.eql(name, "default")) {
            self.seen = paths;
            return;
        }
        // Copy before editing so a failed collection switch can restore the
        // original State value without retaining mutations through its slices.
        const progress = try a.dupe(Progress, self.collection_progress);
        for (progress) |*entry| if (u.eql(entry.name, name)) {
            entry.seen = paths;
            self.collection_progress = progress;
            return;
        };
        self.collection_progress = try u.append(Progress, a, progress, .{ .name = name, .seen = paths });
    }
    pub fn markSeen(self: *State, a: u.A, name: []const u8, path: []const u8) !void {
        const paths = self.seenFor(name);
        if (!u.contains(paths, path)) try self.setSeen(a, name, try u.append([]const u8, a, paths, path));
    }
    pub fn held(self: State, output: []const u8, now: i64) bool {
        for (self.holds) |h| {
            if ((u.eql(h.output, "*") or u.eql(h.output, output)) and (h.until == -1 or h.until > now)) return true;
        }
        return false;
    }
    pub fn record(self: *State, rt: Runtime, a: u.A, outputs: []const Assignment) !void {
        if (self.layouts.len > 0 and same(self.layouts[self.cursor].outputs, outputs)) {
            self.current = outputs;
            return;
        }
        const keep = if (self.layouts.len == 0) 0 else self.cursor + 1;
        const start = keep -| 99;
        self.layouts = try u.append(Layout, a, self.layouts[start..keep], .{ .time = clock.now(rt), .outputs = outputs });
        self.cursor = self.layouts.len - 1;
        self.current = outputs;
    }
    pub fn addImage(self: *State, a: u.A, path: []const u8, timestamp: []const u8) !void {
        var entries: std.ArrayList(Image) = .empty;
        try entries.append(a, .{ .time = timestamp, .path = path });
        for (self.images) |entry| {
            if (entries.items.len == 100) break;
            if (!u.eql(entry.path, path)) try entries.append(a, entry);
        }
        self.images = try entries.toOwnedSlice(a);
    }
    pub fn choose(self: *State, rt: Runtime, a: u.A, name: []const u8, candidates: []const []const u8) ![]const u8 {
        const previous_seen = self.seenFor(name);
        var eligible: std.ArrayList([]const u8) = .empty;
        var remaining: std.ArrayList([]const u8) = .empty;
        for (candidates) |p| {
            if (u.contains(self.excluded, p) or u.contains(eligible.items, p)) continue;
            try eligible.append(a, p);
            if (!u.contains(previous_seen, p)) try remaining.append(a, p);
        }
        if (eligible.items.len == 0) return error.NoImagesFound;
        var seen: std.ArrayList([]const u8) = .empty;
        for (previous_seen) |path| if (u.contains(eligible.items, path)) {
            try seen.append(a, path);
        };
        try self.setSeen(a, name, try seen.toOwnedSlice(a));
        if (remaining.items.len == 0) {
            try self.setSeen(a, name, &.{});
            try remaining.appendSlice(a, eligible.items);
        }
        // Avoid a cycle-boundary immediate repeat if any alternative exists.
        if (remaining.items.len > 1) {
            var alternatives: std.ArrayList([]const u8) = .empty;
            for (remaining.items) |p| {
                var current = false;
                for (self.current) |entry| if (u.eql(entry.image, p)) {
                    current = true;
                    break;
                };
                if (!current) try alternatives.append(a, p);
            }
            if (alternatives.items.len > 0) remaining = alternatives;
        }
        return remaining.items[rt.randomLessThan(usize, remaining.items.len)];
    }
};
pub fn same(lhs: []const Assignment, rhs: []const Assignment) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs) |x| {
        var found = false;
        for (rhs) |y| if (u.eql(x.output, y.output) and u.eql(x.image, y.image)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}
pub fn load(rt: Runtime, a: u.A, path: []const u8) !State {
    const bytes = u.read(rt, a, path, 16 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    var state = try std.json.parseFromSliceLeaky(State, a, bytes, .{ .allocate = .alloc_always });
    if (state.version != 1 and state.version != 2 and state.version != 3) return error.UnsupportedStateVersion;
    state.version = 3;
    if ((state.layouts.len > 0 and state.cursor >= state.layouts.len) or (state.layouts.len == 0 and state.cursor != 0)) return error.InvalidStateCursor;
    return state;
}
pub fn save(rt: Runtime, a: u.A, path: []const u8, state: State) !void {
    try u.atomicWrite(rt, a, path, try std.json.Stringify.valueAlloc(a, state, .{ .whitespace = .indent_2 }));
}
test "layout navigation branches and shuffle never repeats within a cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = State{};
    try s.record(runtime.testing(), a, &.{.{ .output = "DP-1", .image = "one" }});
    try s.record(runtime.testing(), a, &.{.{ .output = "DP-1", .image = "two" }});
    try s.record(runtime.testing(), a, &.{.{ .output = "DP-1", .image = "three" }});
    s.cursor = 0;
    try s.record(runtime.testing(), a, &.{.{ .output = "DP-1", .image = "four" }});
    try std.testing.expectEqual(@as(usize, 2), s.layouts.len);
    const candidates: []const []const u8 = &.{ "a", "b", "c" };
    for (0..3) |_| {
        const p = try s.choose(runtime.testing(), a, "default", candidates);
        try std.testing.expect(!u.contains(s.seen, p));
        s.seen = try u.append([]const u8, a, s.seen, p);
    }
    _ = try s.choose(runtime.testing(), a, "default", candidates);
    try std.testing.expectEqual(@as(usize, 0), s.seen.len);
}

test "atomic state roundtrip preserves unusual paths and rejects corrupt state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, "state.json" });
    var original = State{};
    try original.record(runtime.testing(), a, &.{.{ .output = "DP-1", .image = "/images/a|b\twith\nnewline.png" }});
    original.holds = &.{.{ .output = "DP-1", .until = -1 }};
    try save(runtime.testing(), a, path, original);
    const restored = try load(runtime.testing(), a, path);
    try std.testing.expect(same(original.current, restored.current));
    try std.testing.expect(restored.held("DP-1", clock.now(runtime.testing())));
    try u.atomicWrite(runtime.testing(), a, path, "{broken");
    try std.testing.expectError(error.SyntaxError, load(runtime.testing(), a, path));
    try std.testing.expectEqualStrings("{broken", try u.read(runtime.testing(), a, path, 1024));
}

test "collections retain separate shuffle progress" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = State{};
    try s.markSeen(a, "quiet", "a");
    try s.markSeen(a, "work", "b");
    const original = s;
    try std.testing.expectEqualStrings("b", try s.choose(runtime.testing(), a, "quiet", &.{ "a", "b" }));
    try std.testing.expectEqualStrings("a", try s.choose(runtime.testing(), a, "work", &.{ "a", "b" }));
    try s.markSeen(a, "quiet", "b");
    try std.testing.expectEqual(@as(usize, 1), original.seenFor("quiet").len);
    try std.testing.expectEqual(@as(usize, 0), s.seen.len);
}
