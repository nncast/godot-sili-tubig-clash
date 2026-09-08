extends Node

## Autoload. Owns every non-positional sound in the game: the two music
## tracks, the UI hover/click blips, and the crossfade between them.
##
## Bus routing (see assets/audio/bus_layout.tres):
##   Music     -> Master     the two .ogg tracks
##   SFX       -> Master     parent of everything below, so one slider rules all
##     UI        -> SFX      hover / click blips
##     Ambience  -> SFX      the ocean loop
##     Footsteps -> SFX      per-surface steps from surface_audio.gd
##
## UI sounds wire themselves up: rather than making every scene remember to
## connect its own buttons, this listens to the SceneTree and hooks any Button
## the moment it enters the tree, anywhere in the game. Add a node to the
## "silent_ui" group to opt it out.

const MUSIC_TITLE: AudioStream = preload("res://game/assets/audio/music/Music_Title.ogg")
const MUSIC_INGAME: AudioStream = preload("res://game/assets/audio/music/Music_Ingame.ogg")
const SFX_UI_HOVER: AudioStream = preload("res://game/assets/audio/ui/ui_hover.wav")
const SFX_UI_CLICK: AudioStream = preload("res://game/assets/audio/ui/ui_click.wav")
const AMBIENCE_OCEAN := "res://game/assets/audio/ambiance/Ambiance_Ocean_Praia_dos_Moinhos_Loop_Stereo_02.wav"
## Chase sting, layered OVER the in-game track while the Sili is close. Loaded
## by path rather than preload()ed because it needs its loop points forced at
## load time - see load_looping_wav().
const MUSIC_DANGER := "res://game/assets/audio/music/Danger_03.wav"

## Gameplay sound effects, all synthesised by tools/generate_audio.py.
## Loaded by name rather than preloaded individually so call sites read as
## AudioManager.play_sfx("tag") instead of threading a constant through three
## scripts. Anything missing from disk simply doesn't play - the game should
## never crash over a sound.
const SFX_DIR := "res://game/assets/audio/sfx"
const SFX_NAMES: Array[String] = [
	"tag", "burn_tick", "rescue_start", "rescue_complete", "tunnel",
	"countdown", "countdown_go", "match_win", "match_lose",
	"eliminated", "spotted",
	# Filipino voice callouts - see CALLOUTS below.
	"callout_taya", "callout_anghang", "callout_save",
]

## Recorded Filipino callouts, layered OVER the mechanical sfx rather than
## replacing them: the synthesised tick still carries the timing information,
## the voice carries the identity. Team-recorded, which is both free and
## genuinely original work rather than a licensed pack.
##
## Loading is by name through _load_sfx, and a name with no file on disk simply
## warns and never plays - so this ships harmlessly before the recordings
## exist, and starts working the moment the .wav files are dropped in.
## Recording notes live in game/assets/audio/sfx/CALLOUTS.md.
const CALLOUTS := {
	"taya": "callout_taya",        # "Taya!" - the Sili has been spotted
	"anghang": "callout_anghang",  # "Ang anghang!!" - a tag just landed
	"save": "callout_save",        # "Save!" - a rescue completed
}

## A human voice cutting over itself sounds broken in a way a synthesised blip
## does not, so callouts are gated: one at a time, with a floor between them.
## Four players tagged in the same second gives one "Ang anghang!!", not four.
const CALLOUT_MIN_GAP := 0.9

## Per-sound trim, because a fanfare and a footstep-adjacent tick should not
## arrive at the same level. Anything unlisted plays at 0 dB.
const SFX_DB := {
	"burn_tick": -10.0,
	"countdown": -4.0,
	"rescue_start": -8.0,
	"spotted": -5.0,
	"tunnel": -3.0,
}

## Voices for non-positional (2D-UI-style) effects, round-robined like the UI
## pool so a tag landing under a countdown beep doesn't cut it off.
const SFX_VOICES := 6
## World-space one-shots free themselves when finished, but a chase can throw a
## lot of them at once; this caps how many can be alive at a time.
const MAX_POSITIONAL_SFX := 12

