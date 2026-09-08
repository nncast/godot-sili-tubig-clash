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
## Burn countdown next to a tagged teammate's dot - amber while the run is
## still worth making, red once it probably isn't.
const BURN_TIMER_COLOR := Color(1.0, 0.78, 0.30)
const BURN_TIMER_URGENT_COLOR := Color(1.0, 0.42, 0.36)
## Escape (tunnel trip) counter on each row. Purple, matching the tunnel mouth
## in tunnel.gd and the tagged-teammate guide line on the mini-map - the map
## already teaches that purple means "the tunnel network", so the counter joins
## that vocabulary instead of inventing a fifth colour.
const ESCAPE_COLOR := Color(0.72, 0.52, 0.95)
const ESCAPE_SPENT_COLOR := Color(0.45, 0.45, 0.48)
const ESCAPE_GLYPH := "⇄"

@onready var match_label: Label = $HUD/MatchLabel
@onready var team_panel: VBoxContainer = $HUD/TeamPanel
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
@onready var close_settings_button: Button = $HUD/SettingsPopup/VBox/CloseButton
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
var _spectator: SpectatorView = null
var _danger_music: DangerMusic = null

## Every signal this panel wired up on the LAST rebuild, so the next rebuild can
## unwire them. Without this the closures below outlive the rows they capture:
## _build_team_panel frees the old rows but leaves their update_hearts/update_dot
## still connected to each Tubig, and the next tag or rescue calls them against a
## freed TextureRect - a runtime error mid-match rather than a wrong colour.
var _panel_connections: Array = []


## Only used if Map/SpawnPoints is missing or has no marker for a role - the
## real positions come from the SpawnPoint nodes you drag around in the editor.
## Keeping a fallback means deleting a marker mid-edit can't crash a match.
##
## These are OFFSETS from the map's own centre, not world coordinates. They
## used to be raw coordinates clustered around (0, 0), which is only the middle
## of the level if the level happens to be painted around the origin - this one
## is painted a couple of thousand pixels out, so every fallback spawn landed
## far off the tilemap in empty space. An offset from wherever the ground
## actually is degrades to "somewhere in the middle of the map" for any map.
const FALLBACK_SPAWN_OFFSETS: Array[Vector2] = [
	Vector2(-40, -40), Vector2(60, 40), Vector2(-60, 60),
	Vector2(80, -60), Vector2(-90, -20), Vector2(30, 90),
]


func _ready() -> void:
	_load_map()

	sili_spawner.spawn_function = _spawn_sili
	tubig_spawner.spawn_function = _spawn_tubig
	sili_spawner.spawned.connect(_on_player_spawned)
	tubig_spawner.spawned.connect(_on_player_spawned)
	# Despawn matters as much as spawn. Without it the team panel keeps a row
	# for a player who is no longer in the match, with a status dot that will
	# never change again.
	sili_spawner.despawned.connect(_on_player_despawned)
	tubig_spawner.despawned.connect(_on_player_despawned)

	MatchManager.time_updated.connect(_on_time_updated)
	MatchManager.match_ended.connect(_on_match_ended)
	NetworkManager.player_left.connect(_on_player_left)

	_setup_settings_popup()

	# Bake the mini-map straight off the level's own tilemap, bottom-up, so it
	# can never drift out of sync with the map the players are running around
	# in. We hand it the Map node rather than one layer: build_from_node walks
	# the children itself, so every painted layer (sea, sand, grass, road,
	# buildings...) ends up in the bake.
	minimap.build_from_node(map_instance)

	# Only the host decides who spawns where and starts the clock.
	if NetworkManager.is_host():
		SightingTracker.reset()
		_spawn_all_players()
		MatchManager.start_match()

	# Everyone (not just the host) needs to see the team status panel, so
	# this runs on every peer - only the win-check inside it is server-gated.
	call_deferred("_refresh_team_state")


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
		var offset := FALLBACK_SPAWN_OFFSETS[index % FALLBACK_SPAWN_OFFSETS.size()]
		return container.to_local(_map_centre() + offset)
	var marker: SpawnPoint = markers[index % markers.size()]
	return container.to_local(marker.global_position)


