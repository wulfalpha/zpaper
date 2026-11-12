const std = @import("std");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const u = @import("util.zig");
const clock = @import("clock.zig");
const config = @import("config.zig");
const state = @import("state.zig");
const engine = @import("engine.zig");
const platform = @import("platform.zig");
const ipc = @import("ipc.zig");
const Request = engine.Request;
const version = @import("build_options").version;
const Response = struct { ok: bool, message: []const u8 };
var stopping = std.atomic.Value(bool).init(false);
// Set by a `restart` request: after a clean shutdown, main() re-executes.
var restarting = std.atomic.Value(bool).init(false);
var force_next = std.atomic.Value(bool).init(false);
fn signal(sig: platform.SIG) callconv(.c) void {
    if (sig == platform.SIG.USR1) force_next.store(true, .release) else stopping.store(true, .release);
}
const help = "zpaper " ++ version ++ " — wallpaper rotation with memory\n" ++
    \\Usage: zpaper [--config PATH] COMMAND [ARGS] [--output NAME[,NAME]]
    \\
    \\  daemon                    Run in foreground (use a service or your WM)
    \\  set IMAGE [IMAGE...]      One image everywhere, or images by sorted output
    \\  next | previous          Browse layouts; next shuffles at the end
    \\  hold [DURATION]           Pause rotation indefinitely or for e.g. 2h
    \\  resume                    Release holds and restart the rotation timer
    \\  current | status          Query the backend / show recorded daemon state
    \\  history | layouts         Image history / desktop layout timeline
    \\  search TEXT | select N    Search image paths / apply history entry
    \\  favorite [IMAGE...]       Favorite current image(s) or explicit paths
    \\  unfavorite [IMAGE...]     Remove favorites
    \\  favorites | random-favorite
    \\  exclude [IMAGE...] | include [IMAGE...]
    \\  collections               List collections (* marks the active one)
    \\  use NAME                  Switch collection until the next schedule change
    \\  schedule [resume]         Inspect schedules / return to them (respecting holds)
    \\  list [NAME]               List images in the active or named collection
    \\  restore | refresh         Reapply saved layout, or choose if none saved
    \\  import-legacy [DIR]       Import script history/favorites (default ~/.cache)
    \\  clear-history             Clear image history and layout navigation
    \\  reload | stop             Reload config / stop the daemon (waits until it exits)
    \\  restart                   Restart the daemon, picking up a newly installed binary
    \\  check                     Validate configuration without setting wallpaper
    \\
    \\--json: current, status, history, layouts, favorites, list, collections, schedule.
    \\--output: set, next, hold, resume, select, favorite/unfavorite, exclude/include,
    \\          random-favorite, schedule resume. Needs awww, swww, or feh with xrandr.
    \\Legacy --next, --undo, --history, --favorite, etc. remain aliases.
    \\No command means 'next', or 'daemon' when daemon=true in config.
    \\interval=0 disables automatic rotation; daemon runs in the foreground.
    \\Config: ~/.config/zpaper/zpaperc. State: $XDG_STATE_HOME/zpaper/state.json.
    \\Requires Zig 0.16.0 to build. Linux only.
    \\
