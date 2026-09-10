extends Node2D

const SILI_SCENE: PackedScene = preload("res://game/arena/actors/sili/sili.tscn")
const TUBIG_SCENE: PackedScene = preload("res://game/arena/actors/tubig/tubig.tscn")
const HEART_TEXTURE: Texture2D = preload("res://game/assets/art/ui/heart.png")

## Team-panel status circle. Blue = free, red = tagged and still savable,
## grey = burn timed out and they're gone for good.
const DOT_SIZE := 18
const TUBIG_FREE_COLOR := Color(0.24, 0.55, 0.95)
const TUBIG_TAGGED_COLOR := Color(0.88, 0.22, 0.20)
const TUBIG_DEAD_COLOR := Color(0.42, 0.42, 0.44)
const DEAD_ROW_TINT := Color(0.55, 0.55, 0.55, 0.65)
## Matches Tubig.HEART_SPENT_COLOR so the two heart displays stay in step.
const HEART_SPENT_COLOR := Color(0.25, 0.25, 0.25, 0.5)
## Connection indicator dot colours.
const CONNECTION_OK_COLOR := Color(0.35, 0.85, 0.45)
const CONNECTION_LOST_COLOR := Color(0.88, 0.22, 0.20)
## Burn countdown. Amber while there is still time to cross the map, red once
## the decision is basically made - the threshold is a readable signal, not
## decoration, so it sits at the point where a rescue channel (6s) plus travel
## stops being realistic.
const BURN_TIMER_URGENT_AT := 10
const BURN_TIMER_COLOR := Color(1.0, 0.76, 0.28)
const BURN_TIMER_URGENT_COLOR := Color(1.0, 0.36, 0.32)

@onready var match_label: Label = $HUD/MatchLabel
@onready var announcement_label: Label = $HUD/AnnouncementLabel
@onready var team_panel: VBoxContainer = $HUD/TeamPanel
@onready var guide_button: Button = $HUD/GuideButton
@onready var guide_panel: PanelContainer = $HUD/GuidePanel
@onready var settings_button: Button = $HUD/SettingsButton
@onready var settings_popup: PanelContainer = $HUD/SettingsPopup
@onready var master_slider: HSlider = $HUD/SettingsPopup/VBox/MasterRow/MasterSlider
@onready var music_slider: HSlider = $HUD/SettingsPopup/VBox/MusicRow/MusicSlider
@onready var sfx_slider: HSlider = $HUD/SettingsPopup/VBox/SFXRow/SFXSlider
@onready var ambience_slider: HSlider = $HUD/SettingsPopup/VBox/AmbienceRow/AmbienceSlider
@onready var master_value: Label = $HUD/SettingsPopup/VBox/MasterRow/MasterValue
@onready var music_value: Label = $HUD/SettingsPopup/VBox/MusicRow/MusicValue
@onready var sfx_value: Label = $HUD/SettingsPopup/VBox/SFXRow/SFXValue
@onready var ambience_value: Label = $HUD/SettingsPopup/VBox/AmbienceRow/AmbienceValue
@onready var leave_game_button: Button = $HUD/SettingsPopup/VBox/LeaveGameButton
@onready var close_settings_button: Button = $HUD/SettingsPopup/VBox/CloseButton
@onready var connection_dot: Panel = $HUD/ConnectionIndicator/Dot
@onready var connection_status_label: Label = $HUD/ConnectionIndicator/StatusLabel
@onready var connection_indicator: HBoxContainer = $HUD/ConnectionIndicator
@onready var sili_spawner: MultiplayerSpawner = $SiliSpawner
@onready var tubig_spawner: MultiplayerSpawner = $TubigSpawner
@onready var map_holder: Node2D = $MapHolder
## Containers live on the SHELL, not inside the map.
##
## MultiplayerSpawner replicates by PATH, and every peer resolves that path
## against its own tree - so the path has to be identical everywhere. While the
## level was welded into this scene, Map/SiliContainer was stable. The moment
## the map became a thing that changes, it stopped being. Anchoring the
## containers here gives a path that holds no matter which level is loaded.
@onready var sili_container: Node2D = $SiliContainer
@onready var tubig_container: Node2D = $TubigContainer
## Resolved after the map is instanced, since it lives inside the map.
var spawn_points_root: Node2D = null
var map_instance: Node2D = null
@onready var minimap: Control = $HUD/Minimap
@onready var threat_vignette: Control = $ThreatLayer/ThreatVignette

var _tubig_players: Array = []
## Set the first time a Tubig actually shows up in the group. _check_for_sili_win
## treats an empty roster as "nobody left to catch", which is correct once the
## round is underway - but the roster is also empty for a moment before
## spawning finishes, and without this guard that same moment reads as a
## full-wipe win before anyone was ever in the match.
var _tubigs_ever_seen: bool = false
var _spectator: SpectatorView = null
var _danger_music: DangerMusic = null

## Every signal this panel wired up on the LAST rebuild, so the next rebuild can
## unwire them. Without this the closures below outlive the rows they capture:
## _build_team_panel frees the old rows but leaves their update_hearts/update_dot
## still connected to each Tubig, and the next tag or rescue calls them against a
## freed TextureRect - a runtime error mid-match rather than a wrong colour.
var _panel_connections: Array = []

## Belt-and-suspenders for _check_for_sili_win: that function is also called
## directly off every Tubig's burned/died signal, which is the fast path and
## should always be the one that actually ends the round. This is the backup -
## a plain "is everyone incapacitated right now" poll that doesn't depend on
## any particular signal having fired, so a missed connection (a body spawned
## through some path that skipped _refresh_team_state, say) can't leave a
## fully-tagged team stuck waiting out the clock. Half a second is fast enough
## nobody would notice it's a poll and not an event.
var _win_check_accum: float = 0.0
const WIN_CHECK_INTERVAL: float = 0.5

