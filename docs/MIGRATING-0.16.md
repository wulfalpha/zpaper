# Zig 0.16 migration notes

zpaper 0.5.0 targets Zig **0.16.0**. CLI commands, configuration, collections,
scheduling, and state schema v3 retain their existing semantics. Saved v1 and v2
state is still accepted and upgraded on the next write. There is no parallel
0.15 compatibility layer.

## Runtime and I/O

`main` accepts `std.process.Init`. Arguments come from `Args.toSlice`, and
`runtime.zig` passes the supplied `std.Io` and process environment explicitly to
operations that need them. Configuration reloads, requests, and daemon ticks keep
separate arenas backed by the page allocator; they do not accumulate allocations
in the startup arena.

File access, directory iteration, atomic file replacement, file synchronization,
and owner locks use `std.Io.File` and `std.Io.Dir`. State writes still use an
exclusive 0600 temporary file, sync it, rename it, and sync its containing
directory. Runtime directories still reject symlinks, incorrect ownership, and
permissions that allow access by other users.

`clock.zig` uses the real I/O clock for persisted timestamps and deadlines.
Subprocess and IPC timeouts use the monotonic `awake` clock. Local time conversion
continues to use libc `localtime_r`/`tzset`, including DST transitions. The pure
schedule policy remains independent of runtime I/O.

The build links libc and explicitly uses LLVM/LLD, which handles the `.sframe`
relocations in the local system's CRT objects. The platform C import disables
glibc's fortified inline wrappers for header translation: translate-c rejects
their variadic fcntl checks in optimized builds. The wrapper calls use the
underlying libc declarations with explicit buffer lengths and argument types.

## Linux boundary and toolchain workarounds

`platform.zig` contains descriptor polling, signals, process-group termination,
nonblocking child reaping, directory ownership checks, and directory fsync.
Polling drains both subprocess output pipes with a 1 MiB limit per stream and a
single deadline covering both child exit and pipe EOF. A parent closing its pipes
cannot bypass the deadline; descendants holding pipes open cannot prevent timeout
cleanup. Failed runs kill the process group and reap the direct child.

The socket listener and accepted streams use `std.Io.net.UnixAddress`/`Server`.
JSON framing, size limits, partial reads/writes, and peer deadlines are preserved.
There are two narrow workarounds for the installed 0.16 standard library:

- `UnixAddress.connect` maps `ECONNREFUSED` to `Unexpected`. The Linux connection
  wrapper distinguishes refused/missing endpoints from other errors so stale
  socket recovery remains possible without hiding permission failures.
- `Io.Threaded.processSpawnPosix` returns execution errors without closing the
  captured pipes or reaping the failed child. A regression test reproduced eight
  unreaped children after eight missing-backend requests. The Linux spawn wrapper
  uses libc `posix_spawnp` with explicit file actions and a new process group. It
  returns normal `std.process.Child`/`Io.File` resources, and cleans up on spawn
  errors. This also handles missing interpreters and permission failures without
  a racy executable preflight check.

Revisit these wrappers when upgrading Zig; remove them only when the equivalent
standard-library behavior passes the regression tests.

## Verification

Validated locally with Zig 0.16.0: 14 unit tests and 52 integration tests pass
in Debug and ReleaseSafe. The final adapter and execution-failure regressions
also pass in both modes.

```sh
zig build test
zig build
python3 tests/integration.py
zig build test -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
python3 tests/integration.py
```

The integration harness accepts `ZPAPER_BIN` for a candidate built to a separate
prefix. It uses temporary HOME/XDG directories and fake renderers, so tests do not
change the desktop. Unix sockets and subprocesses must be permitted in the test
environment.

Coverage includes state upgrades, independent collection shuffle, layout history,
partial failures, holds, schedule overrides and reloads, missed periods and DST,
stale sockets, single-writer locking across runtime directories, malformed and
fragmented requests, idle peers, and relative/quoted paths. Migration regressions
also exercise simultaneous output-pipe pressure, output limits, closed-pipe hangs,
descendant cleanup, and repeated execution failures without descriptor/child leaks.