const CROSSFADE_TIME := 1.2
## The danger layer rides on top of the in-game track rather than replacing it,
## so it sits a little above MUSIC_DB to be clearly audible without burying the
## footsteps and the ocean - the cues that actually tell you where someone is.
const DANGER_DB := -14.0
## Asymmetric on purpose. Coming in fast is the point: the sting has to land
## while the Sili is still approaching, not after they've arrived. Going out
## slowly stops the music flickering every time a chase weaves behind a wall,
## and lets the tension hang for a beat after you think you've lost them.
const DANGER_FADE_IN := 0.6
const DANGER_FADE_OUT := 2.0
## Music sits well under the game now - background texture, not a score.
## Footsteps and the ocean are the cues that carry information in a game about
## hearing where someone is, so the music has to leave room for them.
const MUSIC_DB := -20.0
## Hover fires constantly as the pointer sweeps a menu, so it sits well under
## the click and refuses to retrigger while the previous blip is still going.
const HOVER_DB := -8.0   # Increased from -14.0 to make hovers louder
const HOVER_MIN_GAP := 0.06
const UI_VOICES := 4

## SFX bus boost - raises volume for all sounds routed through SFX bus
## (footsteps, ambience, and UI sounds together)
const SFX_BUS_BOOST_DB := 3.0  # Increase this value for louder SFX

var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _active_music: AudioStreamPlayer
var _current_track: AudioStream = null
var _fade_tween: Tween

var _danger_music: AudioStreamPlayer
var _danger_tween: Tween
var _danger_active := false

var _ui_voices: Array[AudioStreamPlayer] = []
var _ui_voice_index := 0
var _last_hover_at := -1.0
var _last_callout_at := -999.0
var _ambience_preview: AudioStreamPlayer
## Menu-side ocean loop. Separate from the in-match ambience, which
## surface_audio.gd fades in and out by how close a player is to the shoreline
## - out here there is no player and no shoreline, so it just runs.
var _menu_ambience: AudioStreamPlayer

var _sfx: Dictionary = {}  # name -> AudioStream
var _sfx_voices: Array[AudioStreamPlayer] = []
var _sfx_voice_index := 0
var _positional_count := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_music_a = _make_music_player("MusicA")
	_music_b = _make_music_player("MusicB")
	_active_music = _music_a

	for i in UI_VOICES:
		var voice := AudioStreamPlayer.new()
		voice.name = "UIVoice%d" % i
		voice.bus = "UI"
		add_child(voice)
		_ui_voices.append(voice)

	_load_sfx()
	for i in SFX_VOICES:
		var sfx_voice := AudioStreamPlayer.new()
		sfx_voice.name = "SFXVoice%d" % i
		sfx_voice.bus = "SFX"
		add_child(sfx_voice)
		_sfx_voices.append(sfx_voice)

	# Boost the SFX bus for all non-music sounds (footsteps, ambience, etc.)
	_boost_sfx_bus()

	get_tree().node_added.connect(_on_node_added)
	# Anything already in the tree when we boot (the title screen itself)
	# never fires node_added, so sweep it once by hand.
	_wire_buttons_under(get_tree().root)

	MatchManager.match_started.connect(_on_match_started)
	MatchManager.match_ended.connect(_on_match_ended)
	MatchManager.pregame_tick.connect(_on_pregame_tick)
	MatchManager.pregame_finished.connect(_on_pregame_finished)
	SightingTracker.sili_spotted_changed.connect(_on_sili_spotted_changed)

	play_title_music()


