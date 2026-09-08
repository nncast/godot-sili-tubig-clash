# Filipino voice callouts — recording notes

Three short shouts, recorded by the team. Drop the finished files in this
folder (`game/assets/audio/sfx/`) and they start playing immediately — no code
change needed. `AudioManager._load_sfx` loads by filename and warns-and-skips
anything missing, so the game runs fine before these exist.

## The three clips

| File | Line | Fires when |
|---|---|---|
| `callout_taya.wav` | "Taya!" | Any Tubig gets the Sili on screen (rising edge only) |
| `callout_anghang.wav` | "Ang anghang!!" | A tag lands, at the tagged player's position |
| `callout_save.wav` | "Save!" | A rescue channel completes, at the rescued player's position |

## Format

- **WAV, 44.1 kHz, 16-bit, mono.** Mono matters: `anghang` and `save` play
  through `AudioStreamPlayer2D`, and a stereo file can't be positioned
  properly in the world.
- **Under 1 second each.** `AudioManager.CALLOUT_MIN_GAP` is 0.9s — a clip
  longer than that will still be playing when the gate reopens.
- Trim silence off the head. Any lead-in delay lands the shout after the
  event it's announcing, which is worse than no shout.
- Normalise to about -3 dBFS peak, then tune in code via `SFX_DB` in
  `audio_manager.gd` rather than re-recording — that's what the table is for.

## Performance notes

- Shout them the way you'd shout them in a real game — outdoors, at someone
  across a yard. A clean studio read sounds wrong next to synthesised sfx.
- Record 4–6 takes of each and pick one. Don't ship variations of the same
  line; one take per callout keeps the announcer sounding like one person.
- `anghang` is the one players hear most. If any take sounds annoying on the
  fifth listen, it will be unbearable by the end of a match — pick the
  shortest, flattest one.
- One voice for all three unless you deliberately want a Sili voice and a
  Tubig voice, in which case `anghang` is the Sili and the other two are Tubig.

## Why record rather than buy

Section 7 of the competition mechanics asks for original work, and Form 03
requires disclosing anything that isn't. A recording the team made needs no
disclosure line and no licence check, and it's the cheapest originality point
in the project — the whole thing is ten minutes with a phone.

Add the resulting files to the credits table as team-recorded audio.
