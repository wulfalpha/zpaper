# Named collections

Collections are named image directories with independent saved shuffle progress.
Keep global settings above collection sections:

```ini
backend = auto
dir = ~/wallstreet
interval = 30m
recursive = true
# Optional initial selection; a saved selection takes precedence.
collection = quiet

[collection.quiet]
dir = ~/Pictures/wallpapers/quiet
interval = 45m

[collection.landscapes]
dir = ~/Pictures/wallpapers/landscapes
interval = 20m
recursive = false
```

```sh
zpaper collections               # * marks the active collection
zpaper use quiet                 # switch and immediately apply an image
zpaper use landscapes
zpaper list quiet                # inspect a collection without switching
zpaper use default               # return to the original top-level source
zpaper status --json
```

Each section requires `dir`. `interval` and `recursive` inherit the global values
when omitted; `interval = 0` explicitly disables automatic rotation for that
collection. All collections use shuffle (`order = shuffle` is accepted). Backend,
transitions, notifications, and timeout remain global. A top-level fixed
`wallpaper` only applies to `default`, never to named collections.

Names are case-sensitive and use 1–64 letters, digits, hyphens, or underscores.
`default` is reserved for the existing top-level `dir`/`wallpaper` settings, so old
configuration files still work without sections. Duplicate sections and unknown
section keys are errors.

`use` saves the selection, applies a fresh image immediately, and resets the timer
using that collection's interval. Like other manual commands, it works during a
hold and leaves holds intact. Switching back resumes the collection's shuffle
progress. An unknown/empty collection or a total backend failure leaves the old
selection and progress unchanged. After a partial backend failure, the new
collection is active and only successful output changes are recorded; the command
reports the failure.

The active collection applies to every monitor without its own assignment (see
[Per-monitor collections](#per-monitor-collections) below). Favorites, exclusions, image history, and the layout timeline remain
global. Browsing `previous`/`next` restores old layouts without changing the active
collection; new rotation uses the active collection. `use` branches from the
current timeline position.

The saved selection takes precedence over `collection = NAME`. Until a selection
has been saved by a successful wallpaper change, that setting chooses the initial
collection (otherwise `default`). A daemon reload cannot remove its active
collection: switch to another collection first. If it was removed while the daemon
was stopped, `status` reports the missing name and `use default` or `use NAME`
recovers it. Changing a collection's directory reconciles its shuffle progress
against the new files at the next rotation.

## Per-monitor collections

With awww or swww, an `[output.NAME]` section gives a monitor its own collection.
Find the output names with `zpaper current`.

```ini
[collection.portrait]
dir = ~/Pictures/wallpapers/portrait
interval = 1h

[output.DP-2]
collection = portrait
```

- An assigned monitor always draws from its collection. Monitors without a
  section follow the active collection, as before.
- **Each collection rotates on its own interval.** Here DP-2 changes hourly while
  the other monitors keep the active collection's interval. Each collection picks
  one image per rotation, shared by every monitor that draws from it.
- `use` and the schedule change the active collection, so they only change
  unassigned monitors. If every connected monitor is assigned, they switch the
  active collection without changing any wallpaper.
- `next` changes every monitor, each from its own collection. `next --output DP-2`
  picks from DP-2's collection. `set`, `previous`, holds, and hotplug restore work
  as usual; a newly connected monitor with a section gets an image from its
  collection.
- `collections` lists each collection's assigned outputs, and `status` shows them
  next to each output along with each assigned collection's next rotation.
- The only key is `collection`, which must name a defined collection (or
  `default`). Output sections need a per-monitor backend; with `backend = feh` or
  `custom` they are a configuration error, and they are ignored if `auto` resolves
  to feh.
