//! Synthetic shuffle benchmark: excludes directory scanning and JSON I/O.
const std = @import("std");
const state = @import("state.zig");
const Runtime = @import("runtime.zig").Runtime;

pub fn main(init: std.process.Init) !void {
    const rt = Runtime{ .io = init.io, .environ = init.minimal.environ };
    try std.Io.File.stdout().writeStreamingAll(rt.io, "images,progress,median_ms,arena_bytes\n");
    for ([_]usize{ 1000, 10000, 50000 }) |count| {
        var fixtures = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer fixtures.deinit();
        const a = fixtures.allocator();
        const paths = try a.alloc([]const u8, count);
        for (paths, 0..) |*path, i| path.* = try std.fmt.allocPrint(a, "/wallpapers/collection/wallpaper-{d:0>6}.jpg", .{i});
        for ([_]usize{ count / 2, count }) |seen_count| {
            var samples: [3]f64 = undefined;
            var capacity: usize = 0;
            for (&samples) |*sample| {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                var s = state.State{ .seen = paths[0..seen_count], .excluded = paths[0 .. count / 10] };
                const start = std.Io.Timestamp.now(rt.io, .awake);
                const chosen = try s.choose(rt, arena.allocator(), "default", paths);
                std.mem.doNotOptimizeAway(chosen.ptr);
                sample.* = @as(f64, @floatFromInt(start.durationTo(std.Io.Timestamp.now(rt.io, .awake)).toNanoseconds())) / std.time.ns_per_ms;
                capacity = arena.queryCapacity();
            }
            std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
            try std.Io.File.stdout().writeStreamingAll(rt.io, try std.fmt.allocPrint(a, "{d},{s},{d:.3},{d}\n", .{ count, if (seen_count == count) "cycle_end" else "half_seen", samples[1], capacity }));
        }
    }
}