## Middle of the painted ground, in world space. Measured off the tilemap
## layers themselves for the same reason the mini-map bakes from them: it is
## the one description of where the level is that cannot drift from the level.
func _map_centre() -> Vector2:
	if map_instance == null:
		return Vector2.ZERO

	var bounds := Rect2()
	var found := false
	for node in map_instance.find_children("*", "TileMapLayer", true, false):
		var layer := node as TileMapLayer
		if layer == null:
			continue
		var used: Rect2i = layer.get_used_rect()
		if used.size == Vector2i.ZERO:
			continue
		var tile_size: Vector2 = Vector2(layer.tile_set.tile_size) if layer.tile_set else Vector2(16, 16)
		var top_left: Vector2 = layer.to_global(Vector2(used.position) * tile_size)
		var bottom_right: Vector2 = layer.to_global(Vector2(used.end) * tile_size)
		var layer_rect := Rect2(top_left, bottom_right - top_left)
		bounds = layer_rect if not found else bounds.merge(layer_rect)
		found = true

	return bounds.get_center() if found else map_instance.global_position


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


## Deferred: this fires while the spawner is removing the node, so the node is
## still in the tree and would still be counted by get_nodes_in_group().
func _on_player_despawned(_node: Node) -> void:
	call_deferred("_refresh_team_state")


## Someone quit. Their character does NOT leave with them - the server spawned
## it, so nothing on the network takes it away - and a body left standing there
## is not just cosmetic:
##
##   - _check_for_sili_win reads it as a Tubig still on their feet, so the Sili
##     can never win. The match then always runs the full clock out, which is
##     the "it just hangs after someone leaves" symptom.
##   - Nobody can control it, so it cannot be tagged into a state that would
##     release the match either. It simply stands in the sand.
##
## Freeing it on the server despawns it everywhere, because MultiplayerSpawner
## replicates the removal of anything it spawned.
func _on_player_left(peer_id: int, display_name: String) -> void:
	# NetworkManager outlives the arena, so this signal can arrive mid-teardown.
	if not is_inside_tree():
		return
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return

	var was_sili: bool = false
	# Typed explicitly: an untyped array literal yields Variant elements, and
	# get_node_or_null() on a Variant has no inferable return type.
	var containers: Array[Node2D] = [sili_container, tubig_container]
	for container in containers:
		var body: Node = container.get_node_or_null("player_%d" % peer_id)
		if body == null:
			continue
		was_sili = body.is_in_group("sili")
		container.remove_child(body)
		body.queue_free()

	_refresh_team_state()

	# A match with no Sili has nobody who can end it. Letting the clock run out
	# gets to the same verdict three minutes later, having made four people
	# stand around to watch it happen.
	if was_sili and MatchManager.is_running:
		MatchManager.broadcast_event(
			"%s was the Sili - the round is over." % MatchManager.sili_name(display_name),
			"warning")
		MatchManager.end_match(false)
		return

	_check_for_sili_win()


func _refresh_team_state() -> void:
	# This used to be reachable only from the spawner's `spawned` signal, which
	# can only fire while the arena is in the tree. It now also arrives from a
	# DEFERRED despawn and from NetworkManager.player_left, and both of those
	# can land after the arena has been pulled out of the tree - a player
	# quitting during the scene change into the next round is enough. get_tree()
	# is null at that point, so every read below would fail.
	if not is_inside_tree():
		return

	var previous_players := _tubig_players
	_tubig_players = get_tree().get_nodes_in_group("tubig")

	for tubig in _tubig_players:
		var heat: HeatStatus = tubig.get_node_or_null("HeatStatus")
		if heat and not heat.burned.is_connected(_check_for_sili_win):
			heat.burned.connect(_check_for_sili_win)
			heat.died.connect(_check_for_sili_win)

	# Compares the actual roster, not just how big it is. The old test was
	# `size() != previous_count`, which misses the case where one player leaves
	# and another spawns before the next refresh: the count is unchanged, so
	# the panel kept a row wired to a freed body and showed a departed player's
	# name with a dot that would never update again. Cheap for a handful of
	# rows, and correct no matter what order peers finish spawning in.
	if _tubig_players != previous_players:
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
	# Same signal, two senses: the vignette shows the Sili closing in, the
	# sting lets you hear it. Both are Tubig-only and neither reveals direction.
	_ensure_danger_music().track_player(local_player, not is_sili)

	# Only a Tubig can be eliminated, so the Sili never needs one of these.
	if not is_sili and local_player != null:
		_ensure_spectator().watch_local_player(local_player)


