# Usage

## Running

Bare `zpaper` performs one `next` action by default. Set `daemon = true` in the
configuration to make bare `zpaper` run the daemon instead, including with
`--config PATH`. Then `zpaper &` works as a shell startup command. The daemon
stays in the foreground unless your shell or service manager backgrounds it.
Explicit `zpaper daemon` always runs the daemon; explicit commands such as
`zpaper next` remain single actions regardless of this setting. Neither an
interval nor a schedule implicitly enables daemon mode. This setting controls
startup only: reloading it does not stop a running daemon.

`daemon` runs in the foreground. Start it from your window manager, or adapt
[contrib/zpaper.service](../contrib/zpaper.service) after installing the executable
at `~/.local/bin/zpaper`. A user service must inherit the graphical session's
`WAYLAND_DISPLAY`/`DISPLAY` and `XDG_RUNTIME_DIR`. No service is installed or enabled
by the build. The renderer's daemon may also be started on demand on Wayland;
set `backend_start = false` if you manage it separately.
Automatically started renderers write stdout/stderr to
`$XDG_STATE_HOME/zpaper/awww-daemon.log` (or `swww-daemon.log`), defaulting to
`~/.local/state/zpaper/`. These append-only logs remain available after zpaper
exits and contain renderer startup errors or panic messages.

Without a daemon, commands run once under an exclusive state lock. With a daemon,
the same commands use its local Unix socket and return the result, including
backend errors. Commands never signal an unverified PID. Only one process may
own a given state directory, including across different runtime directories.

## Command behaviour

```sh
zpaper set ~/wallstreet/forest.jpg
zpaper set ~/wallstreet/wide.jpg ~/wallstreet/portrait.png
zpaper set ~/wallstreet/portrait.png --output DP-1
zpaper next
zpaper previous
zpaper hold 2h
zpaper hold --output DP-1
zpaper resume --output DP-1
zpaper resume
zpaper favorite
zpaper exclude                 # omit current image(s) from future rotation
zpaper include /path/image.png
zpaper current
zpaper status --json
zpaper history
zpaper search forest
zpaper select 3
zpaper refresh                 # reapply the saved layout (alias: restore)
zpaper reload
zpaper stop
```

- A single image applies to every targeted output. Multiple images map to output
  names sorted alphabetically, or to the order of an explicit comma-separated
  `--output` list. Fewer images leave remaining outputs unchanged; extras are an
  error. Connector order is not physical left-to-right order.
- Shuffle remembers images successfully applied in the current cycle, even across
  restarts. It uses every eligible file before starting another cycle and avoids
  immediate cycle-boundary repeats when possible. Added files join the cycle;
  removed files disappear. Favorites can also be selected with `random-favorite`.
- `previous` and `next` navigate up to 100 saved **layouts**. At the newest layout,
  `next` picks from the directory. A new manual selection branches history from
  the current cursor. Automatic rotation always picks from the directory.
  `next --output NAME` chooses a fresh image for that output rather than navigating
  the whole layout. Image history is a separate, deduplicated list of 100 paths.
- A hold blocks **automatic** changes. Explicit `set`, `next`, `previous`, and
  `restore` remain available and preserve holds. Holds survive restart. Bare
  durations mean minutes; `s`, `m`, `h`, and `d` suffixes are supported.
  `resume` releases all holds; `resume --output NAME` releases that output's own
  hold but does not override a global hold. Timed holds expire within five seconds
  of their deadline if rotation is due.
- Successful changes reset the rotation timer; `refresh` does not. Startup
  restores the saved layout and keeps the running timer, or starts a fresh
  interval if it ran out while the daemon was stopped. `interval = 0` disables automatic rotation.
  Omitting a command performs one `next`; configuration never implicitly forks.
- On partial failure, successful outputs are recorded and failed outputs retain
  their previous recorded image. The command reports each failure and exits
  nonzero. A total failure does not consume shuffle progress or advance history.
- `current` queries Wayland's backend, including changes made outside zpaper.
  `status` shows last recorded state, holds, and the next due time. For global-only
  backends, both commands can only report zpaper's recorded state.

`favorite`/`unfavorite` and `exclude`/`include` accept paths, or use current images
(optionally restricted with `--output`). Exclusion never deletes a file and does
not prevent an explicit manual selection or history restoration.

`schedule`, `collections`, `history`, `layouts`, `favorites`, `list`, `current`,
and `status` support `--json`.
## Interactive picker

The optional [zpaper-pick](../contrib/zpaper-pick) helper (Python 3 and `fzf`) picks
a wallpaper interactively with image previews:

```sh
zpaper-pick                    # choose a monitor, then an image from history
zpaper-pick --browse           # ...or from that monitor's collection
zpaper-pick -C quiet --all     # any collection, applied to every monitor
zpaper-pick forest DP-1        # history paths containing "forest", on DP-1
```

- With several monitors connected, it first lists each one with a preview of its
  current wallpaper, plus an "all" entry. An output given positionally, with
  `--output`, or `--all` skips this step; so does a single monitor or a global
  backend such as feh.
- Images come from history by default. `--browse` lists the chosen monitor's
  collection (its `[output.NAME]` assignment, otherwise the active collection);
  `-C NAME` lists a named collection. A substring argument narrows the list.
- Previews use `chafa` when installed (it picks sixel, kitty or text blocks for
  your terminal), otherwise `kitty icat` inside kitty, otherwise file details.
  Set `ZPAPER_PICK_PREVIEW` to another command (the image path is appended) or
  pass `--no-preview`. `--config PATH` is passed through to zpaper.
- The selected path is applied directly with `zpaper set`, so a rotation while
  you are choosing cannot make it apply the wrong image.
