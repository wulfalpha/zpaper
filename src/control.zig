//! Responsive socket frontend. The daemon thread remains the only state writer.
//! Jobs cross to that worker through a bounded FIFO; status uses owned snapshots.
const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const engine = @import("engine.zig");
const platform = @import("platform.zig");
const ipc = @import("ipc.zig");
const u = @import("util.zig");
pub const Response = struct { ok: bool, message: []const u8 };
const Phase = enum(u8) { reading, queued, working, writing, closed };
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    stream: std.Io.net.Stream,
    request: engine.Request = .{},
    phase: std.atomic.Value(Phase) = .init(.reading),
    input: std.ArrayList(u8) = .empty,
    output: []const u8 = "",
    sent: usize = 0,
    since: std.Io.Timestamp,
    pub fn allocator(self: *Job) u.A {
        return self.arena.allocator();
    }
};
pub const Control = struct {
    rt: Runtime,
    server: *std.Io.net.Server,
    cfg_path: []const u8,
    validate: *const fn (engine.Request) anyerror!void,
    stopping: *std.atomic.Value(bool),
    restarting: *std.atomic.Value(bool),
    finishing: std.atomic.Value(bool) = .init(false),
    busy: std.atomic.Value(bool) = .init(true),
    starting: std.atomic.Value(bool) = .init(true),
    mutex: std.Io.Mutex = .init,
    queue: [16]*Job = undefined,
    queued: usize = 0,
    clients: std.ArrayList(*Job) = .empty,
    snapshot_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    status_text: Response = .{ .ok = true, .message = "daemon: starting\n" },
    status_json: Response,
    snapshot_time: i64 = 0,
    thread: ?std.Thread = null,

    pub fn start(self: *Control) !void {
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }
    // Called by the worker only after it has stopped touching jobs.
    pub fn deinit(self: *Control) void {
        self.finishing.store(true, .release);
        if (self.thread) |thread| thread.join();
        for (self.clients.items) |job| self.destroy(job);
        self.clients.deinit(std.heap.page_allocator);
        self.snapshot_arena.deinit();
    }
    fn destroy(self: *Control, job: *Job) void {
        job.stream.close(self.rt.io);
        job.arena.deinit();
        std.heap.page_allocator.destroy(job);
    }
    pub fn take(self: *Control) ?*Job {
        self.mutex.lockUncancelable(self.rt.io);
        defer self.mutex.unlock(self.rt.io);
        if (self.queued == 0 or self.stopping.load(.acquire)) return null;
        const job = self.queue[0];
        self.queued -= 1;
        std.mem.copyForwards(*Job, self.queue[0..self.queued], self.queue[1 .. self.queued + 1]);
        job.phase.store(.working, .release);
        return job;
    }
    pub fn complete(self: *Control, job: *Job, response: Response) void {
        const bytes = std.json.Stringify.valueAlloc(job.allocator(), response, .{}) catch {
            job.output = "{\"ok\":false,\"message\":\"OutOfMemory\\n\"}\n";
            job.since = std.Io.Timestamp.now(self.rt.io, .awake);
            job.phase.store(.writing, .release);
            return;
        };
        job.output = std.fmt.allocPrint(job.allocator(), "{s}\n", .{bytes}) catch "{\"ok\":false,\"message\":\"OutOfMemory\\n\"}\n";
        job.since = std.Io.Timestamp.now(self.rt.io, .awake);
        job.phase.store(.writing, .release);
    }
    pub fn publish(self: *Control, text: Response, json: Response) void {
        self.mutex.lockUncancelable(self.rt.io);
        defer self.mutex.unlock(self.rt.io);
        _ = self.snapshot_arena.reset(.free_all);
        const a = self.snapshot_arena.allocator();
        self.status_text = .{ .ok = text.ok, .message = a.dupe(u8, text.message) catch "OutOfMemory\n" };
        self.status_json = .{ .ok = json.ok, .message = a.dupe(u8, json.message) catch "{}\n" };
        self.snapshot_time = @import("clock.zig").now(self.rt);
    }
    fn status(self: *Control, job: *Job) !Response {
        self.mutex.lockUncancelable(self.rt.io);
        defer self.mutex.unlock(self.rt.io);
        const snapshot = if (job.request.json) self.status_json else self.status_text;
        const busy = self.busy.load(.acquire);
        const starting = self.starting.load(.acquire);
        const message = if (job.request.json and snapshot.ok and std.mem.startsWith(u8, snapshot.message, "{"))
            try std.fmt.allocPrint(job.allocator(), "{{\"busy\":{},\"starting\":{},\"snapshot_time\":{d},{s}", .{ busy, starting, self.snapshot_time, snapshot.message[1..] })
        else if (!job.request.json)
            try std.fmt.allocPrint(job.allocator(), "{s}worker: {s}; snapshot at {d}\n", .{ snapshot.message, if (starting) "starting" else if (busy) "busy" else "idle", self.snapshot_time })
        else
            try job.allocator().dupe(u8, snapshot.message);
        return .{ .ok = snapshot.ok, .message = message };
    }
    fn dispatch(self: *Control, job: *Job, bytes: []const u8) !void {
        u.diagnostic = "";
        defer u.diagnostic = "";
        const a = job.allocator();
        job.request = try std.json.parseFromSliceLeaky(engine.Request, a, bytes, .{ .allocate = .alloc_always });
        try self.validate(job.request);
        if (job.request.config_path) |path| if (!u.eql(path, self.cfg_path)) {
            self.complete(job, .{ .ok = false, .message = "daemon uses a different config; stop it before switching configs\n" });
            return;
        };
        switch (job.request.action) {
            .status => self.complete(job, try self.status(job)),
            .daemon => self.complete(job, .{ .ok = false, .message = "daemon already running\n" }),
            .stop, .restart => {
                // The small acknowledgement fits a fresh socket's send buffer.
                // Send it before releasing the worker to finish shutdown.
                try ipc.send(self.rt, a, job.stream.socket.handle, Response{ .ok = true, .message = if (job.request.action == .restart) "daemon restarting\n" else "daemon stopping\n" });
                if (job.request.action == .restart) self.restarting.store(true, .release);
                self.stopping.store(true, .release);
                job.phase.store(.closed, .release);
            },
            else => {
                self.mutex.lockUncancelable(self.rt.io);
                defer self.mutex.unlock(self.rt.io);
                if (self.stopping.load(.acquire)) {
                    self.complete(job, .{ .ok = false, .message = "daemon is stopping\n" });
                } else if (self.queued == self.queue.len) {
                    self.complete(job, .{ .ok = false, .message = "daemon request queue is full; try again later\n" });
                } else {
                    self.queue[self.queued] = job;
                    self.queued += 1;
                    job.phase.store(.queued, .release);
                }
            },
        }
    }
    fn service(self: *Control, job: *Job) void {
        const phase = job.phase.load(.acquire);
        if (phase != .reading and phase != .writing) return;
        if (job.since.durationTo(std.Io.Timestamp.now(self.rt.io, .awake)).toNanoseconds() >= 5 * std.time.ns_per_s) {
            job.phase.store(.closed, .release);
            return;
        }
        if (phase == .writing) {
            const n = platform.send(job.stream.socket.handle, job.output[job.sent..]) catch |err| {
                if (err != error.WouldBlock) job.phase.store(.closed, .release);
                return;
            };
            job.sent += n;
            if (n == 0 or job.sent == job.output.len) job.phase.store(.closed, .release);
            return;
        }
        var buf: [8192]u8 = undefined;
        const n = platform.receive(job.stream.socket.handle, &buf) catch |err| {
            if (err != error.WouldBlock) job.phase.store(.closed, .release);
            return;
        };
        if (n == 0 or job.input.items.len + n > 1024 * 1024) {
            job.phase.store(.closed, .release);
            return;
        }
        job.input.appendSlice(job.allocator(), buf[0..n]) catch {
            job.phase.store(.closed, .release);
            return;
        };
        if (std.mem.indexOfScalar(u8, job.input.items, '\n')) |end| {
            self.dispatch(job, job.input.items[0..end]) catch |err| self.complete(job, .{ .ok = false, .message = @errorName(err) });
        }
    }
    fn serve(self: *Control) void {
        while (!self.finishing.load(.acquire)) {
            var poll = [_]platform.pollfd{.{ .fd = self.server.socket.handle, .events = platform.POLL.IN, .revents = 0 }};
            _ = platform.poll(&poll, 20) catch continue;
            if (poll[0].revents & platform.POLL.IN != 0) {
                if (self.server.accept(self.rt.io)) |stream| {
                    if (self.clients.items.len >= 64) {
                        stream.close(self.rt.io);
                    } else if (std.heap.page_allocator.create(Job)) |job| {
                        job.* = .{ .arena = .init(std.heap.page_allocator), .stream = stream, .since = std.Io.Timestamp.now(self.rt.io, .awake) };
                        self.clients.append(std.heap.page_allocator, job) catch self.destroy(job);
                    } else |_| stream.close(self.rt.io);
                } else |_| {}
            }
            var i: usize = 0;
            while (i < self.clients.items.len) {
                const job = self.clients.items[i];
                self.service(job);
                if (job.phase.load(.acquire) == .closed) {
                    self.destroy(job);
                    _ = self.clients.swapRemove(i);
                } else i += 1;
            }
        }
    }
};
