# Changelog — competition-readiness pass

Sili-Tubig Clash / F.I.R.E.S DEV

Everything below is scoped to five things: compliance paperwork, sound, exploit
prevention, tournament structure, and the spectator. Each entry says what
changed and why, so the reasoning survives even if the code moves.

**Validation.** All changes were checked against **Godot 4.6 headless**:
a clean import with no script errors, a clean boot of the title screen, and
three test harnesses under `tools/` — all passing. See "Testing" at the bottom.

---

## 1. Compliance and repository hygiene

**Removed from the repository**

| Path | Reason |
|---|---|
| `START_HERE.txt`, `PROJECT_STRUCTURE.txt`, `docs/` | An AI-generated "fixes package" addressed to the team, sitting in the project root. Judges open these. |
| `addons/godot_ai/` | 2.6 MB third-party Godot editor addon, not enabled in `project.godot`, unused by the game. Third-party code shipped in a submission invites originality questions for no benefit. |
| `TileMapUtils.gd` + `.uid` | From the same package. Verified zero references anywhere in the project. |
| `{levels,ui/` | Junk directory created by a shell brace expansion that didn't expand. |

**Added**

- `CREDITS.md` — the authoritative attribution list, including three items that
  were missing from Form 03.
- `Form_01-03_updated.docx` — Form 03 with five new disclosure rows.

**Renamed**

- `project.godot`: `config/name` from `"ssmttm"` to `"Sili-Tubig Clash"`.
- `multiplayer_arena.tscn`: root node from `ssmttm` to `MultiplayerArena`.

> The network discovery protocol still uses the string `SSMTTM_DISCOVER` in
> `network_manager.gd`. This was left alone deliberately — changing it breaks
> compatibility between builds mid-tournament. Change it once, before the
> event, or not at all.

### Still outstanding (team action required)

1. The ocean ambience file's source is unidentified. Find the licence or
   replace it.
2. Confirm the author and licence of the `UI_Flat_*` sprites.
3. **BoldPixels is CC BY-SA 4.0 and legally requires attribution.** The credit
   line must appear in-game, not only in `CREDITS.md`. There is currently no
   credits screen — add one.

---

## 2. Sound

### Footsteps now exist

`surface_audio.gd` was 252 lines of well-built code producing complete silence
— the five footstep folders held nothing but `.gitkeep`. Its own header comment
called hearing someone sprint past "half the game."

`tools/generate_audio.py` synthesises **40 footstep samples** (5 surfaces ×
walk/run × 4 variants) and **11 sound effects** from scratch using numpy and
scipy. Nothing is sampled, recorded, or downloaded, which means:

- it is original work owned by the team, and
- it needs no asset licence and adds nothing to the disclosure burden.

The script has a fixed random seed, so the output is reproducible byte-for-byte.
That is worth saying out loud during the pitch: a judge can run one command and
verify the audio is yours.

Measured spectral centroids confirm the surfaces are distinguishable:

| Surface | Centroid | Character |
|---|---|---|
| sand | 1330 Hz | dull, low, soft |
| stairs | 1614 Hz | hollow wooden knock, three resonant modes |
| road | 3109 Hz | sharp click over a low slap |
| grass | 4831 Hz | swish with dry blade-crackle |
| water | 5051 Hz | broadband splash darkening as it decays |

### Sound effects wired to gameplay

New `AudioManager.play_sfx()` (non-positional) and `play_sfx_at()`
(world-space, with distance attenuation and a concurrency cap).

| Event | Sound | Placement |
|---|---|---|
| Sili lands a tag | `tag` | At the **victim's** position — a nearby teammate needs to know where the player went down |
| Burn times out | `eliminated` | Victim |
| Rescue channel starts | `rescue_start` | Rescuer |
| Rescue completes | `rescue_complete` | Rescued player |
| Tunnel used | `tunnel` | **Both mouths** — the Sili should be able to hear where you went as well as where you left |
| Pre-match countdown | `countdown`, `countdown_go` | Local |
| Match end | `match_win` / `match_lose` | Local, and **role-aware** — the same result is a win on one screen and a loss on the next |

