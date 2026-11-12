# README demo

The [animated demo](media/demo.gif) runs the built zpaper CLI against the same
isolated backend fixtures used by the integration suite. It illustrates two
monitors with separate collections, a targeted rotation, whole-layout undo,
a monitor-first picker, and a timed hold with an explanation.

The displays are simulated, the wallpapers are generated placeholders, and the
picker's choices are scripted. It is not a recording of a live Wayland/X11 desktop.
Every frame's wallpaper paths come from the mock renderer's actual state after
executing the command; assertions verify the targeted rotation, undo, picker, and
hold. The [transcript](media/demo.json) contains command output and displayed paths.
A [static preview](media/demo.png) is available without animation.

## Reproduce

From the repository root, with Python 3, Pillow, and Zig 0.16.0 installed:

```sh
zig build -Doptimize=ReleaseSafe
python3 contrib/record-demo.py
```

The generator requires local Unix socket access, even though no real renderer or
existing daemon is used. HOME, XDG directories, PATH, and backend executables are
isolated in a temporary directory and cleaned afterward. It uses the repository's
`tests/integration.py` fixtures; run it from a source checkout. DejaVu Sans fonts
are used when available, with a Pillow fallback.

Use `--binary PATH` to record another build and `--output PATH.gif` to write the
GIF, PNG preview, and JSON transcript elsewhere.

## Use a real desktop

Start from [contrib/two-monitors.zpaperc](../contrib/two-monitors.zpaperc), edit the
two image folders, and replace the connector names with those from `zpaper current`.
Use an existing renderer or let zpaper start awww/swww with `backend_start = true`.
Run `zpaper check` before starting the daemon. The picker additionally needs fzf;
chafa is optional for image previews.
