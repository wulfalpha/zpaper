# zpaper

A small Linux wallpaper daemon that remembers your choices. Renderers such as
awww, swww and feh draw wallpapers; zpaper decides what to show, when, and on
which monitor, and keeps track of everything you've picked.

## Features

- **Shuffle rotation** that goes through every image once before repeating, and
  remembers its place across restarts
- **Per-monitor wallpapers** on Wayland (awww/swww) and X11 (feh): set, rotate,
  or hold each output on its own
- **History and undo**: step back and forth through up to 100 saved desktop
  layouts, or search and reapply old images
- **Hotplug restore**: reconnected monitors and restarted renderers get their
  wallpaper back automatically (awww/swww on Wayland, feh + xrandr on X11)
- **Change hook**: run a command such as `wal -i %s` or `matugen image %s`
  after every change to theme your desktop from the wallpaper
- **Holds**: pause rotation everywhere or on one monitor, indefinitely or for a
  set time (`zpaper hold 2h`)
- **Favorites and exclusions** without touching your files
- **Named collections** (separate image folders, each with its own interval and
  shuffle progress), assignable per monitor
- **Daily schedules**: switch collections at set times of day, for all monitors
  or with a separate timetable per monitor
- Single binary, no shell evaluation, scriptable JSON output

## Requirements

- Linux
- [Zig 0.16.0](https://ziglang.org/download/) to build
- A renderer: [awww](https://codeberg.org/LGFae/awww) or
  [swww](https://github.com/LGFae/swww) on Wayland, `feh` plus `xrandr` on X11
  (both with per-monitor support), or any command through the `custom` backend
- Optional: Python 3 and `fzf` for the [`zpaper-pick`](contrib/zpaper-pick)
  interactive picker, plus `chafa` for image previews

## Install

Prebuilt Linux binaries for **x86_64** and **arm64** (including Raspberry Pi) are on
the [releases page](https://github.com/wulfalpha/zpaper/releases). They need glibc
2.31 or newer.

```sh
arch=$(uname -m)   # x86_64 or aarch64
version=0.10.1
curl -LO "https://github.com/wulfalpha/zpaper/releases/download/v$version/zpaper-$version-$arch-linux.tar.gz"
tar xzf "zpaper-$version-$arch-linux.tar.gz"
install -Dm755 "zpaper-$version-$arch-linux/zpaper" ~/.local/bin/zpaper
```

Each archive also contains the example config, the systemd unit, shell
completions and `zpaper-pick`. `SHA256SUMS` on the release lists checksums.

To build from source instead, see the quick start below.

## Quick start

```sh
git clone https://github.com/wulfalpha/zpaper.git && cd zpaper
zig build -Doptimize=ReleaseSafe
install -Dm755 zig-out/bin/zpaper ~/.local/bin/zpaper

mkdir -p ~/.config/zpaper
cp zpaperc.example ~/.config/zpaper/zpaperc   # set dir = your wallpaper folder
zpaper check                                  # validate the config
zpaper daemon                                 # start rotating
```

Fish completions (commands, collections, and connected outputs for `--output`):

```sh
cp contrib/completions/zpaper.fish ~/.config/fish/completions/
```

Start `zpaper daemon` from your window manager's autostart, or use the systemd user
unit in [contrib/zpaper.service](contrib/zpaper.service).

## Everyday commands

```sh
zpaper next                              # new wallpaper (or redo after previous)
zpaper previous                          # back to the last layout
zpaper set ~/wallpapers/forest.jpg
zpaper set ~/wallpapers/wide.jpg --output DP-1
zpaper hold 2h                           # pause automatic rotation
zpaper resume
zpaper favorite                          # favorite what's on screen
zpaper exclude                           # never rotate to this again
zpaper history                           # recently shown images
zpaper use landscapes                    # switch collection
zpaper status --json
zpaper explain                           # why each output follows its current policy
zpaper-pick                              # pick a monitor, then an image (fzf)
zpaper refresh                           # reapply the saved layout
zpaper reload                            # re-read the config
zpaper restart                           # restart the daemon (e.g. after upgrading)
zpaper --help
```

With a running daemon, commands go through its local socket; without one, they
run once directly.

## Documentation

- [Usage](docs/usage.md): daemon behaviour, history, holds, shuffle, and every command
- [Configuration and backends](docs/configuration.md): config syntax, renderers,
  state files, migrating from the old shell script
- [Named collections](docs/collections.md)
- [Daily scheduling](docs/scheduling.md)
- [Development](docs/development.md): building, tests, architecture notes

## License

[MIT](LICENSE)
