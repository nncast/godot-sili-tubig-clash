# Credits and Asset Attribution

**Sili-Tubig Clash** — F.I.R.E.S DEV
University of La Salette, Inc. — College of Information Technology
CODE & CONQUER Cagayan Valley: E-Sports Game Dev Challenge (RSTW 2026, DOST Region 2)

This file is the authoritative list of everything in this repository that the
team did not author. It exists alongside Form 03 (Asset and AI Usage
Disclosure); if the two ever disagree, treat Form 03 as the submitted document
and correct this file to match.

---

## Team

| Name | Role |
|---|---|
| Janelle Ann F. Castillo | Team Leader / Developer |
| Stefane B. Cerezo | Developer |
| Romar D. De Asis | QA / Dev Support |
| Hazel B. Sebastian | Game Designer / Artist |
| Cristian P. Sudaria | Game Artist / Dev Support |

Faculty Coach: Jayson S. Nacorda, MIT

---

## Engine

| Component | Author | License |
|---|---|---|
| Godot Engine 4.x | Godot Engine contributors | MIT |

---

## Third-party assets

### Graphics

| Asset | Files | Author | License / terms |
|---|---|---|---|
| Modern Exteriors | `assets/tilemap/*_16x16.png` (Terrains and Fences, City Terrains, City Props, Villas, Additional Houses, Vehicles, Camping, Beach, Godot Autotiles) | LimeZu | Commercial asset licence — **verify purchase receipt is on file** |
| Character Templates Pack | `assets/sprites/16x16 Sili.png`, `assets/sprites/16x16 Tubig.png` | EsriEsra | Asset licence — **verify terms** |
| Flat UI elements | `assets/ui/UI_Flat_*.png`, `assets/ui/Hud_Menu/UI_Flat_*.png` | *(pack author — CONFIRM)* | **UNVERIFIED — see Outstanding below** |

### Fonts

| Asset | Files | Author | License |
|---|---|---|---|
| BoldPixels | `assets/fonts/BoldPixels.ttf` | Yūki (@YukiPixels) | **CC BY-SA 4.0** |

CC BY-SA 4.0 requires attribution. The author's requested credit line is:

> BoldPixels Font by Yūki (@YukiPixels)

This line must appear somewhere the player can reach it — a credits screen or
an about panel — not only in this file.

### Audio

| Asset | Files | Author | License / terms |
|---|---|---|---|
| Music Loop Bundle | `assets/audio/music/Music_Title.ogg`, `Music_Ingame.ogg` | Tallbeard Studios | Asset licence — **verify terms** |
| Universal UI/Menu Soundpack | `assets/audio/ui/ui_click.wav`, `ui_hover.wav` | CyrexStudios | Asset licence — **verify terms** |
| Ocean ambience loop | `assets/audio/ambiance/Ambiance_Ocean_Praia_dos_Moinhos_Loop_Stereo_02.wav` | **UNIDENTIFIED** | **UNVERIFIED — see Outstanding below** |

---

## Original work by the team

Everything below was authored by F.I.R.E.S DEV and is owned by the team.

### Source code

All GDScript in `autoloads/`, `entities/`, `levels/`, `ui/`, and `tools/`.
No code was copied from tutorials, templates, open-source projects, or other
developers. AI assistance was used during development and is disclosed in
Form 03 and in the section below.

### Audio

Every footstep sample and every gameplay sound effect is **synthesised from
scratch** by `tools/generate_audio.py`, a numpy/scipy script written by the
team. Nothing was sampled, recorded from a library, or downloaded.

- `assets/audio/footsteps/{sand,grass,road,stairs,water}/{walk,run}_NN.wav` — 40 files
- `assets/audio/sfx/*.wav` — 11 files

The generator is committed to the repository and is deterministic (fixed random
seed), so any judge can reproduce every one of these files byte-for-byte by
running:

```
python3 tools/generate_audio.py
```

### Level design

The arena layout, spawn placement, hiding-spot placement, and tunnel network in
`levels/multiplayer_arena.tscn` are the team's own design, assembled from the
licensed tilesets listed above.

---

## AI usage

Disclosed in full on Form 03. In summary:

- **Claude** — assisted with backend code: multiplayer networking, match logic,
  server-side validation, the series/rotation system, the spectator camera, and
  the audio synthesis script. Extent: **heavy**.
- **Gemini** — assisted with art concepts and reference material for the game's
  visual direction. Extent: **moderate**.

All AI-assisted code was reviewed by the team before inclusion. No AI-generated
content in this project reproduces or infringes copyrighted or open-source
material.

---

## Outstanding — resolve before final submission

1. **Ocean ambience.** The source of
   `Ambiance_Ocean_Praia_dos_Moinhos_Loop_Stereo_02.wav` has not been
   identified. The filename convention suggests a commercial field-recording
   library. Either locate the purchase and add it to Form 03, or replace it —
   `tools/generate_audio.py` could synthesise a substitute if needed.
2. **Flat UI pack.** Confirm the author and licence for the `UI_Flat_*` files
   and add the entry to Form 03.
3. **BoldPixels attribution.** Add the required CC BY-SA credit line to an
   in-game credits screen. This is a licence obligation, not a courtesy.
4. **In-game credits screen.** None currently exists. Add one reachable from
   the title screen listing everything on this page.
