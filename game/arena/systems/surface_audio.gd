extends Node
class_name SurfaceAudio

## Gives a player footsteps that match the tile they're standing on, plus the
## ocean loop that swells as they get near the water. Add as a child of a
## Tubig or Sili - both create one in their own _ready().
##
## Surface detection reads the level's TileMapLayers directly rather than
## keeping a parallel "what's the ground here" map, so it can never fall out
## of sync with a hand-edited level: whatever layer you painted a tile on is
## what you hear. Layers are tested in SURFACE_LAYERS order and the first one
## with a tile at the player's cell wins, so a road painted over sand sounds
## like road.
##
## Footsteps are positional (AudioStreamPlayer2D) so you can hear another
## player running past you, which matters a lot in a hide-and-seek game.
## The ambience is non-positional and only runs for the player you're
## actually controlling.

## Layer node path under the level's Map node -> surface name. Order is
## priority, most specific ground first. Add a row here when you add a layer.
const SURFACE_LAYERS: Array = [
	["road", "road"],
	["stairs", "stairs"],
	["grass", "grass"],
	["sand", "sand"],
	["sandfade", "sand"],
	["sea", "water"],
]

const DEFAULT_SURFACE := "sand"

## Where each surface's step samples are expected to live. Files are optional:
## anything missing simply stays silent, so the game runs fine before the
## footstep pack is dropped in. Drop numbered .wav files into these folders
## (walk_01.wav, walk_02.wav, ... run_01.wav, ...) and they get picked up.
const FOOTSTEP_DIR := "res://game/assets/audio/footsteps"
const MAX_VARIANTS := 12

## Seconds between steps. Running is quicker AND louder - that's the whole
## risk/reward of the sprint button in a game about not being found.
const WALK_INTERVAL := 0.42
const RUN_INTERVAL := 0.26
const WALK_DB := -6.0
const RUN_DB := 0.0
const PITCH_JITTER := 0.12

const AMBIENCE_STREAM := "res://game/assets/audio/ambiance/Ambiance_Ocean_Praia_dos_Moinhos_Loop_Stereo_02.wav"
## Ocean is at full volume standing in the surf and gone this many tiles inland.
const AMBIENCE_MAX_TILES := 16
const AMBIENCE_MAX_DB := -2.0
const AMBIENCE_MIN_DB := -34.0
## Searching outward for water every frame would be wasteful; a few times a
## second is far faster than a player can cross the beach.
const AMBIENCE_POLL := 0.25

var _player: Node2D
var _is_local: bool = false
## Anything above this counts as running. Passed in by the player rather than
## read off it, because reaching into another script for a constant is exactly
## the kind of coupling that breaks the moment one role is retuned.
var _run_threshold: float = 140.0
var _layers: Dictionary = {}          # surface name -> Array[TileMapLayer], in priority order
var _ordered_layers: Array = []       # [TileMapLayer, surface] pairs, priority order
var _steps: Dictionary = {}           # "grass_walk" -> Array[AudioStream]
var _step_player: AudioStreamPlayer2D
var _ambience: AudioStreamPlayer
var _step_accumulator := 0.0
var _ambience_accumulator := 999.0
var _current_surface := DEFAULT_SURFACE


func setup(player: Node2D, is_local_player: bool, run_threshold: float) -> void:
	_player = player
	_is_local = is_local_player
	_run_threshold = run_threshold


func _ready() -> void:
	if _player == null:
		_player = get_parent() as Node2D

	_step_player = AudioStreamPlayer2D.new()
	_step_player.name = "StepPlayer"
	_step_player.bus = "Footsteps"
	# Steps should carry across a courtyard but not the whole beach.
	_step_player.max_distance = 320.0
	_step_player.attenuation = 2.0
	add_child(_step_player)

	var ocean := AudioManager.load_ocean_loop() if _is_local else null
	if ocean != null:
		_ambience = AudioStreamPlayer.new()
		_ambience.name = "Ambience"
		_ambience.bus = "Ambience"
		# Looping is forced by load_ocean_loop(); a one-shot here would fade in
		# as you neared the water and then simply stop.
		_ambience.stream = ocean
		_ambience.volume_db = GameSettings.MIN_DB
		add_child(_ambience)
		_ambience.play()

	_load_step_banks()
	call_deferred("_find_layers")


## The level finishes building after the player spawns into it, so the layer
## lookup waits a frame rather than racing the arena's own _ready().
func _find_layers() -> void:
	var map := _find_map()
	if map == null:
		return
	for entry in SURFACE_LAYERS:
		var layer := map.get_node_or_null(NodePath(entry[0])) as TileMapLayer
		if layer == null:
			continue
		_ordered_layers.append([layer, entry[1]])
		if not _layers.has(entry[1]):
			_layers[entry[1]] = []
		_layers[entry[1]].append(layer)


