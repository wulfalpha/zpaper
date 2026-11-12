# Changelog

## 0.9.1 — 2026-11-11

### Fixed
- Switching from an X11 session back to Wayland now restores each monitor's last
  image recorded under its Wayland name. In 0.9.0 this only worked in the
  X11 direction: under awww/swww, the daemon's startup restore and `refresh`
  skipped every monitor as disconnected (the saved layout used the X11 names),
  and `status` listed the X11 names. awww's own cache hid this at login.

## 0.9.0 — 2026-11-11

Per-monitor wallpapers on X11, for parity with Wayland.

### Added
- feh sets a different image on each X11 monitor. zpaper names the monitors
  with `xrandr --listmonitors` and runs feh once per change with one image per
  monitor, in Xinerama order. `--output`, per-monitor holds, `[output.NAME]`
  collections, `next --output`, and the `zpaper-pick` monitor step now work
  under X11. `%o` in `on_change` is the monitor name.
- X11 hotplug restores each monitor's own image, and a monitor zpaper has never
  seen gets a fresh image from its collection, as on Wayland.
- Switching between an X11 and a Wayland session restores each monitor's last
  image recorded under its own name, so each session gets its own layout back
  even though monitor names differ between them.

### Changed
- Without `xrandr` (or a display), feh keeps the previous behaviour of one image
  across all screens. Custom setters remain single-image.
- State from 0.8 with one image for every monitor upgrades on the first change.
- Transitions remain awww/swww only; X11 has no wallpaper transitions.

## 0.8.1 — 2026-11-11

Fixes from hardware testing on niri (awww) and qtile (X11, feh).

### Fixed
- Layouts recorded under Wayland, with an image per monitor, now restore under
  feh after switching to an X11 session. Previously the daemon's startup restore
  applied nothing, and `previous`/`next` failed on those layouts. feh shows the
  first recorded image on every monitor, and X11 hotplug restore uses it too.
- `refresh` (and `restore`) no longer act like a new choice: they leave image
  history, shuffle progress and the rotation timer alone, and do not send a
  notification or run `on_change`. The daemon's startup restore keeps a running
  timer and starts a fresh interval only if it ran out while the daemon was
  stopped.

### Changed
- `[output.NAME]` sections with feh or a custom setter are ignored instead of
  being a configuration error, so one configuration serves both a Wayland and an
  X11 session. `check` and `status` note that they are ignored.
- `zpaper reload` switches a monitor whose collection changed to an image from
  its new collection immediately, instead of at its next rotation. Held monitors
  keep their image.
- `on_change` no longer runs for the restore at daemon startup.
- `zpaper-pick` is now monitor-first with image previews: with several monitors
  it asks which one (or all) first, showing each monitor's current wallpaper,
  then lists images with previews via `chafa` or `kitty icat`. New options:
  `--browse` (the monitor's collection), `-C NAME`, `--all`, `--output`,
  `--config`, `--no-preview`, and `ZPAPER_PICK_PREVIEW`. The old
  `zpaper-pick [substring] [output]` usage still works.

## 0.8.0 — 2026-11-11

### Added
- **Per-monitor collections** (awww/swww): `[output.NAME]` sections with
  `collection = NAME` give a monitor its own collection, rotating on that
  collection's interval. Unassigned monitors follow the active collection;
  `use` and the schedule only change those.
- `status` and `collections` show output assignments and per-collection timers.
- Prebuilt release binaries for x86_64 and arm64 (glibc 2.31+), built and
  tested on native runners when a version tag is pushed.
- CI also runs on arm64.
- Fish shell completions in `contrib/completions/zpaper.fish`, including
  collection names for `use`/`list` and connected outputs for `--output`.

### Changed
- State format version 4 (adds per-collection rotation timers). Older states are
  upgraded automatically; older zpaper binaries cannot read version 4.

### Fixed
- A race in the subprocess-timeout integration test that made it fail at random.

## 0.7.0 — 2026-11-11

### Added
- **Change hook**: `on_change = COMMAND` runs once after each successful
  wallpaper change, in the background, with `%s` (image) and `%o` (output)
  placeholders. Output goes to `$XDG_STATE_HOME/zpaper/on_change.log`.

## 0.6.1 — 2026-11-11

### Added
- **Hotplug restore for feh on X11**: the daemon watches `xrandr --listmonitors`
  and reruns feh with the recorded image when monitors are added, removed,
  resized or moved. Skipped when `xrandr` is not installed; `hotplug = false`
  turns it off.

## 0.6.0 — 2026-11-11

### Added
- **Hotplug restore** (awww/swww): while the daemon runs, reconnected monitors
  get their last recorded wallpaper back, monitors blanked by a renderer restart
  are restored, and newly connected monitors get a fresh image. Restoring does not
  add history, use up shuffle progress, release holds, or reset the rotation
  timer. Outputs already showing an image are left alone.
- `hotplug` config option (default `true`) to turn this off.
- `zpaper refresh`, an alias for `restore`.

### Changed
- The version string now comes from `build.zig.zon`.
- README shortened; detailed documentation moved to `docs/`.
- The legacy shell script moved to `contrib/legacy/`.

## 0.5.1

First public release: shuffle rotation, per-monitor wallpapers, layout history,
holds, favorites and exclusions, named collections, and a daily schedule.
