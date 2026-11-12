# Daily scheduling

Add an optional `[schedule]` section after the global settings. Every entry maps
a local, 24-hour `HH:MM` time to an existing collection:

```ini
[schedule]
08:00 = landscapes
20:00 = quiet
```

The referenced collections must have been defined somewhere in the same config;
section order does not matter. Times are sorted automatically. Duplicate times,
invalid times, undefined collections, and a `default` target without an image
source are errors. Omitting the section leaves scheduling disabled.

```sh
zpaper reload
zpaper schedule                  # timetable, current period, next change
zpaper schedule --json
zpaper use quiet                 # manual choice until the next scheduled period
zpaper schedule resume           # follow the current period again, respecting holds
```

- The daemon uses the most recent scheduled entry, including yesterday's last
  entry before today's first time. At startup or after sleep, it catches up to
  the current period once; it does not replay missed changes.
- A period changes the active collection and applies an image to unheld outputs.
  Switching to an already-active collection does not unnecessarily advance its
  wallpaper. That collection's interval controls rotation between schedule times.
  `interval = 0` disables interval rotation, **not scheduled collection changes**.
- Manual wallpaper commands (`use`, `set`, `next`, `previous`, `select`,
  `random-favorite`, and `restore`) suppress scheduled switching until the next
  period. With [per-monitor schedules](#per-monitor-schedules), a change only
  overrides the schedules of the monitors it changed. They still restart normal interval rotation; use `hold` to keep an
  individual wallpaper. The override survives restart. `schedule resume` ends
  it early without releasing any holds. One-shot commands do not otherwise run
  automatic scheduling; `schedule resume` can apply a period without a daemon.
- Global holds defer scheduled switching. Per-output holds preserve those outputs
  while others change. If all outputs are held, the active collection remains
  unchanged until an output is released. Missed periods are then skipped in favor
  of the current one. Hold expiry/release is noticed within five seconds while idle.
- A complete application failure leaves the prior state and scheduled period
  unconsumed; the daemon retries after five seconds. A partial application records
  successful outputs, makes the scheduled collection active, and reports the
  failures. Failed outputs can be retried with `next`; ordinary interval rotation
  and later periods continue. A busy backend can delay processing by its timeout.
- Reloading a changed timetable reconciles the new current period on the next
  daemon tick. Reloading an unchanged timetable preserves manual overrides.
  Invalid edits retain the working configuration. Removing `[schedule]` disables
  scheduling without changing the displayed layout or selected collection.

Times use the daemon's local timezone (`TZ` if supplied, otherwise the system
zone). Use the same `TZ` for daemon and clients; restart after changing the
system timezone. A skipped spring-forward time is caught up at the first observed
later time, unless a newer entry already applies. A repeated fall-back hour does
not replay previously handled entries. Backwards wall-clock adjustments also
avoid replay until local time catches up; `schedule resume` explicitly reevaluates
if needed. JSON times are minutes since local midnight, and event `day` is a civil
day index, not a UTC timestamp.

## Per-monitor schedules

A `[schedule.NAME]` section is a named timetable with the same `HH:MM = collection`
entries. An `[output.NAME]` section uses it with `schedule = NAME` instead of a
fixed `collection`:

```ini
[schedule]                 # monitors without their own schedule
07:00 = catppuccin
21:00 = nsfw

[schedule.external]
07:00 = catppuccin
18:30 = monster

[output.HDMI-A-0]          # X11
schedule = external
[output.HDMI-A-1]          # niri: same timetable, written once
schedule = external
```

This works with awww, swww, and feh (with `xrandr`), like per-monitor collections.

- A scheduled monitor draws from whichever collection its timetable selects now,
  rotating on that collection's interval. At each scheduled time the daemon
  switches only that schedule's monitors; others are untouched. Several monitors
  can share a schedule.
- A manual change (`set`, `next`, ...) to a scheduled monitor overrides its own
  schedule until that schedule's next change; other schedules are unaffected.
  A manual change to a monitor without a section overrides the global
  `[schedule]`, as before, and `use` always does.
- `zpaper schedule resume` resumes every schedule. `zpaper schedule resume
  --output HDMI-A-0` resumes only that monitor's schedule (or the global one for
  a monitor without a section) and switches it to the current collection.
- Holds work as for the global schedule: a held monitor keeps its image, and its
  schedule's switch stays pending until it is released.
- `zpaper schedule` lists every timetable with its monitors, current period and
  next change; `status` shows `[schedule NAME: COLLECTION]` next to each
  scheduled monitor.
- The first time the daemon sees a schedule, it only records the current
  period. Reloading a config that moves a monitor onto a schedule switches it at
  once, like any other reassignment.

Schedules support a daily timetable, without weekday/weekend rules or sunrise
calculations.