## Created on demand and only once. _configure_local_hud runs again every time
## a peer finishes spawning, and a second SpectatorView would mean a second
## Camera2D quietly fighting the first for the viewport.
## Created on demand and only once, for the same reason as the spectator:
## _configure_local_hud runs again on every spawn, and a second DangerMusic
## would mean two nodes racing to start and stop the same sting.
func _ensure_danger_music() -> DangerMusic:
	if _danger_music != null and is_instance_valid(_danger_music):
		return _danger_music
	_danger_music = DangerMusic.new()
	_danger_music.name = "DangerMusic"
	add_child(_danger_music)
	return _danger_music


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

		# Seconds left before this teammate's burn goes permanent, sat right
		# next to the status dot.
		#
		# The red dot said someone was tagged. It did not say whether a rescue
		# was still possible, and the rescue channel alone eats six of the
		# thirty seconds - so without the number, deciding whether to make the
		# run across the map was a guess. With it, it's arithmetic.
		#
		# Fixed width and always present (blank when nobody is burning) so the
		# name and hearts don't slide sideways every time a tag lands.
		var burn_label := Label.new()
		burn_label.custom_minimum_size = Vector2(26, 0)
		burn_label.add_theme_font_size_override("font_size", 13)
		burn_label.add_theme_color_override("font_color", BURN_TIMER_COLOR)
		burn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		burn_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		burn_label.text = ""
		row.add_child(burn_label)

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

		var heat: HeatStatus = tubig.get_node_or_null("HeatStatus")

		var heart_icons: Array = []
		# Sized off the Tubig's own MAX_LIVES rather than a hardcoded 3, so
		# retuning lives for a playtest can't leave the panel drawing three
		# hearts for a player who has five. Falls back to 3 if HeatStatus
		# somehow isn't there yet, which is the value the scene ships with.
		var heart_count: int = heat.MAX_LIVES if heat != null else 3
		for i in maxi(1, heart_count):
			var heart := TextureRect.new()
			heart.custom_minimum_size = Vector2(14, 14)
			heart.texture = HEART_TEXTURE
			heart.expand_mode = 1
			heart.stretch_mode = 5
			hearts_row.add_child(heart)
			heart_icons.append(heart)

		# Each Tubig's OWN escape budget, one number per row.
		#
		# This column exists because "are the escape counts shared?" was a
		# question the HUD gave you no way to answer: the count only ever
		# appeared in your own tunnel prompt, so if one player spent two trips
		# there was nothing on screen to confirm that everybody else still had
		# theirs. Four separate numbers side by side settle it at a glance, and
		# they also make the resource readable as a team - you can see who can
		# still cross the map to reach a burning ally and who is walking.
		#
		# Fed by the replicated tunnel_uses_left, so these are the real values
		# from each owner's machine, not a local guess.
		var escape_label := Label.new()
		escape_label.custom_minimum_size = Vector2(34, 0)
		escape_label.add_theme_font_size_override("font_size", 13)
		escape_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		escape_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		escape_label.tooltip_text = "Escapes (tunnel trips) left"
		row.add_child(escape_label)

		var update_escapes := func(uses_left: int):
			if not is_instance_valid(row) or not is_instance_valid(escape_label):
				return
			escape_label.text = "%s%d" % [ESCAPE_GLYPH, uses_left]
			escape_label.add_theme_color_override("font_color",
				ESCAPE_SPENT_COLOR if uses_left <= 0 else ESCAPE_COLOR)

		if tubig.has_signal("escapes_changed"):
			_track_connection(tubig, &"escapes_changed", update_escapes)
			update_escapes.call(int(tubig.get("tunnel_uses_left")))

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

		# Blank unless they are actually Burning. A DEAD player's last count
		# would freeze at some arbitrary number and read as "still savable",
		# which is the exact decision this label exists to get right.
		var update_burn_timer := func(seconds_left: int):
			if not is_instance_valid(row) or not is_instance_valid(burn_label):
				return
			if heat and heat.is_burning() and seconds_left > 0:
				burn_label.text = "%ds" % seconds_left
				# Turns red under ten seconds - past the six-second channel
				# plus travel, the run has usually stopped being worth it.
				burn_label.add_theme_color_override("font_color",
					BURN_TIMER_URGENT_COLOR if seconds_left <= 10 else BURN_TIMER_COLOR)
			else:
				burn_label.text = ""

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
				# A state flip (rescued, or timed out) has to clear the number
				# immediately; waiting for the next burn_time_changed would
				# leave a stale countdown next to a blue or grey dot.
				update_burn_timer.call(heat.burn_seconds_left)
		if heat:
			_track_connection(heat, &"state_changed", update_dot)
			_track_connection(heat, &"lives_changed", update_hearts)
			_track_connection(heat, &"burn_time_changed", update_burn_timer)
			update_dot.call(heat.state)
			update_hearts.call(heat.lives_left)
			update_burn_timer.call(heat.burn_seconds_left)


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

	# The contract asks for SpawnPoints as a direct child, but a map that
	# buries it one level deeper is a placement mistake, not a reason to throw
	# every player at the fallback coordinates - which is a silent failure that
	# looks like "the spawns don't work" rather than like a broken map. Search
	# the whole subtree before giving up, and say so loudly enough to get fixed.
	if spawn_points_root == null:
		var found := map_instance.find_children("SpawnPoints", "Node2D", true, false)
		if not found.is_empty():
			spawn_points_root = found[0]
			push_warning(
				"Arena: map '%s' has SpawnPoints at '%s' instead of the map root. Using it anyway - see the contract in map_registry.gd." % [
					map_id, map_instance.get_path_to(spawn_points_root)])

	if spawn_points_root == null:
		push_error("Arena: map '%s' has no SpawnPoints - see the contract in map_registry.gd." % map_id)


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


