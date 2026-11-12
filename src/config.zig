const std = @import("std");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const u = @import("util.zig");
const scheduling = @import("schedule.zig");
pub const Kind = enum { auto, awww, swww, feh, custom };
pub const Collection = struct {
    name: []const u8,
    dir: ?[]const u8 = null,
    interval: ?u64 = null,
    recursive: ?bool = null,
};
pub const OutputRule = struct {
    output: []const u8,
    collection: []const u8 = "",
};
pub const Config = struct {
    daemon: bool = false,
    schedule: []const scheduling.Rule = &.{},
    collection: ?[]const u8 = null,
    collections: []const Collection = &.{},
    outputs: []const OutputRule = &.{},
    dir: ?[]const u8 = null,
    wallpaper: ?[]const u8 = null,
    interval: u64 = 0,
    backend: Kind = .auto,
    setter: []const []const u8 = &.{},
    on_change: []const []const u8 = &.{},
    transition: []const []const u8 = &.{},
    recursive: bool = false,
    notify: bool = false,
    backend_start: bool = true,
    hotplug: bool = true,
    timeout: u64 = 15,
    resize: []const u8 = "crop",

    // The collection an [output.NAME] section assigns, if any.
    pub fn assignedCollection(self: Config, output: []const u8) ?[]const u8 {
        for (self.outputs) |rule| if (u.eql(rule.output, output)) return rule.collection;
        return null;
    }
    pub fn selectedName(self: Config, saved: ?[]const u8) []const u8 {
        return saved orelse self.collection orelse "default";
    }
    pub fn effective(self: Config, name: []const u8) !Config {
        if (u.eql(name, "default")) return self;
        for (self.collections) |collection| {
            if (!u.eql(collection.name, name)) continue;
            var cfg = self;
            cfg.dir = collection.dir;
            cfg.wallpaper = null;
            cfg.interval = collection.interval orelse self.interval;
            cfg.recursive = collection.recursive orelse self.recursive;
            return cfg;
        }
        return error.UnknownCollection;
    }
};
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}
// Output connector names such as DP-1 or HDMI-A-1. Commas would clash with
// --output lists, so only a conservative character set is accepted.
fn validOutputName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or u.eql(name, "*")) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.' and c != ':') return false;
    return true;
}
pub fn getConfigPath(rt: Runtime, a: u.A) ![]const u8 {
    if (rt.env("XDG_CONFIG_HOME")) |p| return std.fs.path.join(a, &.{ p, "zpaper/zpaperc" });
    return std.fs.path.join(a, &.{ rt.env("HOME") orelse return error.NoHomeDir, ".config/zpaper/zpaperc" });
}
pub fn getDataDir(rt: Runtime, a: u.A) ![]const u8 {
    if (rt.env("XDG_STATE_HOME")) |p| return std.fs.path.join(a, &.{ p, "zpaper" });
    return std.fs.path.join(a, &.{ rt.env("HOME") orelse return error.NoHomeDir, ".local/state/zpaper" });
}
fn boolean(value: []const u8) !bool {
    if (u.eql(value, "true")) return true;
    if (u.eql(value, "false")) return false;
    return error.InvalidBoolean;
}
fn scalar(a: u.A, raw: []const u8) ![]const u8 {
    if (raw.len > 0 and (raw[0] == '"' or raw[0] == '\'')) {
        const argv = try u.words(a, raw);
        if (argv.len != 1) return error.InvalidValue;
        return argv[0];
    }
    return raw;
}
fn valueWithoutComment(raw: []const u8) []const u8 {
    var quote: u8 = 0;
    var escape = false;
    for (raw, 0..) |c, i| {
        if (escape) {
            escape = false;
            continue;
        }
        if (c == '\\' and quote != '\'') {
            escape = true;
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '#' and (i == 0 or std.ascii.isWhitespace(raw[i - 1]))) return std.mem.trim(u8, raw[0..i], " \t\r");
    }
    return raw;
}
pub fn parse(rt: Runtime, a: u.A, content: []const u8) !Config {
    var cfg = Config{};
    var seen: std.StringHashMap(void) = .init(a);
    var collections: std.ArrayList(Collection) = .empty;
    var outputs: std.ArrayList(OutputRule) = .empty;
    var section: ?usize = null;
    var output_section: ?usize = null;
    var in_schedule = false;
    var had_schedule = false;
    var rules: std.ArrayList(scheduling.Rule) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = valueWithoutComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (u.eql(line, "[schedule]")) {
                if (had_schedule) return u.fail(a, "config line {d}: duplicate [schedule] section", .{line_no});
                had_schedule = true;
                in_schedule = true;
                section = null;
                output_section = null;
                continue;
            }
            in_schedule = false;
            if (std.mem.startsWith(u8, line, "[output.") and line[line.len - 1] == ']') {
                const name = line[8 .. line.len - 1];
                if (!validOutputName(name)) return u.fail(a, "config line {d}: invalid output name '{s}'", .{ line_no, name });
                for (outputs.items) |existing| if (u.eql(existing.output, name)) return u.fail(a, "config line {d}: duplicate output '{s}'", .{ line_no, name });
                try outputs.append(a, .{ .output = name });
                output_section = outputs.items.len - 1;
                section = null;
                continue;
            }
            output_section = null;
            if (!std.mem.startsWith(u8, line, "[collection.") or line[line.len - 1] != ']')
                return u.fail(a, "config line {d}: expected [collection.NAME], [output.NAME] or [schedule]", .{line_no});
            const name = line[12 .. line.len - 1];
            if (!validName(name) or u.eql(name, "default")) return u.fail(a, "config line {d}: invalid or reserved collection name '{s}'", .{ line_no, name });
            for (collections.items) |existing| if (u.eql(existing.name, name)) return u.fail(a, "config line {d}: duplicate collection '{s}'", .{ line_no, name });
            try collections.append(a, .{ .name = name });
            section = collections.items.len - 1;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return u.fail(a, "config line {d}: expected key = value", .{line_no});
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = valueWithoutComment(std.mem.trim(u8, line[eq + 1 ..], " \t\r"));
        const scoped_key = if (output_section) |i|
            try std.fmt.allocPrint(a, "output.{s}.{s}", .{ outputs.items[i].output, key })
        else
            try std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ if (in_schedule) "schedule" else "collection", if (section) |i| collections.items[i].name else "default", key });
        if (seen.contains(scoped_key)) return u.fail(a, "config line {d}: duplicate key '{s}'", .{ line_no, key });
        try seen.put(scoped_key, {});
        if (in_schedule) {
            const minute = scheduling.parseTime(key) catch |err| return u.fail(a, "config line {d}, schedule time '{s}': {s}", .{ line_no, key, @errorName(err) });
            const name = try scalar(a, val);
            if (!validName(name)) return u.fail(a, "config line {d}: invalid scheduled collection '{s}'", .{ line_no, name });
            try rules.append(a, .{ .minute = minute, .collection = name });
        } else if (output_section) |i| {
            const rule = &outputs.items[i];
            if (!u.eql(key, "collection")) return u.fail(a, "config line {d}, output '{s}': unknown key '{s}' (only 'collection' is supported)", .{ line_no, rule.output, key });
            const name = try scalar(a, val);
            if (!validName(name)) return u.fail(a, "config line {d}, output '{s}': invalid collection name '{s}'", .{ line_no, rule.output, name });
            rule.collection = name;
        } else if (section) |i| {
            setCollection(rt, a, &collections.items[i], key, val) catch |err| return u.fail(a, "config line {d}, collection '{s}', '{s}': {s}", .{ line_no, collections.items[i].name, key, @errorName(err) });
        } else {
            set(rt, a, &cfg, key, val) catch |err| return u.fail(a, "config line {d}, '{s}': {s}", .{ line_no, key, @errorName(err) });
        }
    }
    cfg.collections = try collections.toOwnedSlice(a);
    for (cfg.collections) |collection| if (collection.dir == null) return u.fail(a, "collection '{s}': dir is required", .{collection.name});
    std.mem.sort(scheduling.Rule, rules.items, {}, struct {
        fn less(_: void, lhs: scheduling.Rule, rhs: scheduling.Rule) bool {
            return lhs.minute < rhs.minute;
        }
    }.less);
    cfg.schedule = try rules.toOwnedSlice(a);
    for (cfg.schedule) |rule| {
        const target = cfg.effective(rule.collection) catch return u.fail(a, "schedule {d:0>2}:{d:0>2}: collection '{s}' is not defined", .{ rule.minute / 60, rule.minute % 60, rule.collection });
        if (target.dir == null and target.wallpaper == null) return u.fail(a, "scheduled collection '{s}' has no dir or wallpaper", .{rule.collection});
    }
    _ = cfg.effective(cfg.selectedName(null)) catch return u.fail(a, "default collection '{s}' is not defined", .{cfg.collection.?});
    if (cfg.setter.len > 0) {
        if (cfg.backend != .auto and cfg.backend != .custom) return u.fail(a, "setter requires backend = custom (or auto)", .{});
        cfg.backend = .custom;
    }
    if (cfg.backend == .custom and cfg.setter.len == 0) return error.MissingSetter;
    cfg.outputs = try outputs.toOwnedSlice(a);
    for (cfg.outputs) |rule| {
        if (rule.collection.len == 0) return u.fail(a, "output '{s}': collection is required", .{rule.output});
        const target = cfg.effective(rule.collection) catch return u.fail(a, "output '{s}': collection '{s}' is not defined", .{ rule.output, rule.collection });
        if (target.dir == null and target.wallpaper == null) return u.fail(a, "output '{s}': collection '{s}' has no dir or wallpaper", .{ rule.output, rule.collection });
    }
    return cfg;
}
fn set(rt: Runtime, a: u.A, cfg: *Config, key: []const u8, raw: []const u8) !void {
    const value = if (u.eql(key, "setter") or u.eql(key, "transition") or u.eql(key, "on_change")) raw else try scalar(a, raw);
    if (u.eql(key, "daemon")) {
        cfg.daemon = try boolean(value);
    } else if (u.eql(key, "collection")) {
        if (!validName(value)) return error.InvalidCollectionName;
        cfg.collection = value;
    } else if (u.eql(key, "dir")) {
        cfg.dir = if (value.len == 0) null else try u.absolute(rt, a, value);
    } else if (u.eql(key, "wallpaper")) {
        cfg.wallpaper = if (value.len == 0) null else try u.absolute(rt, a, value);
    } else if (u.eql(key, "interval")) {
        cfg.interval = try u.duration(value, 60);
    } else if (u.eql(key, "backend")) {
        cfg.backend = std.meta.stringToEnum(Kind, value) orelse return error.InvalidBackend;
    } else if (u.eql(key, "setter")) {
        cfg.setter = try u.words(a, value);
        if (cfg.setter.len == 0) return error.EmptyCommand;
    } else if (u.eql(key, "on_change")) {
        cfg.on_change = try u.words(a, value);
    } else if (u.eql(key, "transition")) {
        cfg.transition = try u.words(a, value);
    } else if (u.eql(key, "recursive")) {
        cfg.recursive = try boolean(value);
    } else if (u.eql(key, "notify")) {
        cfg.notify = try boolean(value);
    } else if (u.eql(key, "backend_start")) {
        cfg.backend_start = try boolean(value);
    } else if (u.eql(key, "hotplug")) {
        cfg.hotplug = try boolean(value);
    } else if (u.eql(key, "timeout")) {
        cfg.timeout = try u.duration(value, 1);
        if (cfg.timeout == 0 or cfg.timeout > 300) return error.InvalidTimeout;
    } else if (u.eql(key, "resize")) {
        if (!u.contains(&.{ "crop", "fit", "stretch", "no" }, value)) return error.InvalidResize;
        cfg.resize = value;
    } else return error.UnknownKey;
}
fn setCollection(rt: Runtime, a: u.A, collection: *Collection, key: []const u8, raw: []const u8) !void {
    const value = try scalar(a, raw);
    if (u.eql(key, "dir")) {
        if (value.len == 0) return error.EmptyDirectory;
        collection.dir = try u.absolute(rt, a, value);
    } else if (u.eql(key, "interval")) {
        collection.interval = try u.duration(value, 60);
    } else if (u.eql(key, "recursive")) {
        collection.recursive = try boolean(value);
    } else if (u.eql(key, "order")) {
        if (!u.eql(value, "shuffle")) return error.UnsupportedOrder;
    } else return error.UnknownCollectionKey;
}
pub fn load(rt: Runtime, a: u.A, path: []const u8, required: bool) !Config {
    const content = u.read(rt, a, path, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound and !required) return .{};
        return err;
    };
    return parse(rt, a, content);
}
test "strict configuration and interval zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try parse(runtime.testing(), a, "interval = 0\ndir = '/tmp/a # b'\nsetter = tool \"prefix%s\"\n");
    try std.testing.expectEqual(@as(u64, 0), cfg.interval);
    try std.testing.expect(!cfg.daemon);
    try std.testing.expect((try parse(runtime.testing(), a, "daemon = true")).daemon);
    try std.testing.expectError(error.CommandFailed, parse(runtime.testing(), a, "daemon = yes"));
    try std.testing.expectEqualStrings("/tmp/a # b", cfg.dir.?);
    try std.testing.expectError(error.CommandFailed, parse(runtime.testing(), a, "interval = nope"));
    try std.testing.expectError(error.CommandFailed, parse(runtime.testing(), a, "recursiv = true"));
    try std.testing.expectError(error.CommandFailed, parse(runtime.testing(), a, "notify = yes"));
}

