const std = @import("std");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;

const image_extensions = [_][]const u8{
    ".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tiff", ".tif", ".avif", ".svg",
};

fn hasImageExtension(name: []const u8) bool {
    for (image_extensions) |ext| {
        if (name.len >= ext.len) {
            const suffix = name[name.len - ext.len ..];
            if (std.ascii.eqlIgnoreCase(suffix, ext)) return true;
        }
    }
    return false;
}

fn collectDir(
    rt: Runtime,
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]u8),
    dir_path: []const u8,
    recursive: bool,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(rt.io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("cannot open directory '{s}': {}", .{ dir_path, err });
        return err;
    };
    defer dir.close(rt.io);

    var iter = dir.iterate();
    while (try iter.next(rt.io)) |entry| {
        try rt.checkCancelled();
        switch (entry.kind) {
            .file, .sym_link => {
                if (!hasImageExtension(entry.name)) continue;
                const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
                if (entry.kind == .sym_link) {
                    const stat = dir.statFile(rt.io, entry.name, .{}) catch {
                        allocator.free(path);
                        continue;
                    };
                    if (stat.kind != .file) {
                        allocator.free(path);
                        continue;
                    }
                }
                try list.append(allocator, path);
            },
            .directory => {
                if (!recursive) continue;
                const sub = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer allocator.free(sub);
                try collectDir(rt, allocator, list, sub, recursive);
            },
            else => {},
        }
    }
}

pub fn collect(rt: Runtime, allocator: std.mem.Allocator, dir_path: []const u8, recursive: bool) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    try collectDir(rt, allocator, &list, dir_path, recursive);
    return list.toOwnedSlice(allocator);
}
