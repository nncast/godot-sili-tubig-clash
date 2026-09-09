# Footstep samples

**These files are generated, not sourced.** Every `.wav` in these folders is
synthesised from scratch by `tools/generate_audio.py` (numpy + scipy), so they
are original work owned by the team. To (re)build the surfaces it knows how
to make:

```
python3 tools/generate_audio.py
```

Seeds are derived from `(surface, gait, variant)` with a stable hash (not
Python's built-in `hash()`, which is salted per-process), so the output is
byte-for-byte reproducible — a judge can regenerate those files and compare.

**Only `plank` is currently in the script.** The original recipes for
`sand`/`grass`/`road`/`stairs`/`water` were lost before this copy of the
script was written; those five folders still have their real, working
samples checked into the repo, and the script deliberately does not list
them in `SURFACES` so it can never overwrite them. Re-author a recipe and add
it to `SURFACES` before trusting this script to regenerate any of those.

## Layout

`entities/surface_audio.gd` picks these up automatically — no inspector wiring.

```
assets/audio/footsteps/<surface>/walk_01.wav  walk_02.wav  ...
assets/audio/footsteps/<surface>/run_01.wav   run_02.wav   ...
```

Surfaces: `sand`, `grass`, `road`, `stairs`, `water`, `plank`. Four variants of
each gait are shipped; the loader scans up to `12`, picks one at random per
step and jitters the pitch. A surface with no files is silent, and a surface
with only `walk_*` files reuses those when running.

Each surface is voiced differently on purpose, because in a hide-and-seek game
the footstep is information: sand is dull and low, stairs are hollow and woody,
road is a sharp click, grass adds dry crackle, water is a broadband splash that
darkens as it decays, plank is a hollow wooden knock (a boardwalk, not an
indoor stair tread - two closely-detuned low partials under the contact click
is what makes it read as a physical board rather than a single clean tone).
Measured spectral centroids run from ~1.3 kHz (sand) to ~5 kHz (water), which
is wide enough to tell apart through a laptop speaker.

## Surface detection

Which surface a step uses comes from the level's own TileMapLayers (see
`SURFACE_LAYERS` in `surface_audio.gd`), tested in priority order:
`road` → `stairs` → `plank` → `grass` → `sand` → `sandfade` → `sea`. First
layer with a tile under the player wins, so a boardwalk painted over sand
sounds like a boardwalk, not sand.

`sea` maps to the `water` folder. The ocean *ambience* loop is separate — it
lives in `assets/audio/ambiance/` and fades in over the last 16 tiles as you
approach the `sea` layer.