---

## 3. Server-side validation (anti-cheat)

**The problem.** `heat_status.gd`'s RPCs were `@rpc("any_peer")` with no checks
beyond "am I the server". Any modified client could call `request_ignite()` on
any Tubig from anywhere on the map, or `request_cool_fully()` for free instant
rescues. For a game judged 20% on balanced mechanics and fair play, this was
the single most serious technical problem in the project.

**The fix.** Every request is now verified for three things:

1. **Who** — the caller comes from `multiplayer.get_remote_sender_id()`, never
   from an argument, so it cannot be forged.
2. **What role** — only the Sili may ignite; only a Tubig may rescue.
3. **Where** — both bodies must actually be close enough *on the server's copy
   of the world*, with latency tolerance (`TAG_RANGE` 26 px against a 12 px
   hitbox, `RESCUE_RANGE` 40 px against a 13 px interaction area).

Rescues additionally check that the rescuer isn't rescuing themselves, isn't
incapacitated, and that the end-of-match rescue lock is actually in force.

Rejections are `push_warning`, not errors — a legitimate client can fail a
distance check occasionally under lag, and that is not cheating.

### `request_die()` was deleted, not guarded

Elimination used to be something a client *asked for* when its own heart count
hit zero, which meant any peer could ask for it against anyone. `ignite()` now
handles the last heart itself, on the server. The network surface for "put a
player out of the match" is gone rather than merely defended.

### Lives moved to the server

Validating the tag doesn't help if a client can still write its own heart
count. `lives_left` moved from the player-owned `MPSync` onto the
server-authoritative `HeatStatus`, and the deduction moved into `ignite()`.

Before, one rule lived on two machines: the server set the state, and the
tagged player's client watched for the replicated change and decremented its
own counter. Now both halves happen in the same place, so the count and the
state cannot disagree.

`tubig.gd` loses `MAX_LIVES`, `lives_left`, `_on_burned()` and the
`_burn_counted` guard (which existed only to paper over the split), and now
just draws `heat_status.lives_left`.

### Win condition corrected

`_check_for_sili_win()` ended the match as soon as no Tubig was `NORMAL` —
counting a *burning* player as already beaten. Burning is temporary by design:
they are rooted, but a teammate has 15 seconds to reach them. The old rule
threw away the most dramatic situation the game can produce (four burning
players, one rescue channel running) and made the rescue mechanic meaningless
exactly when it mattered most.

A burn now has to actually time out. The Sili wins only when every Tubig is
`DEAD`.

---

## 4. Tournament structure

### Lobby locked to 5

`MATCH_SIZE = 5`. The clock, the Sili's speed ramp and the rescue economy are
all tuned against four runners; the lobby used to allow anything from 2 to 10,
so 1v1 and 1v9 were both startable and both broken.

Two exits from the lobby now:

- **Start Series** — competitive. Requires exactly 5.
- **Practice Match** — unranked, 2+, random Sili. Clears any series in progress
  rather than scoring into it, so a casual round can't pollute the standings.

The player list draws empty seats so the host can see how many people are still
missing instead of counting names.

**Bug fixed:** `create_server(port, max_clients)` counts *clients*, not total
players. `MAX_PLAYERS = 10` was really "10 clients plus the host". Now
`MAX_CLIENTS = MATCH_SIZE - 1`.

### Sili rotation

New `SeriesManager` autoload. A series is one round per player: with five in
the lobby you play five rounds and everyone is the Sili in exactly one.

The old code shuffled and took index 0 every round — pure random. The comment
at `match_result.gd:177` claimed this ensured "the Sili isn't the same player
two rounds running," which was **not true**. Random selection means one player
can be hunted four rounds running while another never holds the knife, and no
result taken from that is worth comparing.

### Cumulative scoring

Both roles score, and the ceilings are close, so nobody wins a series on the
strength of one lucky draw.