func _find_map() -> Node:
	var node := _player.get_parent()
	while node != null:
		var map := node.get_node_or_null("Map")
		if map != null:
			return map
		node = node.get_parent()
	return null


## Loads whatever step samples actually exist. ResourceLoader.exists() keeps a
## missing pack from spamming load errors on every single footstep.
func _load_step_banks() -> void:
	for entry in SURFACE_LAYERS:
		var surface: String = entry[1]
		for gait in ["walk", "run"]:
			var key := "%s_%s" % [surface, gait]
			if _steps.has(key):
				continue
			var bank: Array[AudioStream] = []
			for i in range(1, MAX_VARIANTS + 1):
				var path := "%s/%s/%s_%02d.wav" % [FOOTSTEP_DIR, surface, gait, i]
				if ResourceLoader.exists(path):
					bank.append(load(path))
			_steps[key] = bank


func _physics_process(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return

	_current_surface = _surface_under_player()

	var speed: float = _player.velocity.length()
	if speed > 5.0:
		var running: bool = speed > _run_threshold
		_step_accumulator += delta
		var interval := RUN_INTERVAL if running else WALK_INTERVAL
		if _step_accumulator >= interval:
			_step_accumulator = 0.0
			_play_step(running)
	else:
		# Prime the timer so the very first step after standing still is
		# immediate instead of arriving a beat late.
		_step_accumulator = WALK_INTERVAL

	if _ambience:
		_ambience_accumulator += delta
		if _ambience_accumulator >= AMBIENCE_POLL:
			_ambience_accumulator = 0.0
			_update_ambience()


## Walks the layers in priority order and returns the first one with a tile
## under the player. Falls back to sand so a player standing in an unpainted
## gap still makes a noise.
func _surface_under_player() -> String:
	for pair in _ordered_layers:
		var layer: TileMapLayer = pair[0]
		if not is_instance_valid(layer):
			continue
		var cell := layer.local_to_map(layer.to_local(_player.global_position))
		if layer.get_cell_source_id(cell) != -1:
			return pair[1]
	return DEFAULT_SURFACE


func _play_step(running: bool) -> void:
	var key := "%s_%s" % [_current_surface, "run" if running else "walk"]
	var bank: Array = _steps.get(key, [])
	if bank.is_empty():
		# Fall back to the walk bank so a surface with only walk samples still
		# sounds like something when you sprint over it.
		bank = _steps.get("%s_walk" % _current_surface, [])
	if bank.is_empty():
		return

	_step_player.stream = bank[randi() % bank.size()]
	_step_player.volume_db = RUN_DB if running else WALK_DB
	# Identical samples back to back read as a machine gun; a little pitch
	# wobble is enough to make a short loop sound like real footfalls.
	_step_player.pitch_scale = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER)
	_step_player.global_position = _player.global_position
	_step_player.play()


func _update_ambience() -> void:
	var tiles := _tiles_to_water()
	if tiles < 0:
		_ambience.volume_db = GameSettings.MIN_DB
		return
	var closeness := 1.0 - clampf(float(tiles) / float(AMBIENCE_MAX_TILES), 0.0, 1.0)
	if closeness <= 0.0:
		_ambience.volume_db = GameSettings.MIN_DB
		return
	_ambience.volume_db = lerpf(AMBIENCE_MIN_DB, AMBIENCE_MAX_DB, closeness)


## Expanding-ring search out to AMBIENCE_MAX_TILES. Bounded and early-exiting,
## which beats measuring against every sea tile on a large map.
func _tiles_to_water() -> int:
	var water_layers: Array = _layers.get("water", [])
	if water_layers.is_empty():
		return -1

	var layer: TileMapLayer = water_layers[0]
	if not is_instance_valid(layer):
		return -1
	var origin := layer.local_to_map(layer.to_local(_player.global_position))

	for radius in range(0, AMBIENCE_MAX_TILES + 1):
		for offset in _ring_offsets(radius):
			if layer.get_cell_source_id(origin + offset) != -1:
				return radius
	return -1


## Cells exactly `radius` steps from the centre (Chebyshev), i.e. the square
## shell only - the interior was already covered by smaller radii.
func _ring_offsets(radius: int) -> Array:
	if radius == 0:
		return [Vector2i.ZERO]
	var offsets: Array = []
	for x in range(-radius, radius + 1):
		offsets.append(Vector2i(x, -radius))
		offsets.append(Vector2i(x, radius))
	for y in range(-radius + 1, radius):
		offsets.append(Vector2i(-radius, y))
		offsets.append(Vector2i(radius, y))
	return offsets
