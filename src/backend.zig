const std = @import("std");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const u = @import("util.zig");
const config = @import("config.zig");
const Assignment = @import("state.zig").Assignment;
pub const Backend = struct {
    rt: Runtime,
    a: u.A,
    cfg: config.Config,
    kind: config.Kind,
    pub fn init(rt: Runtime, a: u.A, cfg: config.Config) Backend {
        var kind = cfg.backend;
        if (kind == .auto) {
            kind = if (rt.env("WAYLAND_DISPLAY") != null) (if (available(rt, a, "awww")) .awww else .swww) else .feh;
        }
        return .{ .rt = rt, .a = a, .cfg = cfg, .kind = kind };
    }
    pub fn queryable(self: Backend) bool {
        return self.kind == .awww or self.kind == .swww;
    }
    pub fn query(self: Backend) ![]const Assignment {
        if (!self.queryable()) return error.QueryUnsupported;
        const text = try u.run(self.rt, self.a, &.{ @tagName(self.kind), "query" }, self.cfg.timeout);
        return parseQuery(self.a, text, self.kind == .awww);
    }
    pub fn ready(self: Backend) !void {
        try self.rt.checkCancelled();
        if (!self.queryable()) return;
        _ = self.query() catch |original| {
            if (!self.cfg.backend_start) return original;
            const executable = try std.fmt.allocPrint(self.a, "{s}-daemon", .{@tagName(self.kind)});
            const data_dir = try u.absolute(self.rt, self.a, try config.getDataDir(self.rt, self.a));
            try std.Io.Dir.cwd().createDirPath(self.rt.io, data_dir);
            const log_path = try std.fmt.allocPrint(self.a, "{s}/{s}.log", .{ data_dir, executable });
            u.runLogged(self.rt, self.a, &.{ "setsid", "-f", executable }, self.cfg.timeout, log_path) catch |err|
                return u.fail(self.a, "cannot start {s}: {s}; see {s}", .{ executable, if (u.diagnostic.len > 0) u.diagnostic else @errorName(err), log_path });
            for (0..20) |_| {
                try self.rt.checkCancelled();
                try self.rt.sleep(100);
                _ = self.query() catch continue;
                u.diagnostic = "";
                return;
            }
            return u.fail(self.a, "{s} did not become ready; see {s}", .{ executable, log_path });
        };
    }
    fn fehMode(self: Backend) []const u8 {
        return if (u.eql(self.cfg.resize, "crop")) "--bg-fill" else if (u.eql(self.cfg.resize, "fit")) "--bg-max" else if (u.eql(self.cfg.resize, "stretch")) "--bg-scale" else "--bg-center";
    }
    // feh sets every X11 monitor in one call: image i goes on Xinerama
    // monitor i, the order `xrandr --listmonitors` reports.
    pub fn applyMonitors(self: Backend, images: []const []const u8) !void {
        std.debug.assert(self.kind == .feh);
        for (images) |image| if (!u.exists(self.rt, image)) return u.fail(self.a, "image is missing or not a regular file: {s}", .{image});
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.a, &.{ "feh", self.fehMode() });
        try argv.appendSlice(self.a, images);
        _ = try u.run(self.rt, self.a, argv.items, self.cfg.timeout);
    }
    pub fn apply(self: Backend, image: []const u8, output: []const u8) !void {
        if (!u.exists(self.rt, image)) return u.fail(self.a, "image is missing or not a regular file: {s}", .{image});
        var argv: std.ArrayList([]const u8) = .empty;
        switch (self.kind) {
            .awww, .swww => {
                try argv.appendSlice(self.a, &.{ @tagName(self.kind), "img", image });
                if (!u.eql(output, "*")) try argv.appendSlice(self.a, &.{ "--outputs", output });
                try argv.appendSlice(self.a, &.{ "--resize", self.cfg.resize });
                try argv.appendSlice(self.a, self.cfg.transition);
            },
            .feh => {
                if (!u.eql(output, "*")) return error.OutputUnsupported;
                try argv.appendSlice(self.a, &.{ "feh", self.fehMode(), image });
            },
            .custom => {
                if (!u.eql(output, "*")) return error.OutputUnsupported;
                var replaced = false;
                for (self.cfg.setter) |arg| {
                    if (std.mem.indexOf(u8, arg, "%s") != null) replaced = true;
                    try argv.append(self.a, try std.mem.replaceOwned(u8, self.a, arg, "%s", image));
                }
                if (!replaced) try argv.append(self.a, image);
                try argv.appendSlice(self.a, self.cfg.transition);
            },
            .auto => unreachable,
        }
        _ = try u.run(self.rt, self.a, argv.items, self.cfg.timeout);
    }
};
pub fn available(rt: Runtime, a: u.A, name: []const u8) bool {
    var paths = std.mem.splitScalar(u8, rt.env("PATH") orelse "", ':');
    while (paths.next()) |p| {
        const candidate = std.fs.path.resolve(a, &.{ p, name }) catch return false;
        std.Io.Dir.cwd().access(rt.io, candidate, .{ .execute = true }) catch continue;
        return true;
    }
    return false;
}
pub fn parseQuery(a: u.A, text: []const u8, namespaced: bool) ![]const Assignment {
    var outputs: std.ArrayList(Assignment) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (namespaced) {
            const namespace = std.mem.indexOf(u8, line, ": ") orelse return error.InvalidBackendQuery;
            line = line[namespace + 2 ..];
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidBackendQuery;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (name.len == 0) return error.InvalidBackendQuery;
        for (outputs.items) |existing| if (u.eql(existing.output, name)) return error.DuplicateOutput;
        const marker = "currently displaying: image: ";
        const image = if (std.mem.indexOf(u8, line, marker)) |start| line[start + marker.len ..] else "";
        try outputs.append(a, .{ .output = name, .image = image });
    }
    if (outputs.items.len == 0) return error.NoOutputs;
    std.mem.sort(Assignment, outputs.items, {}, struct {
        fn less(_: void, lhs: Assignment, rhs: Assignment) bool {
            return std.mem.lessThan(u8, lhs.output, rhs.output);
        }
    }.less);
    return outputs.toOwnedSlice(a);
}
test "backend query preserves output names and paths with colons and spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const outputs = try parseQuery(arena.allocator(), "awww-daemon: DP-1: 1920x1080, scale: 1, currently displaying: image: /tmp/a: b.png\nawww-daemon: eDP-1: 1920x1080, scale: 1, currently displaying: color: 000000\n", true);
    try std.testing.expectEqualStrings("DP-1", outputs[0].output);
    try std.testing.expectEqualStrings("/tmp/a: b.png", outputs[0].image);
    try std.testing.expectEqualStrings("", outputs[1].image);
}
