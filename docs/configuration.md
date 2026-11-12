# Configuration and backends

See [zpaperc.example](../zpaperc.example). Unknown keys, duplicates, malformed
booleans, and invalid durations are errors with line numbers. `check` validates
the file on disk; `reload` explicitly replaces the daemon configuration. An invalid
reload leaves the working configuration active. Quoted paths may contain spaces
and `#`; inline comments begin with a whitespace-separated, unquoted `#`.

| Backend | Query actual layout | Target outputs | Scope |
| --- | --- | --- | --- |
| `awww`, `swww` | Yes | Yes | Per-monitor images |
| `feh` | No | No | One image across all screens |
| `custom` | No | No | One image through a user command |

`backend = auto` picks `awww` when installed on Wayland, otherwise `swww`; outside
Wayland it picks `feh`. Explicit selection is available. The built-in Wayland
adapters query the default namespace. Transition/filter arguments are configured
with `transition`; `resize` accepts `crop`, `fit`, `stretch`, or `no`. These renderer
options are not duplicated as zpaper command-line flags. Image format support is
ultimately determined by the renderer.

`setter` selects the custom backend unless an incompatible backend was explicitly
configured. Commands support quoted arguments and backslash escapes, including an
embedded `%s` image placeholder. They are executed directly, **without a shell**.
Custom setters must terminate after applying the image; long-lived programs need
a separate service. Each command has a configurable timeout, and failures include
stderr. `notify` is optional and a missing notification tool does not fail changes.

Disconnected outputs and saved non-image backgrounds are reported as skipped
when restoring a layout; other connected outputs still apply. This release saves
image paths, not solid-color backgrounds or renderer effects. To give a monitor its
own collection, see [Per-monitor collections](collections.md#per-monitor-collections).

## Change hook

`on_change` runs a command after every successful wallpaper change, which is
handy for theming the desktop from the new image:

```ini
on_change = wal -q -i %s
# or: on_change = matugen image %s
```

- `%s` is replaced with the image path and `%o` with the output name (`*` for
  feh and custom setters). If `%s` is absent, the image is appended as the last
  argument. Quoting works like `setter`; no shell is involved, so point it at a
  script if you need pipes or several commands.
- It runs **once per change**, even when several monitors change together, using
  the first changed output in sorted name order. Use `zpaper current --json` in a
  script if you need every output.
- Changes include rotation, manual commands, schedule switches, a reload that
  reassigns a monitor, and a fresh image for a newly connected monitor.
  Reapplying recorded images does not run it: `refresh`, the restore at daemon
  startup, and hotplug restore. Neither does a failed change.
- The command is started in the background through `setsid`, so a slow theme
  generator never blocks zpaper. Its output and errors, including a missing
  program, are appended to `$XDG_STATE_HOME/zpaper/on_change.log`
  (default `~/.local/state/zpaper/on_change.log`).

## Hotplug restore

With awww or swww, the daemon checks the connected outputs every two seconds
(`hotplug = true`, the default). An output that was reconnected, or that shows
no image because the renderer restarted, gets back the last image zpaper recorded
for it, including one from an older layout if it was unplugged during rotation.
A monitor zpaper has never seen gets a fresh image from the active collection,
even during a hold, and that becomes a new layout. Restoring a known image does
not add history, use up shuffle progress, release holds, or reset the rotation
timer. Outputs already showing an image are never changed, so wallpapers set
outside zpaper stay put. If the renderer stops answering, the daemon restarts it
when `backend_start = true` and retries every 15 seconds. Set `hotplug = false`
to turn this off.

With feh on X11, zpaper cannot ask what is displayed, so the daemon watches
`xrandr --listmonitors` instead. When monitors are added, removed, resized or
moved, it reruns feh with the recorded image so the background covers the new
screen layout. This needs `xrandr` (usually in the `xorg-xrandr` package); without
it the check is skipped. `hotplug = false` turns it off too.

`zpaper refresh` (an alias for `restore`) reapplies the saved
layout by hand, with or without a daemon. Like hotplug restore it is not a new
choice: history, shuffle progress, the rotation timer, the hook and
notifications are left alone.

A layout recorded under Wayland, with an image per monitor, still restores under
feh after switching sessions: feh shows the first of those images on every
monitor. The same applies to `previous` and `next` through older layouts.

## Migration and state

```sh
zpaper import-legacy             # ~/.cache/wallpaper_history and wallpaper_favorites
zpaper import-legacy /other/cache
```

Import merges without deleting or rewriting the source files and is safe to
repeat. Relative legacy paths are skipped because their original working directory
is unknown. The shell script's `wallpaper_state` is a **previous** layout, so it is
not imported as the current desktop. Old Zig flat state is also left untouched.

Version 1, 2 and 3 state files are read automatically and upgraded to version 4 on
the next successful state write, preserving history, holds, collection selection,
and shuffle progress. Version 3 added the scheduled-period cursor and manual
override; version 4 adds rotation timers for collections assigned to outputs.
Older zpaper binaries cannot read newer state versions.

State lives at `$XDG_STATE_HOME/zpaper/state.json`, defaulting to
`~/.local/state/zpaper/state.json`. It is versioned JSON, saved through an atomic
rename with file and directory synchronization. Corrupt or newer-version state is
reported rather than silently replaced. The socket lives in a private subdirectory
of `$XDG_RUNTIME_DIR`, or a private per-user directory in `/tmp` when unset.
Use the same XDG environment for daemon and client. Explicit `--config` requests
must match the active daemon's config; they never silently change it.

Most old long flags remain command aliases (`--next`, `--undo`, `--history`,
`--favorite`, `--restore-or-random`, etc.). `--preview` and the hardcoded
`--lock` integration were removed; use `set` plus `previous` for reversible
selection, and manage screen locking separately. The original shell script is
kept as a reference in [contrib/legacy](../contrib/legacy/). Stop any old wallpaper timer before using zpaper rotation.