## The Sili wins once no Tubig can still be rescued.
##
## Waiting for every Tubig to be DEAD was too slow at the end. A burn is only
## temporary because a TEAMMATE can come and undo it, and a teammate who is
## themselves burning or dead cannot: heat_status.gd's request_cool_fully
## rejects an incapacitated rescuer, and rejects rescuing yourself. So the
## moment the last free Tubig is tagged, every burn still running is already
## decided - the players just sat and watched the burn clock tick down for
## thirty seconds before the game agreed with them.
##
## The condition is therefore "nobody is in NORMAL state", not "everybody is
## DEAD". That still protects the case the burn window exists for: as long as
## one Tubig is on their feet, the match keeps running and the rescue is live,
## however many teammates are burning.
func _check_for_sili_win() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	if _tubig_players.is_empty():
		return  # nothing spawned yet; nothing to decide

	var free_tubigs := 0
	var doomed_burns := 0
	for tubig in _tubig_players:
		if not is_instance_valid(tubig):
			continue
		var heat: HeatStatus = tubig.get_node_or_null("HeatStatus")
		if heat == null or heat.is_dead():
			continue
		if heat.is_burning():
			doomed_burns += 1
		else:
			free_tubigs += 1

	if free_tubigs > 0:
		return  # someone is still up, so a rescue is still possible

	# Says WHY the match ended here rather than at the buzzer, so the last
	# player tagged doesn't read it as the clock being cut short.
	if doomed_burns > 0:
		MatchManager.broadcast_event(
			"No Tubig left standing - the burns can't be undone.", "warning")
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