## The same belt-and-suspenders idea as _win_check_accum, for the team panel -
## and specifically for the peers the one above never covers. _process() returns
## on its first line for anyone who is not the server, so that poll is a
## HOST-ONLY backup: every client was left purely event-driven, rebuilding only
## when a spawned/player_left signal happened to arrive. A signal that came out
## of order, or a spawn that never landed at all, left that player looking at a
## panel missing their teammates for the rest of the round with nothing in the
## scene able to notice or correct it. The host never saw the bug because it
## builds the whole roster locally in one loop.
##
## Compares who is ACTUALLY in the tubig group against who the panel was last
## drawn from, so the steady state costs one group query and a string compare
## rather than a rebuild - it only redraws when those two genuinely disagree.
var _panel_roster_signature: String = ""
var _panel_check_accum: float = 0.0
const PANEL_CHECK_INTERVAL: float = 0.5


## Only used if Map/SpawnPoints is missing or has no marker for a role - the
## real positions come from the SpawnPoint nodes you drag around in the editor.
## Keeping a fallback means deleting a marker mid-edit can't crash a match.
const FALLBACK_SPAWN_POINTS: Array[Vector2] = [
	Vector2(-40, -40), Vector2(60, 40), Vector2(-60, 60),
	Vector2(80, -60), Vector2(-90, -20), Vector2(30, 90),
]


func _ready() -> void:
	_load_map()

	sili_spawner.spawn_function = _spawn_sili
	tubig_spawner.spawn_function = _spawn_tubig
	sili_spawner.spawned.connect(_on_player_spawned)
	tubig_spawner.spawned.connect(_on_player_spawned)

	MatchManager.time_updated.connect(_on_time_updated)
	MatchManager.match_ended.connect(_on_match_ended)
	NetworkManager.player_left.connect(_on_player_left)

	_setup_settings_popup()
	_setup_connection_indicator()
	_setup_guide()
	_setup_announcements()

	# Bake the mini-map straight off the level's own tilemap, bottom-up, so it
	# can never drift out of sync with the map the players are running around
	# in. We hand it the Map node rather than one layer: build_from_node walks
	# the children itself, so every painted layer (sea, sand, grass, road,
	# buildings...) ends up in the bake.
	minimap.build_from_node(map_instance)

	# Only the host decides who spawns where and starts the clock - but not
	# until every peer has actually finished building this scene. See
	# NetworkManager.report_arena_ready().
	if NetworkManager.is_host():
		SightingTracker.reset()
		NetworkManager.arena_peer_ready.connect(_on_arena_peer_ready)
		NetworkManager.player_list_changed.connect(_try_launch_round)
		get_tree().create_timer(READY_TIMEOUT).timeout.connect(_on_ready_timeout)

	# Every peer reports, host included - the host's own arena is no more ready
	# than anyone else's until this line runs.
	NetworkManager.report_arena_ready()

	if NetworkManager.is_host():
		# Reports that arrived while this scene was still being built are
		# already sitting in NetworkManager, so check them now rather than
		# waiting for a signal that has been and gone.
		_try_launch_round()
	elif not multiplayer.has_multiplayer_peer():
		# Offline (tools/ test harnesses): nothing to wait for.
		_round_launched = true

	# Everyone (not just the host) needs to see the team status panel, so
	# this runs on every peer - only the win-check inside it is server-gated.
	call_deferred("_refresh_team_state")


## --- Load handshake -------------------------------------------------------
##
## The host used to spawn players and start the clock straight out of _ready().
## That works with one fast client and fails with four laptops, because
## _rpc_load_arena tells everyone to change scene at the same moment but the
## host's own change is a local call - it is already running _ready() while the
## clients are still loading theirs.
##
## MultiplayerSpawner replicates by PATH. A spawn command that lands on a peer
## whose arena does not exist yet cannot resolve "../TubigContainer", so ENet
## discards it and never retries: that client spends the whole round with
## missing players. The pregame RPC from MatchManager.start_match() is lost the
## same way, which is the "countdown never starts" version of the same bug.
##
## The window is wide, not marginal. minimap.build_from_node() above walks every
## TileMapLayer and averages each tile's pixels, which on a big level takes real
## time on a slow machine - so the host can comfortably finish spawning before a
## client has begun.

## Long enough to cover a slow laptop loading a big map, short enough that one
## machine which crashed or pulled its Wi-Fi cannot hang the other four
## indefinitely. On timeout the round starts anyway - a short-handed match is a
## far better failure than a lobby frozen forever at a demo booth.
const READY_TIMEOUT: float = 20.0

var _round_launched: bool = false

## True while the HUD's own panels are shut out - see _set_hud_locked(). Held as
## state rather than read off MatchManager each time because the guide answers to
## a hotkey as well as a button, and both have to consult the same answer.
var _hud_locked: bool = false


func _on_arena_peer_ready(_peer_id: int) -> void:
	_try_launch_round()


## Host only. Fires as soon as everyone in NetworkManager.players has checked
## in - which for a solo host is immediately, so two-machine testing behaves
## exactly as it did before. Also re-run when the player list changes, so a peer
## dropping mid-load releases the wait instead of costing everyone the timeout.
func _try_launch_round() -> void:
	if _round_launched or not NetworkManager.is_host():
		return
	if not NetworkManager.all_peers_arena_ready():
		return
	_launch_round_now()


