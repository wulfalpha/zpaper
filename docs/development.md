# Development

`zig build test` covers parsing, layout branching, shuffle invariants, schedule
boundaries, and daylight-saving transitions. The scheduler takes explicit civil
time values; the engine also accepts an injected timestamp for tests. Production
does not expose a test clock through environment variables or the socket API.
`python3 tests/integration.py` drives the built executable with fake backends and
isolated HOME/XDG directories. It requires permission to create local Unix sockets;
it never changes the real desktop. Override `ZPAPER_BIN` to test another build.

Core modules use request-scoped arenas. The daemon owns configuration separately
and releases each request/timer arena, keeping memory bounded over its lifetime.

## Architecture

`policy.zig` takes configuration, recorded state, explicit wall/civil time, and
backend targeting capability. It resolves output collections, evaluates schedule
actions, and plans image/rotation targets without accessing files, launching
processes, or mutating state. `schedule.zig` supplies the daily timetable and DST
cursor rules. `explain.zig` formats the same policy as text or JSON.

`engine.zig` obtains backend facts, collects and chooses images, applies plans,
and commits successful changes to history, shuffle progress, and timers. Failed
outputs retain their recorded images; total failures roll back tentative choices.
The daemon and IPC lifecycle remain in `main.zig`. Policy unit tests use explicit
time; integration tests verify application and partial-failure behavior.

## Toolchain

Use **Zig 0.16.0**. The build links system libc for local timezone/DST conversion
and uses Zig's LLVM/LLD backend. See [the 0.16 migration notes](MIGRATING-0.16.md)
for implementation details. The version string comes from `build.zig.zon`.

```sh
zig build test
zig build -Doptimize=ReleaseSafe
python3 tests/integration.py
```

## Releasing

1. Update `.version` in `build.zig.zon` and add a matching `## X.Y.Z` section to
   `CHANGELOG.md`. Update the install snippet in `README.md` to the same version.
2. Commit and push, then tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.

The release workflow checks that the tag and README install version match
`build.zig.zon`, builds ReleaseSafe binaries for x86_64 and aarch64 against glibc
2.31 on native runners, runs the unit
and integration tests against them, and publishes the archives, `SHA256SUMS`, and
the changelog section as release notes.

