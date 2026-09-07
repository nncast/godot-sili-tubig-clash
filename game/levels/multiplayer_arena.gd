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

@onready var match_label: Label = $HUD/MatchLabel
@onready var team_panel: VBoxContainer = $HUD/TeamPanel
@onready var settings_button: Button = $HUD/SettingsButton
@onready var settings_popup: PanelContainer = $HUD/SettingsPopup
@onready var master_slider: HSlider = $HUD/SettingsPopup/VBox/MasterRow/MasterSlider
@onready var music_slider: HSlider = $HUD/SettingsPopup/VBox/MusicRow/MusicSlider
@onready var sfx_slider: HSlider = $HUD/SettingsPopup/VBox/SFXRow/SFXSlider
@onready var ambience_slider: HSlider = $HUD/SettingsPopup/VBox/AmbienceRow/AmbienceSlider
@onready var close_settings_button: Button = $HUD/SettingsPopup/VBox/CloseButton
@onready var sili_spawner: MultiplayerSpawner = $SiliSpawner
@onready var tubig_spawner: MultiplayerSpawner = $TubigSpawner
@onready var sili_container: Node2D = $Map/SiliContainer
@onready var tubig_container: Node2D = $Map/TubigContainer
@onready var spawn_points_root: Node2D = $Map/SpawnPoints
@onready var minimap: Control = $HUD/Minimap
@onready var threat_vignette: Control = $ThreatLayer/ThreatVignette

var _tubig_players: Array = []
var _spectator: SpectatorView = null

## Every signal this panel wired up on the LAST rebuild, so the next rebuild can
## unwire them. Without this the closures below outlive the rows they capture:
## _build_team_panel frees the old rows but leaves their update_hearts/update_dot
## still connected to each Tubig, and the next tag or rescue calls them against a
## freed TextureRect - a runtime error mid-match rather than a wrong colour.
var _panel_connections: Array = []


## Only used if Map/SpawnPoints is missing or has no marker for a role - the
## real positions come from the SpawnPoint nodes you drag around in the editor.
## Keeping a fallback means deleting a marker mid-edit can't crash a match.
const FALLBACK_SPAWN_POINTS: Array[Vector2] = [
	Vector2(-40, -40), Vector2(60, 40), Vector2(-60, 60),
	Vector2(80, -60), Vector2(-90, -20), Vector2(30, 90),
]


func _ready() -> void:
	sili_spawner.spawn_function = _spawn_sili
	tubig_spawner.spawn_function = _spawn_tubig
	sili_spawner.spawned.connect(_on_player_spawned)
	tubig_spawner.spawned.connect(_on_player_spawned)

	MatchManager.time_updated.connect(_on_time_updated)
	MatchManager.match_ended.connect(_on_match_ended)

	_setup_settings_popup()

	# Bake the mini-map straight off the level's own tilemap, bottom-up, so it
	# can never drift out of sync with the map the players are running around
	# in. We hand it the Map node rather than one layer: build_from_node walks
	# the children itself, so every painted layer (sea, sand, grass, road,
	# buildings...) ends up in the bake.
	minimap.build_from_node($Map)

	# Only the host decides who spawns where and starts the clock.
	if NetworkManager.is_host():
		SightingTracker.reset()
		_spawn_all_players()
		MatchManager.start_match()

	# Everyone (not just the host) needs to see the team status panel, so
	# this runs on every peer - only the win-check inside it is server-gated.
	call_deferred("_refresh_team_state")


## Placeholder in-match settings panel - just the same Master/Music/SFX
## sliders as the main Settings screen, without leaving the match scene.
func _setup_settings_popup() -> void:
	master_slider.value = GameSettings.master_volume
	music_slider.value = GameSettings.music_volume
	sfx_slider.value = GameSettings.sfx_volume
	ambience_slider.value = GameSettings.ambience_volume

	master_slider.value_changed.connect(GameSettings.set_master_volume)
	music_slider.value_changed.connect(GameSettings.set_music_volume)
	sfx_slider.value_changed.connect(GameSettings.set_sfx_volume)
	ambience_slider.value_changed.connect(GameSettings.set_ambience_volume)

	settings_button.pressed.connect(func(): settings_popup.visible = not settings_popup.visible)
	close_settings_button.pressed.connect(func(): settings_popup.visible = false)


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


## Fires locally on EVERY peer, the instant a spawn actually lands in their
## own scene tree - the correct way to know spawning finished, instead of
## guessing with a fixed timer that could be wrong on a slower connection
## and permanently leave the local HUD (or a teammate's team-panel row)
## unconfigured.
func _on_player_spawned(_node: Node) -> void:
	_refresh_team_state()


func _refresh_team_state() -> void:
	var previous_count := _tubig_players.size()
	_tubig_players = get_tree().get_nodes_in_group("tubig")

	for tubig in _tubig_players:
		var heat: HeatStatus = tubig.get_node_or_null("HeatStatus")
		if heat and not heat.burned.is_connected(_check_for_sili_win):
			heat.burned.connect(_check_for_sili_win)
			heat.died.connect(_check_for_sili_win)

	# Rebuilding is cheap for a handful of rows and keeps this correct no
	# matter what order peers finish spawning in.
	if _tubig_players.size() != previous_count:
		_build_team_panel()
	_configure_local_hud()