func _on_ready_timeout() -> void:
	if _round_launched or not NetworkManager.is_host():
		return
	var missing: Array = []
	for peer_id in NetworkManager.players.keys():
		if not NetworkManager.arena_ready_peers.has(peer_id):
			missing.append(peer_id)
	push_warning("Arena: starting without %s - they never reported ready." % str(missing))
	_launch_round_now()


func _launch_round_now() -> void:
	_round_launched = true
	_spawn_all_players()
	# MultiplayerSpawner.spawned is emitted on PUPPETS ONLY - the authority that
	# called spawn() never hears about its own spawns. So _on_player_spawned,
	# which is what re-runs _configure_local_hud once bodies exist, never fires
	# on the host: its only configure was the one from _ready(), before anyone
	# had spawned, which handed the minimap, the threat vignette, the danger
	# music and the spectator a null player and never corrected any of them.
	# spawn() adds the bodies synchronously, so by here they are all in the tree
	# and one refresh catches the lot.
	_refresh_team_state()
	MatchManager.start_match()


## In-match settings panel - the same four rows as the main Settings screen,
## bound the same way and reading off the same autoload, so a value changed here
## and a value changed there can never disagree.
func _setup_settings_popup() -> void:
	_bind_volume_row(master_slider, master_value,
		GameSettings.master_volume, GameSettings.set_master_volume)
	_bind_volume_row(music_slider, music_value,
		GameSettings.music_volume, GameSettings.set_music_volume)
	_bind_volume_row(sfx_slider, sfx_value,
		GameSettings.sfx_volume, GameSettings.set_sfx_volume)
	_bind_volume_row(ambience_slider, ambience_value,
		GameSettings.ambience_volume, GameSettings.set_ambience_volume)

	settings_button.pressed.connect(func(): settings_popup.visible = not settings_popup.visible)
	close_settings_button.pressed.connect(func(): settings_popup.visible = false)
	leave_game_button.pressed.connect(_on_leave_game_pressed)

	# The HUD is shut while the countdown runs. See _set_hud_locked - the round is
	# already on screen during the role reveal, so without this the Settings
	# panel opens over the top of it.
	#
	# Unlocked on match_started, NOT on pregame_finished: pregame_finished is
	# emitted only `if was_pregame`, so a match with PREGAME_DURATION set to 0
	# goes straight to _rpc_start_match and never sends it - and a lock released
	# by a signal that never arrives is a HUD nobody can open for the whole
	# round. match_started fires on both paths.
	MatchManager.pregame_started.connect(func(_duration: float): _set_hud_locked(true))
	MatchManager.match_started.connect(func(): _set_hud_locked(false))
	# A peer whose arena finished building after the countdown had already begun
	# never saw pregame_started, so take the current state rather than assuming
	# this scene is older than the match. Offline harnesses run no match at all
	# and want the HUD live from the start.
	_set_hud_locked(MatchManager.is_pregame)


## The only way out of a match once it's started - the title screen's own Exit
## button doesn't reach here, and a host or client stuck mid-round (say, the
## other side of a dead connection) had no way back except force-quitting.
##
## Confirmed rather than immediate because it sits one click inside the Settings
## popup, next to four volume sliders: the hand that went in there to turn the
## music down should not be able to end four other people's round by a pixel.
func _on_leave_game_pressed() -> void:
	var message := "The round keeps going without you, and you'll go back to the title screen."
	if NetworkManager.is_host():
		message = "You're hosting. Leaving ends this match for everyone in it."
	ModalDialog.show_confirm("Leave Match?", message, "Leave", "Stay", _leave_match)


func _leave_match() -> void:
	NetworkManager.leave_game()
	LoadingScreen.change_scene("res://ui/title_screen/title_screen.tscn")


## F1 (standard) or H (mnemonic for "Help") toggles the controls guide. The
## question mark button is the discoverable path to the same panel; either one
## flips guide_panel and hides/shows the "?" so there's never a redundant way
## to open something already open.
func _setup_guide() -> void:
	guide_button.pressed.connect(_toggle_guide)


func _toggle_guide() -> void:
	if _hud_locked:
		return
	guide_panel.visible = not guide_panel.visible
	guide_button.visible = not guide_panel.visible


## Shuts the HUD's own panels while the round is still counting in.
##
## The arena is fully built and visible during the role reveal and the 5-second
## countdown - the players just can't move yet - so every HUD control was live
## before the match was. You could sit in the Settings panel through the whole
## countdown, and be looking at a volume slider instead of at which role you had
## just been given.
##
## Both entry points to each panel are covered, not just the buttons: the guide
## also answers to F1/H, and a disabled button that a hotkey still opens is not
## disabled. Anything already open is closed rather than frozen in place, since
## the reveal is the one thing that should be on screen at that moment.
func _set_hud_locked(locked: bool) -> void:
	_hud_locked = locked

	settings_button.disabled = locked
	guide_button.disabled = locked

	if locked:
		settings_popup.visible = false
		guide_panel.visible = false
		guide_button.visible = true
		# A button that keeps focus can still be fired with Enter or Space while
		# it is disabled-looking, which is the same bug one layer down.
		get_viewport().gui_release_focus()


func _unhandled_input(event: InputEvent) -> void:
	if _hud_locked:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1 or event.keycode == KEY_H:
			_toggle_guide()
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("ui_cancel") and guide_panel.visible:
		_toggle_guide()
		get_viewport().set_input_as_handled()


## Match-wide state changes ("Sili is faster", "Rescues are locked") read as
## announcements, not chatter - they apply to everyone regardless of what they
## just did, unlike the tag/rescue/buff lines in HUD/EventFeed. Anchored right
## under the clock instead of the corner feed so they're impossible to miss at
## the moment they matter, and single-line rather than stacked since only one
## of these is ever true at a time.
func _setup_announcements() -> void:
	announcement_label.text = ""
	MatchManager.sili_speed_changed.connect(_on_sili_speed_changed)
	MatchManager.rescues_locked.connect(_on_rescues_locked)