test "collection sections inherit defaults without inheriting fixed wallpaper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try parse(runtime.testing(), a, "collection = quiet\ninterval = 30m\nrecursive = true\nwallpaper = /tmp/fixed.png\n[collection.quiet] # comment\ndir = '/tmp/a # b'\ninterval = 45m\n[collection.work]\ndir = /tmp/work\nrecursive = false\norder = shuffle\n");
    try std.testing.expectEqualStrings("quiet", cfg.selectedName(null));
    try std.testing.expectEqualStrings("default", cfg.selectedName("default"));
    const quiet = try cfg.effective("quiet");
    try std.testing.expectEqualStrings("/tmp/a # b", quiet.dir.?);
    try std.testing.expectEqual(@as(u64, 2700), quiet.interval);
    try std.testing.expect(quiet.recursive);
    try std.testing.expect(quiet.wallpaper == null);
    const work = try cfg.effective("work");
    try std.testing.expectEqual(@as(u64, 1800), work.interval);
    try std.testing.expect(!work.recursive);
    try std.testing.expectError(error.UnknownCollection, cfg.effective("missing"));
    for ([_][]const u8{
        "[collection.default]\ndir=/tmp",
        "[collection.bad name]\ndir=/tmp",
        "[collection.quiet]\ninterval=1m",
        "[collection.quiet]\ndir=/tmp\ndir=/other",
        "[collection.quiet]\ndir=/tmp\n[collection.quiet]\ndir=/other",
        "[collection.quiet]\ndir=/tmp\nbackend=feh",
        "collection=missing",
    }) |bad| try std.testing.expectError(error.CommandFailed, parse(runtime.testing(), a, bad));
}

