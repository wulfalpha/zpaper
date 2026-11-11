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
image paths, not solid-color backgrounds or renderer effects. Automatic hotplug
restoration, per-monitor collection assignments, and change hooks are future work.

## Migration and state

```sh
zpaper import-legacy             # ~/.cache/wallpaper_history and wallpaper_favorites
zpaper import-legacy /other/cache
```

Import merges without deleting or rewriting the source files and is safe to
repeat. Relative legacy paths are skipped because their original working directory
is unknown. The shell script's `wallpaper_state` is a **previous** layout, so it is
not imported as the current desktop. Old Zig flat state is also left untouched.

Version 1 and 2 state files are read automatically and upgraded to version 3 on
the next successful state write, preserving history, holds, collection selection,
and shuffle progress. Version 3 adds the scheduled-period cursor and manual
override. Older zpaper binaries cannot read version 3 state.

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