func _on_sili_speed_changed(multiplier: float, stage: int) -> void:
	if stage <= 0:
		return  # stage 0 is the match's starting speed - nothing to announce
	_show_announcement("Sili is getting faster  (+%d%%)" % roundi((multiplier - 1.0) * 100.0))


func _on_rescues_locked() -> void:
	_show_announcement("Rescues are locked")


func _show_announcement(text: String) -> void:
	announcement_label.text = text
	var tween := create_tween()
	tween.tween_interval(4.0)
	tween.tween_callback(func():
		if announcement_label.text == text:
			announcement_label.text = "")


## Hidden entirely offline (tools/ test harnesses have no peer to report on).
## While networked, starts green and flips red the moment the host connection
## is lost - see NetworkManager.server_disconnected. This does not itself
## return the player to the title screen; Settings > Leave Game (above) is the
## way out of a dead connection.
func _setup_connection_indicator() -> void:
	if not multiplayer.has_multiplayer_peer():
		connection_indicator.visible = false
		return
	connection_indicator.visible = true
	_set_connection_state(true)
	NetworkManager.server_disconnected.connect(func(): _set_connection_state(false))


func _set_connection_state(connected: bool) -> void:
	var dot_style := StyleBoxFlat.new()
	dot_style.bg_color = CONNECTION_OK_COLOR if connected else CONNECTION_LOST_COLOR
	dot_style.set_corner_radius_all(6)
	connection_dot.add_theme_stylebox_override("panel", dot_style)
	connection_status_label.text = "Connected" if connected else "Disconnected"


## Mirrors settings.gd's _bind. Four rows configured by one code path is what
## stops a single row silently drifting away from the other three.
func _bind_volume_row(slider: HSlider, readout: Label, initial: float, apply: Callable) -> void:
	slider.value = initial
	readout.text = "%d%%" % roundi(initial * 100.0)
	slider.value_changed.connect(apply)
	slider.value_changed.connect(func(value: float):
		readout.text = "%d%%" % roundi(value * 100.0))


func _spawn_all_players() -> void:
	# One counter per role: the roles have separate marker lists, so a shared
	# index would leave gaps (two Tubigs would land on markers 2 and 3 when the
	# Sili took 1, never touching marker 1).
	var role_counts := {"sili": 0, "tubig": 0}
	for peer_id in NetworkManager.roles.keys():
		var role: String = NetworkManager.roles[peer_id]
		var index: int = role_counts.get(role, 0)
		role_counts[role] = index + 1
		var data := {"peer_id": peer_id, "role": role, "spawn_index": index}
		if role == "sili":
			sili_spawner.spawn(data)
		else:
			tubig_spawner.spawn(data)


## Reads the position off the matching SpawnPoint marker. Markers live in the
## scene, so every peer sees the same ones and independently works out the same
## spawn - no position needs replicating.
##
## Converted through the container rather than used raw: the marker is a child
## of Map (which is offset from the scene root), while the character is added
## under Map/SiliContainer, so a straight copy of marker.position would land the
## player one Map-offset away from the marker you dragged.
func _spawn_position_for(role: String, index: int, container: Node2D) -> Vector2:
	var markers := _markers_for(role)
	if markers.is_empty():
		return FALLBACK_SPAWN_POINTS[index % FALLBACK_SPAWN_POINTS.size()]
	var marker: SpawnPoint = markers[index % markers.size()]
	return container.to_local(marker.global_position)


func _markers_for(role: String) -> Array:
	var markers: Array = []
	if spawn_points_root == null:
		return markers
	for child in spawn_points_root.get_children():
		var marker := child as SpawnPoint
		if marker and marker.role_name() == role:
			markers.append(marker)
	return markers


## Runs on EVERY peer (that's the point of spawn_function) so all clients
## build the exact same node with the exact same authority, without needing
## the authority property itself to be network-replicated. Split into two
## thin wrappers (one per spawner) that both defer to the shared builder below.
func _spawn_sili(data: Dictionary) -> Node:
	return _build_player(data)


func _spawn_tubig(data: Dictionary) -> Node:
	return _build_player(data)


func _build_player(data: Dictionary) -> Node:
	var peer_id: int = data["peer_id"]
	var role: String = data["role"]
	var index: int = data.get("spawn_index", 0)

	var scene := SILI_SCENE if role == "sili" else TUBIG_SCENE
	var container: Node2D = sili_container if role == "sili" else tubig_container
	var instance := scene.instantiate()
	instance.name = "player_%d" % peer_id
	instance.position = _spawn_position_for(role, index, container)
	instance.z_index = 0
	instance.set_multiplayer_authority(peer_id)

	if role == "tubig":
		# Heat/burning state is always server-decided, regardless of who
		# controls the Tubig's movement - see heat_status.gd's request_*() RPCs.
		var heat_status := instance.get_node("HeatStatus")
		heat_status.set_multiplayer_authority(1)

	# Only the locally-controlled character should be driving the camera.
	if peer_id != multiplayer.get_unique_id():
		var cam := instance.get_node_or_null("Camera2D")
		if cam:
			cam.enabled = false

	return instance


## Fires the instant a spawn lands in this peer's own scene tree - the correct
## way to know spawning finished, instead of guessing with a fixed timer that
## could be wrong on a slower connection and permanently leave the local HUD (or
## a teammate's team-panel row) unconfigured.
##
## PUPPETS ONLY. MultiplayerSpawner does not emit `spawned` on the authority
## that called spawn(), so this never runs on the host - see _launch_round_now,
## which refreshes by hand for exactly that reason.
func _on_player_spawned(_node: Node) -> void:
	_refresh_team_state()