## The mini-map and the threat vignette both need to know which character on
## this screen is ours, and which side it's on - the map shows a different set
## of dots per team, and the vignette is Tubig-only.
func _configure_local_hud() -> void:
	var my_id := _local_peer_id()
	var is_sili: bool = NetworkManager.roles.get(my_id, "tubig") == "sili"
	var container := sili_container if is_sili else tubig_container
	var local_player := container.get_node_or_null("player_%d" % my_id) as Node2D

	minimap.configure(local_player, is_sili)
	threat_vignette.track_player(local_player, not is_sili)

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
		dot_style.set_corner_radius_all(DOT_SIZE / 2)
		dot.add_theme_stylebox_override("panel", dot_style)
		row.add_child(dot)

		# The ONLY place a player's name appears during a match. Names are
		# deliberately never drawn above characters in-world: at a glance
		# mid-chase you should be reading team colour and nothing else, so
		# picking a target out of a scattering crowd stays a real decision.
		var name_label := Label.new()
		name_label.custom_minimum_size = Vector2(96, 0)
		name_label.text = _display_name_for(tubig)
		name_label.add_theme_font_size_override("font_size", 14)
		name_label.clip_text = true
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(name_label)

		var hearts_row := HBoxContainer.new()
		hearts_row.add_theme_constant_override("separation", 2)
		row.add_child(hearts_row)

		var heart_icons: Array = []
		for i in 3:
			var heart := TextureRect.new()
			heart.custom_minimum_size = Vector2(14, 14)
			heart.texture = HEART_TEXTURE
			heart.expand_mode = 1
			heart.stretch_mode = 5
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
		if heat:
			_track_connection(heat, &"state_changed", update_dot)
			_track_connection(heat, &"lives_changed", update_hearts)
			update_dot.call(heat.state)
			update_hearts.call(heat.lives_left)


## Connects and records, so _drop_panel_connections can undo it on the next
## rebuild. Panel closures capture nodes, so they must not outlive those nodes.
func _track_connection(source: Object, signal_name: StringName, callable: Callable) -> void:
	source.connect(signal_name, callable)
	_panel_connections.append({"source": source, "signal": signal_name, "callable": callable})


func _drop_panel_connections() -> void:
	for entry in _panel_connections:
		var source: Object = entry["source"]
		if is_instance_valid(source) and source.is_connected(entry["signal"], entry["callable"]):
			source.disconnect(entry["signal"], entry["callable"])
	_panel_connections.clear()


## The Sili wins only when every Tubig is DEAD - permanently out.
##
## This used to end the match as soon as nobody was in the NORMAL state, which
## counted a burning player as already beaten. Burning is temporary by design:
## they are rooted, but a teammate has fifteen seconds to reach them. Ending
## there threw away the most dramatic moment the game has - four burning
## players and one rescue channel running - and made the rescue mechanic
## meaningless exactly when it mattered most. Now a burn has to actually time
## out for it to count.
func _check_for_sili_win() -> void:
	if not multiplayer.is_server():
		return
	for tubig in _tubig_players:
		if not is_instance_valid(tubig):
			continue
		var heat: HeatStatus = tubig.get_node_or_null("HeatStatus")
		if heat and not heat.is_dead():
			return  # someone is still free, or still savable
	MatchManager.end_match(true)


func _on_time_updated(time_remaining: float, _match_duration: float) -> void:
	var minutes := int(time_remaining) / 60
	var seconds := int(time_remaining) % 60
	# Just the clock now - tag/rescue/speed lines go to HUD/EventFeed, which has
	# room to show what actually happened instead of a bare percentage.
	match_label.text = "%d:%02d" % [minutes, seconds]





func _on_match_ended(sili_won: bool) -> void:
	match_label.text = "Sili wins!" if sili_won else "Tubig survives!"
	_record_round_result()


## Server only. Reads the final state of every Tubig off this machine's own
## copy of the world and hands it to SeriesManager, which owns the points.
##
## "Out" means DEAD - a burning player at the final whistle was still in the
## match and still savable, so they count as having survived it. Rescues are
## not tallied here: SeriesManager already counted them one by one as they
## were validated, which is the only way to know who performed each.
func _record_round_result() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	if not SeriesManager.is_active:
		return  # practice match - nothing to score

	var outcomes: Dictionary = {}
	for tubig in _tubig_players:
		if not is_instance_valid(tubig):
			continue
		var peer_id := _peer_id_for(tubig)
		if peer_id == 0:
			continue
		var heat: HeatStatus = tubig.get_node_or_null("HeatStatus")
		outcomes[peer_id] = "out" if (heat and heat.is_dead()) else "survived"

	SeriesManager.record_round(_sili_peer_id(), outcomes)


func _sili_peer_id() -> int:
	for peer_id in NetworkManager.roles:
		if NetworkManager.roles[peer_id] == "sili":
			return peer_id
	return 0