;
const ParsedRequest = struct { request: Request, implicit: bool };
fn parse(rt: Runtime, a: u.A, argv: []const []const u8) !?ParsedRequest {
    var req = Request{};
    var chosen = false;
    var operands: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    var literal = false;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!literal and u.eql(arg, "--")) {
            literal = true;
            continue;
        }
        if (!literal and (u.eql(arg, "--help") or u.eql(arg, "-h"))) {
            try std.Io.File.stdout().writeStreamingAll(rt.io, help);
            return null;
        }
        if (!literal and u.eql(arg, "--version")) {
            try std.Io.File.stdout().writeStreamingAll(rt.io, "zpaper " ++ version ++ "\n");
            return null;
        }
        if (!literal and (u.eql(arg, "--config") or u.eql(arg, "--output") or u.eql(arg, "--outputs") or u.eql(arg, "-o"))) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            if (u.eql(arg, "--config")) {
                req.config_path = try u.absolute(rt, a, argv[i]);
            } else {
                req.output = argv[i];
            }
            continue;
        }
        if (!literal and u.eql(arg, "--json")) {
            req.json = true;
            continue;
        }
        if (!literal and (!chosen or std.mem.startsWith(u8, arg, "--"))) {
            var name = if (std.mem.startsWith(u8, arg, "--")) arg[2..] else arg;
            if (u.eql(name, "undo")) name = "previous";
            if (u.eql(name, "restore-or-random") or u.eql(name, "refresh")) name = "restore";
            const normalized = try a.dupe(u8, name);
            for (normalized) |*c| if (c.* == '-') {
                c.* = '_';
            };
            if (std.meta.stringToEnum(engine.Action, normalized)) |action| {
                if (chosen) return error.MultipleCommands;
                req.action = action;
                chosen = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) return u.fail(a, "unknown option: {s}", .{arg});
            if (!chosen) return u.fail(a, "unknown command: {s}; see --help", .{arg});
        }
        try operands.append(a, arg);
    }
    req.args = try operands.toOwnedSlice(a);
    try validate(req);
    switch (req.action) {
        .set, .favorite, .unfavorite, .exclude, .include, .import_legacy => {
            const paths = try a.alloc([]const u8, req.args.len);
            for (req.args, 0..) |path, n| paths[n] = try u.absolute(rt, a, path);
            req.args = paths;
        },
        else => {},
    }
    return .{ .request = req, .implicit = !chosen };
}
fn validate(req: Request) !void {
    const count = req.args.len;
    switch (req.action) {
        .set => if (count == 0 or count > 32) return error.ExpectedImagePaths,
        .search, .select, .use => if (count != 1) return error.ExpectedOneArgument,
        .hold, .import_legacy, .list, .schedule => if (count > 1) return error.TooManyArguments,
        .favorite, .unfavorite, .exclude, .include => {},
        else => if (count != 0) return error.UnexpectedArgument,
    }
    if (req.action == .schedule and count == 1 and !u.eql(req.args[0], "resume")) return error.ExpectedScheduleResume;
    if (req.action == .schedule and count == 1 and req.json) return error.JsonNotApplicable;
    if (req.action == .schedule and count == 0 and req.output != null) return error.OutputNotApplicable;
    if (req.output != null) switch (req.action) {
        .set, .next, .hold, .@"resume", .select, .favorite, .unfavorite, .exclude, .include, .random_favorite, .schedule => {},
        else => return error.OutputNotApplicable,
    };
    if (req.json) switch (req.action) {
        .current, .status, .history, .layouts, .favorites, .list, .collections, .schedule => {},
        else => return error.JsonNotApplicable,
    };
}
fn errorResponse(a: u.A, err: anyerror) Response {
    return .{ .ok = false, .message = std.fmt.allocPrint(a, "{s}\n", .{if (u.diagnostic.len > 0) u.diagnostic else @errorName(err)}) catch "OutOfMemory\n" };
}
fn execute(rt: Runtime, a: u.A, cfg: config.Config, paths: ipc.Paths, req: Request, daemon: bool, manual: bool) Response {
    u.diagnostic = "";
    validate(req) catch |err| return errorResponse(a, err);
    var e = engine.Engine{ .rt = rt, .a = a, .cfg = cfg, .state = state.load(rt, a, paths.state) catch |err| return errorResponse(a, err), .daemon = daemon };
    var ok = true;
    e.execute(req) catch |err| {
        ok = false;
        e.print("{s}\n", .{if (u.diagnostic.len > 0) u.diagnostic else @errorName(err)}) catch {};
    };
    if (manual) e.rememberManualChoice(req.action) catch |err| {
        e.print("schedule override: {s}\n", .{@errorName(err)}) catch {};
        ok = false;
    };
    if (e.dirty) state.save(rt, a, paths.state, e.state) catch |err| {
        e.print("state save failed: {s}; displayed wallpaper may already have changed\n", .{@errorName(err)}) catch {};
        ok = false;
    };
    return .{ .ok = ok, .message = e.message.items };
}
fn emit(rt: Runtime, response: Response) !void {
    try (if (response.ok) std.Io.File.stdout() else std.Io.File.stderr()).writeStreamingAll(rt.io, response.message);
}
fn client(rt: Runtime, a: u.A, stream: std.Io.net.Stream, req: Request) !bool {
    defer stream.close(rt.io);
    const fd = stream.socket.handle;
    try ipc.send(rt, a, fd, req);
    const bytes = ipc.receive(rt, a, fd, 300) catch |err| return u.fail(a, "daemon response: {s}; the request may still be running", .{@errorName(err)});
    const response = try std.json.parseFromSliceLeaky(Response, a, bytes, .{});
    try emit(rt, response);
    return response.ok;
}
fn daemonLoop(rt: Runtime, a: u.A, paths: ipc.Paths, cfg_path: []const u8, required: bool) !void {
    var cfg_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer cfg_arena.deinit();
    // Preserve startup diagnostics before freeing the config arena.
    errdefer u.diagnostic = a.dupe(u8, u.diagnostic) catch "";
    var cfg = try config.load(rt, cfg_arena.allocator(), cfg_path, required);
    var server = try ipc.listen(rt, paths.socket);
    defer server.deinit(rt.io);
    const fd = server.socket.handle;
    defer std.Io.Dir.deleteFileAbsolute(rt.io, paths.socket) catch {};
    platform.signals(signal);
    try std.Io.File.stderr().writeStreamingAll(rt.io, "zpaper daemon ready\n");
    // Reconcile the current scheduled period first, without replaying missed
    // periods. Startup restoration must not create a manual schedule override.
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer {
            u.diagnostic = "";
            arena.deinit();
        }
        const startup_a = arena.allocator();
        const initial = try state.load(rt, startup_a, paths.state);
        var e = engine.Engine{ .rt = rt, .a = startup_a, .cfg = cfg, .state = initial, .daemon = true };
        const handled = e.applySchedule() catch |err| blk: {
            std.log.err("schedule: {s}", .{if (u.diagnostic.len > 0) u.diagnostic else @errorName(err)});
            break :blk true;
        };
        if (e.message.items.len > 0) try std.Io.File.stderr().writeStreamingAll(rt.io, e.message.items);
        if (e.dirty) try state.save(rt, startup_a, paths.state, e.state);
        const active = cfg.effective(cfg.selectedName(e.state.collection)) catch {
            try std.Io.File.stderr().writeStreamingAll(rt.io, try std.fmt.allocPrint(startup_a, "saved collection '{s}' is not defined; run 'zpaper use NAME' before starting the daemon\n", .{cfg.selectedName(e.state.collection)}));
            return error.UnknownCollection;
        };
        if (!e.wallpaper_applied and initial.current.len > 0) {
            try emit(rt, execute(rt, startup_a, cfg, paths, .{ .action = .restore }, true, false));
        } else if (!handled and initial.next_due == 0 and active.interval > 0) {
            var next = initial;
            next.next_due = clock.now(rt);
            try state.save(rt, startup_a, paths.state, next);
        }
    }
    var retry_at: i64 = 0;
    var schedule_retry_at: i64 = 0;
    var output_schedule_retry_at: i64 = 0;
    // Connected outputs from the last hotplug check, kept across ticks.
    var outputs_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer outputs_arena.deinit();
    var known_outputs: ?[]const []const u8 = null;
    var hotplug_at: i64 = 0;
    var assigned_retry_at: i64 = 0;
    while (!stopping.load(.acquire)) {
        var poll = [_]platform.pollfd{.{ .fd = fd, .events = platform.POLL.IN, .revents = 0 }};
        _ = try platform.poll(&poll, 500);
        if (poll[0].revents & platform.POLL.IN != 0) {
            const stream = server.accept(rt.io) catch continue;
            defer stream.close(rt.io);
            const peer = stream.socket.handle;
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer {
                u.diagnostic = "";
                arena.deinit();
            }
            const request_a = arena.allocator();
            u.diagnostic = "";
            const bytes = ipc.receive(rt, request_a, peer, 5) catch continue;
            const req = std.json.parseFromSliceLeaky(Request, request_a, bytes, .{ .allocate = .alloc_always }) catch |err| {
                ipc.send(rt, request_a, peer, errorResponse(request_a, err)) catch {};
                continue;
            };
            const response: Response = blk: {
                validate(req) catch |err| break :blk errorResponse(request_a, err);
                if (req.config_path) |override| {
                    if (!u.eql(override, cfg_path)) break :blk .{ .ok = false, .message = "daemon uses a different config; stop it before switching configs\n" };
                }
                switch (req.action) {
                    .daemon => break :blk .{ .ok = false, .message = "daemon already running\n" },
                    .stop => {
                        stopping.store(true, .release);
                        break :blk .{ .ok = true, .message = "daemon stopping\n" };
                    },
                    .restart => {
                        restarting.store(true, .release);
                        stopping.store(true, .release);
                        break :blk .{ .ok = true, .message = "daemon restarting\n" };
                    },
                    .reload => {
                        var replacement = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                        const updated = config.load(rt, replacement.allocator(), cfg_path, true) catch |err| {
                            const response = errorResponse(request_a, err);
                            // Diagnostic may have been allocated in replacement.
                            const message = try request_a.dupe(u8, response.message);
                            replacement.deinit();
                            break :blk .{ .ok = false, .message = message };
                        };
                        var s = state.load(rt, request_a, paths.state) catch |err| {
                            replacement.deinit();
                            break :blk errorResponse(request_a, err);
                        };
                        const selected = updated.selectedName(s.collection);
                        const active = updated.effective(selected) catch {
                            const message = try std.fmt.allocPrint(request_a, "reload would remove active collection '{s}'; use another collection first\n", .{selected});
                            replacement.deinit();
                            break :blk .{ .ok = false, .message = message };
                        };
                        s.next_due = if (active.interval == 0) 0 else clock.now(rt) + @as(i64, @intCast(active.interval));
                        state.save(rt, request_a, paths.state, s) catch |err| {
                            replacement.deinit();
                            break :blk errorResponse(request_a, err);
                        };
                        // Runs before the old configuration is freed.
                        var e = engine.Engine{ .rt = rt, .a = request_a, .cfg = updated, .state = s, .daemon = true };
                        e.reassign(cfg) catch |err| {
                            e.print("reassign: {s}\n", .{if (u.diagnostic.len > 0) u.diagnostic else @errorName(err)}) catch {};
                        };
                        if (e.dirty) state.save(rt, request_a, paths.state, e.state) catch |err| {
                            e.print("state save failed: {s}\n", .{@errorName(err)}) catch {};
                        };
                        const message = try std.fmt.allocPrint(request_a, "configuration reloaded\n{s}", .{e.message.items});
                        cfg_arena.deinit();
                        cfg_arena = replacement;
                        cfg = updated;
                        retry_at = 0;
                        schedule_retry_at = 0;
                        output_schedule_retry_at = 0;
                        break :blk .{ .ok = true, .message = message };
                    },
                    .check => break :blk .{ .ok = true, .message = "active configuration is valid\n" },
                    else => break :blk execute(rt, request_a, cfg, paths, req, true, true),
                }
            };
            ipc.send(rt, request_a, peer, response) catch {};
        }
        if (stopping.load(.acquire)) break;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer {
            u.diagnostic = "";
            arena.deinit();
        }
        const tick_a = arena.allocator();
        u.diagnostic = "";
        const s = state.load(rt, tick_a, paths.state) catch |err| {
            std.log.err("state: {s}", .{@errorName(err)});
            continue;
        };
        const forced = force_next.swap(false, .acq_rel);
        const now = clock.now(rt);
        var e = engine.Engine{ .rt = rt, .a = tick_a, .cfg = cfg, .state = s, .daemon = true };
        var scheduled = false;
        if (!forced and now >= schedule_retry_at) {
            scheduled = e.applySchedule() catch |err| blk: {
                std.log.err("schedule: {s}", .{if (u.diagnostic.len > 0) u.diagnostic else @errorName(err)});
                schedule_retry_at = now + 5;
                break :blk true;
            };
            if (scheduled and !e.dirty) schedule_retry_at = now + 5;
        } else if (!forced and now < schedule_retry_at) {
            scheduled = true;
        }
        // Per-monitor schedules never block the active collection's rotation.
        if (now >= output_schedule_retry_at) e.applyOutputSchedules() catch |err| {
            std.log.err("schedule: {s}", .{if (u.diagnostic.len > 0) u.diagnostic else @errorName(err)});
            u.diagnostic = "";
            output_schedule_retry_at = now + 5;
        };
        if (cfg.hotplug and now >= hotplug_at) {
            if (e.reconcile(known_outputs)) |names| {
                var replacement = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                const copy = replacement.allocator().alloc([]const u8, names.len) catch null;
                if (copy) |slots| {
                    for (names, slots) |name, *slot| slot.* = replacement.allocator().dupe(u8, name) catch "";
                    outputs_arena.deinit();
                    outputs_arena = replacement;
                    known_outputs = slots;
                } else replacement.deinit();
                hotplug_at = now + 2;
            } else |err| {
                if (err != error.QueryUnsupported) std.log.err("hotplug: {s}", .{if (u.diagnostic.len > 0) u.diagnostic else @errorName(err)});
                u.diagnostic = "";
                hotplug_at = now + 15;
            }
        }
        const active = cfg.effective(cfg.selectedName(e.state.collection)) catch continue;
        if (now >= assigned_retry_at) {
            const stalled = e.rotateDue() catch |err| blk: {
                std.log.err("rotation: {s}", .{if (u.diagnostic.len > 0) u.diagnostic else @errorName(err)});
                break :blk true;
            };
            if (stalled) assigned_retry_at = now + 5;
        }
        if (forced or (!scheduled and active.interval > 0 and now >= e.state.next_due and now >= retry_at)) {
            (if (forced) e.rotate(false, null) else e.rotateActive(true)) catch |err| {
                std.log.err("rotation: {s}", .{if (u.diagnostic.len > 0) u.diagnostic else @errorName(err)});
            };
            if (forced) try e.rememberManualChoice(.next);
            retry_at = now + (if (e.dirty) @as(i64, 1) else 5);
        }
        if (e.message.items.len > 0) try std.Io.File.stderr().writeStreamingAll(rt.io, e.message.items);
        if (e.dirty) state.save(rt, tick_a, paths.state, e.state) catch |err| {
            std.log.err("state save: {s}", .{@errorName(err)});
        };
    }
}
fn run(rt: Runtime, a: u.A, argv: []const []const u8) !bool {
    const parsed = (try parse(rt, a, argv)) orelse return true;
    var req = parsed.request;
    const cfg_path = req.config_path orelse try u.absolute(rt, a, try config.getConfigPath(rt, a));
    if (req.action == .check) {
        const checked = try config.load(rt, a, cfg_path, true);
        try std.Io.File.stdout().writeStreamingAll(rt.io, "configuration is valid\n");
        var probe = engine.Engine{ .rt = rt, .a = a, .cfg = checked, .state = .{} };
        if (probe.outputsIgnored()) |note| try std.Io.File.stdout().writeStreamingAll(rt.io, try std.fmt.allocPrint(a, "{s}\n", .{note}));
        return true;
    }
    // Only an omitted command consults the startup default. Explicit commands
    // can still reach the daemon when the on-disk config needs repair.
    const default_cfg: ?config.Config = if (parsed.implicit) try config.load(rt, a, cfg_path, req.config_path != null) else null;
    if (default_cfg) |cfg| if (cfg.daemon) {
        req.action = .daemon;
        try validate(req);
    };
    const paths = try ipc.paths(rt, a, try u.absolute(rt, a, try config.getDataDir(rt, a)));
    if (try ipc.connect(rt, paths.socket)) |fd| return clientAndWait(rt, a, fd, req, paths);
    if (req.action == .restart) return startDaemon(rt, a, paths, req.config_path);
    const owner = ipc.lock(rt, paths.lock) catch |err| {
        if (err == error.WouldBlock) {
            for (0..20) |_| {
                try rt.sleep(100);
                if (try ipc.connect(rt, paths.socket)) |fd| return clientAndWait(rt, a, fd, req, paths);
            }
            return u.fail(a, "another zpaper command owns the state; try again when it completes", .{});
        }
        return err;
    };
    defer owner.close(rt.io);
    if (req.action == .daemon) {
        try daemonLoop(rt, a, paths, cfg_path, req.config_path != null);
        return true;
    }
    if (req.action == .stop or req.action == .reload) return u.fail(a, "daemon is not running", .{});
    const cfg = default_cfg orelse try config.load(rt, a, cfg_path, req.config_path != null);
    const response = execute(rt, a, cfg, paths, req, false, true);
    try emit(rt, response);
    return response.ok;
}
// `stop` returns once the daemon has released the owner lock, so a new daemon
// can start right away; `restart` returns once the new daemon answers.
fn clientAndWait(rt: Runtime, a: u.A, stream: std.Io.net.Stream, req: Request, paths: ipc.Paths) !bool {
    if (!try client(rt, a, stream, req)) return false;
    switch (req.action) {
        .stop => {
            for (0..100) |_| {
                if (ipc.lock(rt, paths.lock)) |f| {
                    f.close(rt.io);
                    try std.Io.File.stdout().writeStreamingAll(rt.io, "daemon stopped\n");
                    return true;
                } else |err| if (err != error.WouldBlock) return err;
                try rt.sleep(100);
            }
            return u.fail(a, "daemon did not stop within 10s", .{});
        },
        .restart => return waitForDaemon(rt, a, paths, "restarted"),
        else => return true,
    }
}
// Poll until a daemon answers `status`, then report its version.
fn waitForDaemon(rt: Runtime, a: u.A, paths: ipc.Paths, verb: []const u8) !bool {
    for (0..100) |_| {
        try rt.sleep(100);
        const stream = (try ipc.connect(rt, paths.socket)) orelse continue;
        defer stream.close(rt.io);
        const fd = stream.socket.handle;
        ipc.send(rt, a, fd, Request{ .action = .status, .json = true }) catch continue;
        const bytes = ipc.receive(rt, a, fd, 2) catch continue;
        const response = std.json.parseFromSliceLeaky(Response, a, bytes, .{}) catch continue;
        if (!response.ok) continue;
        const Status = struct { version: []const u8 = "unknown" };
        const status = std.json.parseFromSliceLeaky(Status, a, response.message, .{ .ignore_unknown_fields = true }) catch continue;
        try std.Io.File.stdout().writeStreamingAll(rt.io, try std.fmt.allocPrint(a, "daemon {s} (zpaper {s})\n", .{ verb, status.version }));
        return true;
    }
    return u.fail(a, "daemon did not answer within 10s; check `zpaper status`", .{});
}
// `restart` without a running daemon starts one in the background, detached
// from this terminal, with this command's environment.
fn startDaemon(rt: Runtime, a: u.A, paths: ipc.Paths, config_path: ?[]const u8) !bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "setsid", "-f", try selfExe(rt, &buf) });
    if (config_path) |path| try argv.appendSlice(a, &.{ "--config", path });
    try argv.append(a, "daemon");
    try u.runLogged(rt, a, argv.items, 5, "/dev/null");
    return waitForDaemon(rt, a, paths, "started");
}
// The binary now installed at this process's path. After an upgrade the
// kernel reports the replaced file as "PATH (deleted)".
fn selfExe(rt: Runtime, buf: []u8) ![]const u8 {
    const n = try std.Io.Dir.readLinkAbsolute(rt.io, "/proc/self/exe", buf);
    const suffix = " (deleted)";
    return if (std.mem.endsWith(u8, buf[0..n], suffix)) buf[0 .. n - suffix.len] else buf[0..n];
}
// Replace this process with a fresh daemon: same arguments, environment
// (the session's display variables), and process ID.
fn reexec(rt: Runtime, a: u.A, args: []const [:0]const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const argv = a.alloc([]const u8, args.len) catch return;
    argv[0] = selfExe(rt, &buf) catch |err| {
        std.log.err("restart: {s}", .{@errorName(err)});
        return;
    };
    for (args[1..], argv[1..]) |arg, *slot| slot.* = arg;
    const err = std.process.replace(rt.io, .{ .argv = argv });
    std.log.err("restart: cannot execute {s}: {s}", .{ argv[0], @errorName(err) });
}
pub fn main(init: std.process.Init) void {
    const rt: Runtime = .{ .io = init.io, .environ = init.minimal.environ };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const args = init.minimal.args.toSlice(arena.allocator()) catch {
        std.process.exit(1);
    };
    const ok = run(rt, arena.allocator(), args) catch |err| blk: {
        emit(rt, errorResponse(arena.allocator(), err)) catch {};
        break :blk false;
    };
    if (restarting.load(.acquire)) {
        reexec(rt, arena.allocator(), args);
        std.process.exit(1);
    }
    arena.deinit();
    if (!ok) std.process.exit(1);
}
test {
    _ = @import("config.zig");
    _ = @import("state.zig");
    _ = @import("backend.zig");
    _ = @import("util.zig");
    _ = @import("schedule.zig");
    _ = @import("clock.zig");
    _ = @import("engine.zig");
}