func _refresh_team_state() -> void:
	# Can arrive after the arena has already left the tree - a deferred call
	# from _on_player_left queued the moment before a scene change, or the
	# same NetworkManager signal reaching an arena that just got torn down.
	# get_tree() returns null in that case, not an empty tree, so this has to
	# be an early return rather than a call that would otherwise error out.
	if not is_inside_tree():
		return

	_tubig_players = get_tree().get_nodes_in_group("tubig")
	if not _tubig_players.is_empty():
		_tubigs_ever_seen = true

	for tubig in _tubig_players:
		var heat: HeatStatus = tubig.get_node_or_null("HeatStatus")
		if heat and not heat.burned.is_connected(_check_for_sili_win):
			heat.burned.connect(_check_for_sili_win)
			heat.died.connect(_check_for_sili_win)

	# Unconditional. This used to skip the rebuild whenever _tubig_players.size()
	# came out equal to what it was before the refresh, on the theory that a
	# same-size roster means nothing worth redrawing changed. That assumption
	# is what could leave a Tubig staring at an empty or stale team panel:
	# this function fires off whichever spawn/despawn signal a given peer
	# happens to receive, in whatever order the network delivers them, and a
	# size comparison against the wrong baseline can read as "no change" even
	# when the actual roster (which bodies are in it, not just how many) did
	# change. Rebuilding is cheap for a handful of rows - see
	# _build_team_panel - so there's no real cost to just always doing it and
	# guaranteeing the panel matches reality instead of trusting a shortcut
	# that depended on an ordering multiplayer replication doesn't promise.
	_build_team_panel()
	_configure_local_hud()


## The mini-map, the threat vignette and the danger music all need to know
## which character on this screen is ours, and which side it's on - the map
## shows a different set of dots per team, and the other two are Tubig-only.
func _configure_local_hud() -> void:
	var my_id := _local_peer_id()
	var is_sili: bool = NetworkManager.roles.get(my_id, "tubig") == "sili"
	var container := sili_container if is_sili else tubig_container
	var local_player := container.get_node_or_null("player_%d" % my_id) as Node2D

	minimap.configure(local_player, is_sili)
	threat_vignette.track_player(local_player, not is_sili)
	_ensure_danger_music().track_player(local_player, not is_sili)

	# Only a Tubig can be eliminated, so the Sili never needs one of these.
	if not is_sili and local_player != null:
		_ensure_spectator().watch_local_player(local_player)


## Created on demand and only once. _configure_local_hud runs again every time
## a peer finishes spawning, and a second SpectatorView would mean a second
## Camera2D quietly fighting the first for the viewport.
func _ensure_spectator() -> SpectatorView:
	if _spectator != null and is_instance_valid(_spectator):
		return _spectator
	_spectator = SpectatorView.new()
	_spectator.name = "SpectatorView"
	add_child(_spectator)
	return _spectator


## Same "create once, reuse after" reasoning as _ensure_spectator() - and the
## same doc comment on danger_music.gd itself explains why this is built here
## in code rather than placed in arena.tscn: it is per-local-player state, and
## the arena is what knows which character that is.
func _ensure_danger_music() -> DangerMusic:
	if _danger_music != null and is_instance_valid(_danger_music):
		return _danger_music
	_danger_music = DangerMusic.new()
	_danger_music.name = "DangerMusic"
	add_child(_danger_music)
	return _danger_music


func _local_peer_id() -> int:
	return multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1


## Character nodes are named "player_<peer_id>" by _build_player, which is the
## only link back from a spawned body to the name its owner typed in the lobby.
func _peer_id_for(character: Node) -> int:
	var node_name := String(character.name)
	if not node_name.begins_with("player_"):
		return 0
	return int(node_name.trim_prefix("player_"))


func _display_name_for(character: Node) -> String:
	var peer_id := _peer_id_for(character)
	if peer_id == 0:
		return "Tubig"
	return NetworkManager.players.get(peer_id, "Player %d" % peer_id)


