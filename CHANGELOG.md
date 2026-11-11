# Changelog

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