func _make_music_player(player_name: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = player_name
	player.bus = "Music"
	player.volume_db = MUSIC_DB
	# Enable looping for music tracks
	player.finished.connect(_on_music_finished.bind(player))
	add_child(player)
	return player


## Boost the SFX bus volume to make footsteps, ambience, and UI sounds louder
func _boost_sfx_bus() -> void:
	var sfx_bus_idx := AudioServer.get_bus_index("SFX")
	if sfx_bus_idx != -1:
		# Get current volume and add our boost
		var current_db := AudioServer.get_bus_volume_db(sfx_bus_idx)
		AudioServer.set_bus_volume_db(sfx_bus_idx, current_db + SFX_BUS_BOOST_DB)
	else:
		push_warning("SFX bus not found! Check bus_layout.tres")


# --- Music ------------------------------------------------------------------

## Title, lobby and settings. Music plus the ocean underneath it - the game is
## set on a beach, and starting the surf here rather than at the first match
## means the setting is established before the player has done anything.
func play_title_music() -> void:
	_crossfade_to(MUSIC_TITLE)
	start_menu_ambience()


## Handed over to surface_audio.gd once a match starts: in the arena the ocean
## has a position, and it should get louder as you approach the water rather
## than sitting flat under everything.
func play_game_music() -> void:
	stop_menu_ambience()
	_crossfade_to(MUSIC_INGAME)


func stop_music() -> void:
	_crossfade_to(null)


## Swaps between two AudioStreamPlayers rather than restarting one, so the
## outgoing track can fade out over the top of the incoming one instead of
## cutting dead the moment the scene changes.
func _crossfade_to(stream: AudioStream) -> void:
	if stream == _current_track and _active_music.playing:
		return
	_current_track = stream

	var outgoing := _active_music
	var incoming := _music_b if _active_music == _music_a else _music_a
	_active_music = incoming

	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.set_parallel(true)

	if stream != null:
		incoming.stream = stream
		incoming.volume_db = GameSettings.MIN_DB
		incoming.play()
		_fade_tween.tween_property(incoming, "volume_db", MUSIC_DB, CROSSFADE_TIME)

	if outgoing.playing:
		_fade_tween.tween_property(outgoing, "volume_db", GameSettings.MIN_DB, CROSSFADE_TIME)
		# finished fires once the whole (parallel) tween is done, which is the
		# simplest correct moment to free the voice up for the next swap.
		_fade_tween.finished.connect(outgoing.stop, CONNECT_ONE_SHOT)


# --- Danger layer -----------------------------------------------------------

## Fades the chase sting in over whatever music is already playing. Safe to
## call every frame: a repeat call while it's already up does nothing, so the
## caller can just describe the situation rather than track edges itself.
##
## Deliberately a LAYER and not a crossfade. Swapping tracks would mean the
## in-game music restarting from the top every time a Sili wanders past, and
## would fight _crossfade_to for the same two voices.
func start_danger_music() -> void:
	if _danger_active:
		return
	_danger_active = true

	var stream := load_looping_wav(MUSIC_DANGER)
	if stream == null:
		push_warning("AudioManager: missing danger track at '%s'." % MUSIC_DANGER)
		return

	if _danger_music == null:
		_danger_music = AudioStreamPlayer.new()
		_danger_music.name = "DangerMusic"
		_danger_music.bus = "Music"
		add_child(_danger_music)

	# Only restart the clip if it isn't already running. Fading back in on a
	# still-playing voice keeps the loop continuous through a quick
	# lost-then-found, instead of snapping back to the first bar.
	if not _danger_music.playing:
		_danger_music.stream = stream
		_danger_music.volume_db = GameSettings.MIN_DB
		_danger_music.play()

	_fade_danger_to(DANGER_DB, DANGER_FADE_IN)


## Fades the sting out and stops the voice once it's silent. Also safe to call
## repeatedly.
func stop_danger_music() -> void:
	if not _danger_active:
		return
	_danger_active = false
	if _danger_music == null or not _danger_music.playing:
		return
	_fade_danger_to(GameSettings.MIN_DB, DANGER_FADE_OUT)
	# Bound to this specific tween so a fade-in that interrupts the fade-out
	# can't be stopped by the older tween finishing afterwards.
	_danger_tween.finished.connect(func():
		if not _danger_active and _danger_music:
			_danger_music.stop(), CONNECT_ONE_SHOT)


## One tween at a time, killed on replacement - otherwise a fade-out started
## mid-fade-in leaves two tweens writing volume_db in the same frame and the
## level lands wherever the later one happens to run.
func _fade_danger_to(target_db: float, duration: float) -> void:
	if _danger_tween and _danger_tween.is_valid():
		_danger_tween.kill()
	_danger_tween = create_tween()
	_danger_tween.tween_property(_danger_music, "volume_db", target_db, duration)


## Cuts the sting immediately, no fade. For leaving the arena entirely, where
## a two-second tail would play over the results screen.
func kill_danger_music() -> void:
	_danger_active = false
	if _danger_tween and _danger_tween.is_valid():
		_danger_tween.kill()
	if _danger_music:
		_danger_music.stop()


## Handle music looping - when a track finishes, restart it if it's still
## the current active track and we're not crossfading to something else.
func _on_music_finished(player: AudioStreamPlayer) -> void:
	# Only loop if this is still the active music player and we have a track
	if player == _active_music and _current_track != null and player.playing == false:
		player.play()


func _on_match_started() -> void:
	play_game_music()


## The verdict is per-player: the same result is a win on one screen and a loss
## on the next, so this asks which side the local player is on rather than
## playing one stinger for everybody.
func _on_match_ended(sili_won: bool) -> void:
	# The chase is over the instant the whistle goes, so the sting should not
	# be fading out underneath the win/lose stinger.
	kill_danger_music()
	var my_id := multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1
	var my_role: String = NetworkManager.roles.get(my_id, "tubig")
	var i_won: bool = my_role == ("sili" if sili_won else "tubig")
	play_sfx("match_win" if i_won else "match_lose")
	play_title_music()


func _on_pregame_tick(seconds_left: int) -> void:
	if seconds_left > 0:
		play_sfx("countdown")


func _on_pregame_finished() -> void:
	play_sfx("countdown_go")


## "Taya!" - the Sili has been found. Fires on the rising edge only: the flag
## flickers as a chase weaves behind cover, and a voice re-announcing the same
## Sili every two seconds stops being information and becomes noise. The
## CALLOUT_MIN_GAP gate catches the rest.
##
## This also finally gives the `spotted` sfx a call site - it was loaded and
## never played, so the moment the whole team learns where the Sili is passed
## in silence.
func _on_sili_spotted_changed(is_spotted: bool) -> void:
	if not is_spotted:
		return
	play_sfx("spotted")
	play_callout("taya")


# --- UI blips ---------------------------------------------------------------

func play_ui_hover() -> void:
	# Sweeping a pointer across a menu can fire mouse_entered many times a
	# second; without this gate the blips pile up into a buzz.
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_hover_at < HOVER_MIN_GAP:
		return
	_last_hover_at = now
	_play_ui(SFX_UI_HOVER, HOVER_DB)


func play_ui_click() -> void:
	_play_ui(SFX_UI_CLICK, 0.0)


## Round-robins a small pool so a click landing on top of a hover doesn't cut
## the hover off mid-sample.
func _play_ui(stream: AudioStream, volume_db: float) -> void:
	var voice := _ui_voices[_ui_voice_index]
	_ui_voice_index = (_ui_voice_index + 1) % _ui_voices.size()
	voice.stream = stream
	voice.volume_db = volume_db
	voice.play()


# --- Gameplay SFX -----------------------------------------------------------

func _load_sfx() -> void:
	for sfx_name in SFX_NAMES:
		var path := "%s/%s.wav" % [SFX_DIR, sfx_name]
		if ResourceLoader.exists(path):
			_sfx[sfx_name] = load(path)
		else:
			push_warning("AudioManager: missing sfx '%s' - run tools/generate_audio.py" % sfx_name)


## Non-positional. Use for things that happened TO the person at this screen -
## their own countdown, their own elimination, the final verdict - where the
## sound is about them and not about a place on the map.
func play_sfx(sfx_name: String, extra_db: float = 0.0) -> void:
	if not _sfx.has(sfx_name) or _sfx_voices.is_empty():
		return
	var voice := _sfx_voices[_sfx_voice_index]
	_sfx_voice_index = (_sfx_voice_index + 1) % _sfx_voices.size()
	voice.stream = _sfx[sfx_name]
	voice.volume_db = float(SFX_DB.get(sfx_name, 0.0)) + extra_db
	voice.play()


## Plays a Filipino callout by its short key ("taya", "anghang", "save").
##
## Positional when given a place, flat otherwise. A tag callout belongs at the
## tagged player's feet for the same reason the tag sfx does - it tells a
## nearby teammate which way to look. The reveal callout has no single place
## it happened at, so it plays flat.
##
## Silently does nothing if the clip hasn't been recorded yet, or if another
## callout is still in the air.
func play_callout(key: String, world_position = null, extra_db: float = 0.0) -> void:
	var sfx_name: String = CALLOUTS.get(key, "")
	if sfx_name == "" or not _sfx.has(sfx_name):
		return

	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_callout_at < CALLOUT_MIN_GAP:
		return
	_last_callout_at = now

	if world_position is Vector2:
		play_sfx_at(sfx_name, world_position, extra_db)
	else:
		play_sfx(sfx_name, extra_db)


## World-space. Use for anything a bystander should be able to LOCATE - a tag
## landing across the plaza, someone dropping into a tunnel behind you. In a
## game about working out where people are, most gameplay sound belongs here
## rather than flat in both ears.
func play_sfx_at(sfx_name: String, world_position: Vector2, extra_db: float = 0.0) -> void:
	if not _sfx.has(sfx_name):
		return
	if _positional_count >= MAX_POSITIONAL_SFX:
		return

	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		play_sfx(sfx_name, extra_db)  # no world to place it in; better flat than silent
		return

	var voice := AudioStreamPlayer2D.new()
	voice.stream = _sfx[sfx_name]
	voice.bus = "SFX"
	voice.global_position = world_position
	voice.volume_db = float(SFX_DB.get(sfx_name, 0.0)) + extra_db
	# Roughly the footstep envelope: audible across a courtyard, gone across
	# the map, so sound stays a local clue rather than a global announcement.
	voice.max_distance = 520.0
	voice.attenuation = 1.6
	tree.current_scene.add_child(voice)

	_positional_count += 1
	voice.finished.connect(func():
		_positional_count = max(0, _positional_count - 1)
		voice.queue_free())
	voice.play()


# --- Ambience ---------------------------------------------------------------

## Loads the ocean loop with looping forced on in code as well as in the .import.
## The import flag only takes effect on a reimport, so a project that already
## has the old non-looping .sample cached would otherwise still play it once and
## fall silent - which is exactly what "the waves stop" looks like.
static func load_ocean_loop() -> AudioStream:
	return load_looping_wav(AMBIENCE_OCEAN)


## Loads a .wav with looping forced on in code as well as in the .import.
## The import flag only takes effect on a reimport, so a project that already
## has an old non-looping .sample cached would otherwise still play it once and
## fall silent. Shared by the ocean ambience and the danger sting, which are
## both loops shipped with the importer's default (non-looping) settings.
static func load_looping_wav(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		return null
	var stream := load(path)
	var wav := stream as AudioStreamWAV
	if wav:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		# A LOOP_FORWARD stream with loop_end still at 0 loops a zero-length
		# region, which is silence rather than sound. Derive it from the clip
		# length instead of the raw byte count - the file imports as compressed
		# audio, so bytes-per-sample arithmetic would be wrong.
		if wav.loop_end <= 0:
			wav.loop_end = int(wav.get_length() * wav.mix_rate)
	return stream


## The waves normally only exist on the local player in the arena, so on the
## settings screen the Ambience slider had nothing to act on - moving it did
## nothing audible, which read as a broken slider. Playing a preview while that
## screen is open gives it something to adjust.
func start_ambience_preview() -> void:
	if _ambience_preview and _ambience_preview.playing:
		return
	var stream := load_ocean_loop()
	if stream == null:
		return
	if _ambience_preview == null:
		_ambience_preview = AudioStreamPlayer.new()
		_ambience_preview.name = "AmbiencePreview"
		_ambience_preview.bus = "Ambience"
		add_child(_ambience_preview)
	_ambience_preview.stream = stream
	_ambience_preview.volume_db = -4.0
	_ambience_preview.play()


func stop_ambience_preview() -> void:
	if _ambience_preview:
		_ambience_preview.stop()


# --- Automatic button wiring ------------------------------------------------

func _on_node_added(node: Node) -> void:
	_wire_button(node)


func _wire_buttons_under(root: Node) -> void:
	_wire_button(root)
	for child in root.get_children():
		_wire_buttons_under(child)


## Covers Button, CheckBox, OptionButton and friends - they all derive from
## BaseButton, so menu toggles blip too without naming each type here.
func _wire_button(node: Node) -> void:
	var button := node as BaseButton
	if button == null or button.is_in_group("silent_ui"):
		return
	if not button.mouse_entered.is_connected(play_ui_hover):
		button.mouse_entered.connect(play_ui_hover)
	if not button.pressed.is_connected(play_ui_click):
		button.pressed.connect(play_ui_click)


## --- Menu ambience -------------------------------------------------------

func start_menu_ambience() -> void:
	if not ResourceLoader.exists(AMBIENCE_OCEAN):
		return
	if _menu_ambience == null:
		_menu_ambience = AudioStreamPlayer.new()
		_menu_ambience.name = "MenuAmbience"
		_menu_ambience.bus = "Ambience"
		add_child(_menu_ambience)

	var stream: AudioStream = load(AMBIENCE_OCEAN)
	# The file is a loop, but the importer does not always mark it as one - so
	# say it explicitly rather than letting the surf stop dead after 30s on the
	# title screen.
	if stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD

	if _menu_ambience.playing and _menu_ambience.stream == stream:
		return
	_menu_ambience.stream = stream
	_menu_ambience.volume_db = -2.0
	_menu_ambience.play()


func stop_menu_ambience() -> void:
	if _menu_ambience:
		_menu_ambience.stop()