## Doc section 5.2's "Team Status Panel" - one row per Tubig, sized to
## however many are actually in the match. Each row is a status circle and the
## player's name side by side, then their remaining rescue charges.
##
## The circle carries the state at a glance: blue while they're free, red the
## moment the Sili tags them, grey once the burn times out. Runs on every peer
## so everyone can read the same board.
func _build_team_panel() -> void:
	_drop_panel_connections()

	# Recorded from the roster actually being drawn, not from a fresh group
	# query, so the signature can never claim the panel shows something it
	# doesn't - see _reconcile_team_panel.
	_panel_roster_signature = _roster_signature(_tubig_players)

	# remove_child as well as queue_free: queue_free only deletes at the end of
	# the frame, so without it the panel briefly shows the old rows underneath
	# the new ones.
	for child in team_panel.get_children():
		team_panel.remove_child(child)
		child.queue_free()

	for tubig in _tubig_players:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		team_panel.add_child(row)

		# A Panel with a fully-rounded StyleBoxFlat is a real circle without
		# needing a texture asset or a custom _draw.
		var dot := Panel.new()
		dot.custom_minimum_size = Vector2(DOT_SIZE, DOT_SIZE)
		var dot_style := StyleBoxFlat.new()
		dot_style.bg_color = TUBIG_FREE_COLOR
		@warning_ignore("integer_division")
		dot_style.set_corner_radius_all(DOT_SIZE / 2)
		dot.add_theme_stylebox_override("panel", dot_style)
		row.add_child(dot)

		# Also drawn above each character in-world (see sili.tscn/tubig.tscn's
		# own NameLabel) - this copy is what lets you read a teammate's status
		# and name together without them needing to be on screen at all.
		var name_label := Label.new()
		name_label.custom_minimum_size = Vector2(96, 0)
		name_label.text = _display_name_for(tubig)
		name_label.add_theme_font_size_override("font_size", 14)
		name_label.clip_text = true
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(name_label)

		# The countdown a teammate needs in order to decide whether the run is
		# worth making. Fixed width and always present (blank when nobody is
		# burning) so the hearts beside it never shift sideways mid-match.
		var timer_label := Label.new()
		timer_label.custom_minimum_size = Vector2(34, 0)
		timer_label.add_theme_font_size_override("font_size", 14)
		timer_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		timer_label.add_theme_constant_override("outline_size", 4)
		timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(timer_label)

		var hearts_row := HBoxContainer.new()
		hearts_row.add_theme_constant_override("separation", 2)
		row.add_child(hearts_row)

		var heart_icons: Array = []
		for i in 3:
			var heart := TextureRect.new()
			heart.custom_minimum_size = Vector2(14, 14)
			heart.texture = HEART_TEXTURE
			heart.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			heart.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			hearts_row.add_child(heart)
			heart_icons.append(heart)

		var heat: HeatStatus = tubig.get_node_or_null("HeatStatus")

		# Read straight off HeatStatus instead of caching a flag. GDScript
		# lambdas capture by VALUE, so the previous version's shared
		# `is_tagged` bool never worked: update_dot flipped its own copy and
		# update_hearts kept reading the stale `false` it captured at creation
		# time, which is why the heart never greyed. Capturing `heat` is fine -
		# the captured value is an object reference, so state changes on it are
		# visible here.
		var update_hearts := func(lives_remaining: int):
			if not is_instance_valid(row):
				return  # this row was replaced by a rebuild; nothing to paint
			# Straight one-heart-per-life. The old "grey the last heart while
			# tagged" special case is gone: a tag now actually deducts a life,
			# so shading one on top of that counted the same hit twice.
			for i in heart_icons.size():
				heart_icons[i].modulate = (
					Color.WHITE if i < lives_remaining else HEART_SPENT_COLOR)

		var update_timer := func(seconds_left: int):
			if not is_instance_valid(timer_label) or not is_instance_valid(tubig):
				return
			# Only a BURNING player has a clock worth showing. A dead one has
			# run out and a free one was never on it, and printing "0s" for
			# either would read as "about to die" for someone who isn't.
			if heat == null or not heat.is_burning():
				timer_label.text = ""
				return
			timer_label.text = "%ds" % seconds_left
			timer_label.add_theme_color_override("font_color",
				BURN_TIMER_URGENT_COLOR if seconds_left <= BURN_TIMER_URGENT_AT
				else BURN_TIMER_COLOR)

		var update_dot := func(new_state):
			if not is_instance_valid(row) or not is_instance_valid(tubig):
				return
			match new_state:
				HeatStatus.State.BURNING:
					dot_style.bg_color = TUBIG_TAGGED_COLOR
					row.modulate = Color.WHITE
				HeatStatus.State.DEAD:
					# Grey circle plus a grey row tint: the hearts and the name
					# are near-white, so multiplying them down reads as the
					# whole entry draining to greyscale.
					dot_style.bg_color = TUBIG_DEAD_COLOR
					row.modulate = DEAD_ROW_TINT
				_:
					dot_style.bg_color = TUBIG_FREE_COLOR
					row.modulate = Color.WHITE
			if heat:
				update_hearts.call(heat.lives_left)
				update_timer.call(heat.burn_seconds_left)
		if heat:
			_track_connection(heat, &"state_changed", update_dot)
			_track_connection(heat, &"lives_changed", update_hearts)
			_track_connection(heat, &"burn_time_changed", update_timer)
			update_dot.call(heat.state)
			update_hearts.call(heat.lives_left)
			update_timer.call(heat.burn_seconds_left)


## Instances the level the host chose and parks it under MapHolder.
##
## The instance is renamed to "Map" regardless of what the scene file is
## called: surface_audio.gd finds the level by walking up for a node with that
## name, so every map answers to it. The map id comes from NetworkManager,
## which the host set before telling anyone to change scene - a client never
## picks its own level, or peers would be running around different worlds.
func _load_map() -> void:
	var map_id := NetworkManager.current_map_id
	if not MapRegistry.exists(map_id):
		push_warning("Arena: unknown map '%s', falling back to '%s'." % [
			map_id, MapRegistry.DEFAULT_MAP])
		map_id = MapRegistry.DEFAULT_MAP

	var packed: PackedScene = load(MapRegistry.scene_path(map_id))
	if packed == null:
		push_error("Arena: could not load map '%s'." % map_id)
		return

	map_instance = packed.instantiate() as Node2D
	map_instance.name = "Map"
	map_holder.add_child(map_instance)

	spawn_points_root = map_instance.get_node_or_null("SpawnPoints")
	if spawn_points_root == null:
		push_error("Arena: map '%s' has no SpawnPoints - see the contract in map_registry.gd." % map_id)


## Connects and records, so _drop_panel_connections can undo it on the next
## rebuild. Panel closures capture nodes, so they must not outlive those nodes.
##
## Stored as a WeakRef, not the HeatStatus node itself. A departed player's
## body (HeatStatus included) can now be freed out from under this array by
## _on_player_left, and reading a plain Object reference back out of a
## Dictionary after its target was freed logs "Trying to assign invalid
## previously freed instance" the moment it's assigned to a typed variable -
## before is_instance_valid() ever gets a chance to say no. WeakRef.get_ref()
## is the engine's own answer to exactly this: it comes back null, quietly,
## once the target is gone.
func _track_connection(source: Object, signal_name: StringName, callable: Callable) -> void:
	source.connect(signal_name, callable)
	_panel_connections.append({"source": weakref(source), "signal": signal_name, "callable": callable})