test "daily schedule references, strict times and section validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try parse(runtime.testing(), a, "dir=/tmp/default\n[schedule]\n20:00=quiet\n08:00=default\n[collection.quiet]\ndir=/tmp/quiet\n");
    try std.testing.expectEqual(@as(usize, 2), cfg.schedule.len);
    try std.testing.expectEqual(@as(u16, 480), cfg.schedule[0].minute);
    try std.testing.expectEqualStrings("quiet", cfg.schedule[1].collection);
    for ([_][]const u8{
        "dir=/tmp\n[schedule]\n8:00=default",
        "dir=/tmp\n[schedule]\n24:00=default",
        "dir=/tmp\n[schedule]\n08:00=default\n08:00=default",
        "dir=/tmp\n[schedule]\n08:00=missing",
        "[schedule]\n08:00=default",
        "[schedule]\n[schedule]",
    }) |bad| try std.testing.expectError(error.CommandFailed, parse(runtime.testing(), a, bad));
}

test "output sections assign collections and are validated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try parse(runtime.testing(), a, "dir=/tmp/default\n[output.DP-2]\ncollection = portrait\n[collection.portrait]\ndir=/tmp/portrait\n[output.HDMI-A-1]\ncollection=default\n");
    try std.testing.expectEqual(@as(usize, 2), cfg.outputs.len);
    try std.testing.expectEqualStrings("portrait", cfg.assignedCollection("DP-2").?);
    try std.testing.expectEqualStrings("default", cfg.assignedCollection("HDMI-A-1").?);
    try std.testing.expect(cfg.assignedCollection("eDP-1") == null);
    for ([_][]const u8{
        "dir=/tmp\n[output.DP-1]",
        "dir=/tmp\n[output.DP-1]\ncollection=missing",
        "dir=/tmp\n[output.DP-1]\ncollection=default\ninterval=5m",
        "dir=/tmp\n[output.DP-1]\ncollection=default\ncollection=default",
        "dir=/tmp\n[output.DP-1]\ncollection=default\n[output.DP-1]\ncollection=default",
        "dir=/tmp\n[output.bad,name]\ncollection=default",
        "[output.DP-1]\ncollection=default",
    }) |bad| try std.testing.expectError(error.CommandFailed, parse(runtime.testing(), a, bad));
    // Global backends ignore output sections at runtime; one config can serve
    // both a Wayland and an X11 session.
    const feh = try parse(runtime.testing(), a, "dir=/tmp\nbackend=feh\n[output.DP-1]\ncollection=default");
    try std.testing.expectEqual(@as(usize, 1), feh.outputs.len);
}