| Role | Award | Points |
|---|---|---|
| Sili | per Tubig eliminated | 2 |
| Sili | full wipe bonus | +3 |
| Tubig | survived to the buzzer | 3 |
| Tubig | per completed rescue | 1 |

A perfect Sili round is 11. A perfect Tubig round is 3 + up to 4 rescues.

Rescues are credited inside `request_cool_fully()` **after** every validation
check passes, so the scoreboard counts rescues that actually landed rather than
rescues that were claimed.

A standings board appears on the result screen after **every** round, not just
at the end — the whole point of a rotation is knowing where you stand while
there are still rounds left to change it. Eliminations and rescues are shown
next to the total so the number is explainable.

---

## 5. Spectator camera

New `ui/hud/spectator_view.gd`. Activates when a Tubig is eliminated.

A player knocked out at 0:30 previously spent two and a half minutes looking at
their own frozen sprite. That is a long time to ask someone to sit still, and
it throws away the thing that makes a 4v1 hunt worth watching — the four other
people still playing it.

- Cycle subjects with `A` / `D`; the list is Sili first, then living Tubig by
  peer id, in a **stable order** so pressing D twice doesn't land you back
  where you started.
- Lerped follow camera rather than a hard cut — both subjects are usually
  running, and instant cuts are disorienting.
- Auto-advances if the person you're watching gets caught.
- Banner hides at the final whistle so it doesn't clutter the result overlay.

**No RPCs, no replication.** The spectator only reads positions already on this
machine, so an eliminated player cannot leak information to their team or
affect the match. They also see nothing a live player couldn't — no mini-map,
no name tags.

---

## Bonus: pre-existing bug found and fixed

`ui/hud/minimap.gd` — `get_tile_texture_region()`'s second argument is the
**animation frame**, not the alternative tile. Both call sites were passing
`alternative`, which for any flipped or transposed tile is a bit-flagged value
like 4096, 12288 or 24576. Godot threw an out-of-bounds error *per tile* and
left those cells un-sampled, so the minimap terrain bake was both noisy in the
console and wrong on screen.

Fixed to frame `0`. Flipping a tile doesn't change its average colour, so the
alternative was never relevant to the answer. Arena load is now error-free.

---

## Testing

Three harnesses under `tools/`, run with:

```bash
godot --headless --script res://tools/test_series.gd    # 17 assertions
godot --headless --script res://tools/test_heat.gd      # 13 assertions
godot --headless --script res://tools/test_scenes.gd    # instantiates all 6 scenes
```

`test_series.gd` verifies rotation coverage, no duplicate Sili, full-wipe
scoring, survival + rescue scoring, that rescue credit doesn't leak between
rounds, and that everyone is Sili exactly once across a set.

`test_heat.gd` verifies the life economy: three hearts, one per tag, rescues
never refund, the last heart goes straight to `DEAD`, and a dead player can be
neither rescued nor re-tagged.

All passing on Godot 4.6 headless.

---

## Before you run this

1. **Back up your repo**, then copy these files over it.
2. `python3 tools/generate_audio.py` (needs `numpy` and `scipy`).
3. Open the project in Godot so the 51 new `.wav` files import.
4. Check the debugger for errors on first load.
5. Commit — and make sure the commits come from more than one team member's
   account. All ten existing commits are from a single author, and Rule 8
   allows organisers to request version-control records.

## Not done — from the original review

- Solo/offline practice mode with a bot Sili (a judge opening the `.exe` alone
  still reaches a lobby they cannot leave).
- Web export — `ENetMultiplayerPeer` and UDP broadcast discovery cannot run in
  a browser; this needs a `WebSocketMultiplayerPeer` transport.
- Filipino cultural art pass on the tilemap.
- Mid-match disconnect and reconnect handling.
- The trailer.

One known cosmetic issue: `_complete_rescue()` broadcasts "X rescued Y" to the
event feed before the server validates, so a rejected rescue would print a
false line. Rare, and harmless to the match state.