func _drop_panel_connections() -> void:
	for entry in _panel_connections:
		var source: Object = entry["source"].get_ref()
		if source != null and source.is_connected(entry["signal"], entry["callable"]):
			source.disconnect(entry["signal"], entry["callable"])
	_panel_connections.clear()


## The Sili wins the moment nobody is left who could still perform a rescue.
##
## Checked on every tag AND every death (see _refresh_team_state's connect
## calls). A Tubig still NORMAL could in principle reach and save a burning
## teammate, so that's the only state that keeps the round alive - BURNING
## and DEAD are both "can't act" from the win check's point of view. Ending
## only on all-DEAD (a burn has to fully time out) sounds safer, but it isn't:
## rescuing a burning Tubig requires another Tubig who is free to move, so the
## instant everyone remaining is burning or dead, the round is already
## unwinnable - waiting out the timer just delays a result that's already
## decided. That delay was very visible in a 1v1: the sole Tubig gets tagged,
## there is nobody left who could ever rescue them, and the match kept running
## for the rest of the burn timer before declaring the win. The rescue
## mechanic's drama is unaffected - it's exactly preserved whenever at least
## one Tubig is still NORMAL and the round has to keep going for them.
## Every Tubig body that is actually still in the match, right now.
##
## Reads the group directly rather than trusting the cached _tubig_players,
## and that distinction is the whole fix for "the round never ends once the
## Tubig side empties out". Two separate lags were stacking up:
##
##   1. _tubig_players is only rewritten by _refresh_team_state, so anything
##      calling _check_for_sili_win in between reads the roster as it was.
##   2. queue_free() does not remove a node until the END of the frame, so
##      even a refresh that runs in the same frame as a departure still finds
##      the departing body sitting in the group, alive and NORMAL.
##
## _on_player_left defers a refresh and then the check, which looks like it
## sequences those correctly - but the refresh still lands before the engine
## has actually deleted anything. The result was a check that ran exactly one
## departure behind: with two Tubigs leaving, the first check saw both, the
## second saw the one that had just left, and no third check ever happened
## because there were no bodies left to fire burned/died. The round then ran
## its full clock out with nobody in it.
##
## is_queued_for_deletion() is what closes that window: a body already marked
## for removal is not somebody who can still perform a rescue, whether or not
## the engine has got round to freeing it.
func _live_tubig_bodies() -> Array:
	var live: Array = []
	if not is_inside_tree():
		return live
	for tubig in get_tree().get_nodes_in_group("tubig"):
		if not is_instance_valid(tubig):
			continue
		if tubig.is_queued_for_deletion():
			continue
		live.append(tubig)
	return live


## Server-only poll, running independently of the burned/died signals - see
## the comment on _win_check_accum for why this exists alongside the
## event-driven path rather than instead of it.
func _process(delta: float) -> void:
	# Before the server-only guard below, deliberately: this half is what every
	# non-host peer relies on, and gating it the way the win check is gated is
	# the exact bug it exists to fix.
	_reconcile_team_panel(delta)

	# has_multiplayer_peer() first: once a peer disconnects mid-match,
	# multiplayer.multiplayer_peer goes null but this scene keeps ticking for
	# the few seconds match_result.gd takes to lead the player back to the
	# title, and calling is_server() with no peer assigned logs an engine
	# error every single frame instead of returning cleanly. Same guard
	# _record_round_result already uses below.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	if not MatchManager.is_running:
		return
	_win_check_accum += delta
	if _win_check_accum < WIN_CHECK_INTERVAL:
		return
	_win_check_accum = 0.0
	_check_for_sili_win()


## Runs on EVERY peer. Rebuilds only when the roster on screen has drifted from
## the roster in the tree, so a client that missed a spawn signal repairs itself
## within half a second instead of playing the whole round with a wrong panel.
func _reconcile_team_panel(delta: float) -> void:
	_panel_check_accum += delta
	if _panel_check_accum < PANEL_CHECK_INTERVAL:
		return
	_panel_check_accum = 0.0
	if not is_inside_tree():
		return
	if _roster_signature(get_tree().get_nodes_in_group("tubig")) == _panel_roster_signature:
		return
	_refresh_team_state()


## Who the panel is showing, as one comparable value. Sorted because group order
## is whatever order the nodes happened to enter the tree in, which differs from
## peer to peer and between rounds - unsorted, two identical rosters could
## compare unequal and rebuild the panel every half second forever.
func _roster_signature(bodies: Array) -> String:
	var ids: Array[String] = []
	for body in bodies:
		if is_instance_valid(body) and not body.is_queued_for_deletion():
			ids.append(String(body.name))
	ids.sort()
	return ",".join(ids)


func _check_for_sili_win() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	# Nothing to decide before the round starts. end_match() refuses while
	# is_running is false anyway, so this only keeps an empty pregame roster
	# from looking like a Sili win on the way past.
	if not MatchManager.is_running:
		return

	# Every Tubig still in the match has to be BURNING or DEAD - rooted, unable
	# to move - for the Sili to have won. The Sili is never a candidate here;
	# it's the opposing side, so it can never be the one rescue depends on.
	# The moment even one Tubig is NORMAL (free to move), that one could still
	# reach and save a tagged teammate, so the round keeps going.
	var live := _live_tubig_bodies()
	for tubig in live:
		var heat: HeatStatus = tubig.get_node_or_null("HeatStatus")
		if heat and not heat.is_incapacitated():
			return  # someone is still free to attempt a rescue

	# An EMPTY list ends the round too, and it reaches this line the same way
	# "everyone is burning" does: the loop simply finds nobody who could still
	# act. Nobody left to catch is the same verdict as nobody left standing -
	# there is no play remaining either way - so it is deliberately not a
	# special case with its own branch.
	#
	# EXCEPT when the roster has never had anyone in it yet. A round that
	# hasn't finished spawning also has an empty list, and that is not a wipe -
	# it's the round not having started. Without this, a poll or a signal
	# firing in that brief window declares an instant Sili win over a match
	# nobody actually played.
	if live.is_empty() and not _tubigs_ever_seen:
		return

	MatchManager.end_match(true)


