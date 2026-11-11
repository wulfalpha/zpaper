# Changelog

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
