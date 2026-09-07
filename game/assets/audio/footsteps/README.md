# Footstep samples

**These files are generated, not sourced.** Every `.wav` in these folders is
synthesised from scratch by `tools/generate_audio.py` (numpy + scipy), so they
are original work owned by the team. To rebuild them:

```
python3 tools/generate_audio.py
```

The script uses a fixed random seed, so the output is byte-for-byte
reproducible — a judge can regenerate the whole set and compare.

## Layout

`entities/surface_audio.gd` picks these up automatically — no inspector wiring.

```
assets/audio/footsteps/<surface>/walk_01.wav  walk_02.wav  ...
assets/audio/footsteps/<surface>/run_01.wav   run_02.wav   ...
```

Surfaces: `sand`, `grass`, `road`, `stairs`, `water`. Four variants of each
gait are shipped; the loader scans up to `12`, picks one at random per step and
jitters the pitch. A surface with no files is silent, and a surface with only
`walk_*` files reuses those when running.

Each surface is voiced differently on purpose, because in a hide-and-seek game
the footstep is information: sand is dull and low, stairs are hollow and woody,
road is a sharp click, grass adds dry crackle, water is a broadband splash that
darkens as it decays. Measured spectral centroids run from ~1.3 kHz (sand) to
~5 kHz (water), which is wide enough to tell apart through a laptop speaker.

## Surface detection

Which surface a step uses comes from the level's own TileMapLayers (see
`SURFACE_LAYERS` in `surface_audio.gd`), tested in priority order:
`road` → `stairs` → `grass` → `sand` → `sandfade` → `sea`. First layer with a
tile under the player wins, so road painted over sand sounds like road.

`sea` maps to the `water` folder. The ocean *ambience* loop is separate — it
lives in `assets/audio/ambiance/` and fades in over the last 16 tiles as you
approach the `sea` layer.