## Nobody ever removes a spawned character when its owner disconnects -
## SiliSpawner/TubigSpawner only ever add - so without this a departed
## player's body stayed in the world forever: a corpse the Sili could still
## "tag" for nothing, a permanent entry in the team panel, a target
## SpectatorView could get stuck watching, and - critically for
## _check_for_sili_win - a body that was never DEAD or BURNING and so counted
## as "still free" forever, meaning a match could never end once its last
## active Tubig simply left instead of being caught.
##
## Runs on every peer (NetworkManager.player_left fires everywhere). Both
## deferred calls below are safe to fire unconditionally on a client too -
## _check_for_sili_win gates itself on multiplayer.is_server(), the same
## pattern it already relies on being connected to every Tubig's burned/died
## signals on every peer.
func _on_player_left(peer_id: int, _display_name: String) -> void:
	var node_name := "player_%d" % peer_id
	var body := sili_container.get_node_or_null(node_name)
	if body == null:
		body = tubig_container.get_node_or_null(node_name)
	if body != null:
		body.queue_free()

	# Deferred: queue_free() only removes the node at the end of this frame,
	# so _refresh_team_state's group query would still see the departed body
	# if it ran right now. _check_for_sili_win is queued after it for the same
	# reason - it reads _tubig_players, which only _refresh_team_state updates.
	call_deferred("_refresh_team_state")
	call_deferred("_check_for_sili_win")


func _on_time_updated(time_remaining: float, _match_duration: float) -> void:
	@warning_ignore("integer_division")
	var minutes := int(time_remaining) / 60
	var seconds := int(time_remaining) % 60
	# Just the clock now - tag/rescue/speed lines go to HUD/EventFeed, which has
	# room to show what actually happened instead of a bare percentage.
	match_label.text = "%d:%02d" % [minutes, seconds]





func _on_match_ended(sili_won: bool) -> void:
	match_label.text = "Sili wins!" if sili_won else "Tubig survives!"
	_record_round_result(sili_won)


## Server only. Reads the final state of every Tubig off this machine's own
## copy of the world and hands it to SeriesManager, which owns the points.
##
## What counts as "out" depends on WHY the match ended:
##   - Sili won: _check_for_sili_win only ever calls this when every remaining
##     Tubig is BURNING or DEAD - nobody was left free to run a rescue. A
##     player still mid-burn at that instant is not "still savable" the way
##     the time-expiry case below is; the round ended precisely because no
##     save was possible, so BURNING counts as caught here.
##   - Tubig survived (time expired): a burning player at the buzzer genuinely
##     might have been rescued a second later, so only DEAD (fully burned out)
##     counts as out - anyone still standing, tagged or not, gets credit for
##     lasting the match.
## Without this split, a Sili who tags every Tubig and wins on the wipe check
## (before anyone's burn timer actually expires) saw every Tubig scored as
## "survived" and zero eliminations credited - a full wipe that paid nothing.
##
## Each caught Tubig also carries a "fraction" - how much of the match they
## were free before that final catch (HeatStatus.survived_fraction()) - so
## SeriesManager can scale their survival points by it: caught in the first
## few seconds pays nothing, caught with the buzzer in sight pays almost the
## full survival bonus, instead of every "out" flatly scoring zero regardless
## of how long the chase actually lasted.
##
## Rescues are not tallied here: SeriesManager already counted them one by one
## as they were validated, which is the only way to know who performed each.
func _record_round_result(sili_won: bool) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		print("[SCORE-DEBUG] _record_round_result skipped - not server")
		return
	if not SeriesManager.is_active:
		print("[SCORE-DEBUG] _record_round_result skipped - SeriesManager not active (practice match)")
		return  # practice match - nothing to score

	# _live_tubig_bodies(), not the cached _tubig_players: the same staleness
	# _check_for_sili_win was fixed for above applies here too - _tubig_players
	# is only rewritten by _refresh_team_state, so a round that ends via a
	# departure handled in the same frame (_on_player_left's deferred refresh
	# hasn't necessarily run relative to this call) could otherwise score off
	# a roster that no longer matches who is actually in the match.
	var outcomes: Dictionary = {}
	for tubig in _live_tubig_bodies():
		var peer_id := _peer_id_for(tubig)
		if peer_id == 0:
			continue
		var heat: HeatStatus = tubig.get_node_or_null("HeatStatus")
		var caught: bool = heat != null and (heat.is_dead() or (sili_won and heat.is_incapacitated()))
		outcomes[peer_id] = {
			"out": caught,
			"fraction": heat.survived_fraction() if (caught and heat != null) else 1.0,
		}

	print("[SCORE-DEBUG] _record_round_result: sili_won=%s _tubig_players=%s sili_peer=%d outcomes=%s" % [
		sili_won, _tubig_players, _sili_peer_id(), outcomes])
	SeriesManager.record_round(_sili_peer_id(), outcomes)


func _sili_peer_id() -> int:
	for peer_id in NetworkManager.roles:
		if NetworkManager.roles[peer_id] == "sili":
			return peer_id
	return 0
