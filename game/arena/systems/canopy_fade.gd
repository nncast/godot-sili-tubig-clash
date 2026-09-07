extends TileMapLayer

## Attach to the "over" TileMapLayers - the tree canopies and building roofs
## drawn at z_index 21, above the players.
##
## Those layers sit in front of characters so you can walk behind a palm or
## under a roof. Without this they would hide you forever, since nothing ever
## gets out of the way.
##
## WHY THIS IS A SHADER AND NOT modulate.a
##
## modulate belongs to the whole CanvasItem, and a TileMapLayer is one
## CanvasItem - so fading through it fades EVERY tree in the layer at once, not
## the one you happen to be standing under. There is no per-cell alpha on a
## tilemap. The only ways to give individual canopies their own alpha are to
## turn each one into a node (a few hundred extra nodes, and they drop out of
## the mini-map bake, which walks TileMapLayers) or to mask in the fragment
## stage. This does the second.
##
## ONLY the locally controlled character triggers the fade. That is a gameplay
## rule, not an optimisation: in a hide-and-seek game, a roof going transparent
## because a *remote* player walked under it would broadcast their position to
## everyone looking at that part of the map.

enum FadeMode {
	## Fade the whole connected clump of tiles the player is under, found by a
	## flood fill. Correct for a lone palm or a single roof: the object lifts as
	## one piece.
	CLUSTER,
	## Fade a soft circle around the player. Correct where the canopy is painted
	## as one continuous mass and there is no single tree to isolate.
	RADIAL,
	## CLUSTER when the clump is small enough to be one object, RADIAL when it
	## turns out to be a blob. This is the sane default: the same layer can hold
	## both a few scattered palms and a dense patch, and this picks per contact
	## rather than per layer.
	AUTO,
}

@export var fade_mode: FadeMode = FadeMode.AUTO

## Alpha while you are underneath. Not 0 - a faint canopy reads as "you are
## under something", where clearing it fully just looks like the art vanished.
@export var faded_alpha: float = 0.3

## How fast the fade settles, in alpha units per second. Slow enough to read as
## a fade rather than a flicker when you clip the corner of a canopy.
@export var fade_speed: float = 4.0

## Tiles around the player that also count as "underneath". A character is
## taller than one cell, so testing only the cell under their origin makes the
## canopy snap back while their head is still covered.
@export var cover_radius: int = 1

## Above this many cells, a connected clump is treated as scenery rather than
## as one object, and AUTO switches to the circular mask. Sized off the actual
## map: the palms on sand come in clumps of 15-30 cells, so 64 keeps every real
## tree whole while still catching the 629-cell mass on the grass layer.
@export var max_cluster_cells: int = 64

## Radius of the circular mask, in pixels, used by RADIAL and by AUTO's
## fallback. Roughly three tiles - enough to clear the character and their
## immediate surroundings without opening a hole you can see the whole map
## through.
@export var radial_radius: float = 52.0

## Safety valve on the flood fill. A pathological layer (every cell painted)
## would otherwise walk the entire map on the frame you step under it.
const MAX_FLOOD_CELLS := 4096

var _blend: float = 0.0          # 0 = fully opaque, 1 = fully faded
var _target_blend: float = 0.0
var _local_player: Node2D = null
var _material: ShaderMaterial = null

## The clump found last time, cached against the seed cell. Recomputing a flood
## fill every frame while a player stands still under one tree would be pure
## waste; the answer cannot change until they move to a different cell.
var _cached_seed: Vector2i = Vector2i(2147483647, 2147483647)
var _cached_rect: Rect2 = Rect2()
var _cached_is_blob: bool = false


func _ready() -> void:
	var shader: Shader = load("res://game/arena/systems/canopy_fade.gdshader")
	if shader == null:
		push_warning("canopy_fade: shader missing; this layer will not fade.")
		set_physics_process(false)
		return

	# Built here rather than assigned in the .tscn so every layer gets its OWN
	# material. A material shared between two layers would share its uniforms
	# too, and the second layer to write fade_rect each frame would win.
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter("faded_alpha", faded_alpha)
	_material.set_shader_parameter("blend", 0.0)
	material = _material


func _physics_process(delta: float) -> void:
	_refresh_local_player()

	# Untyped on purpose: _covering_cell() returns either a Vector2i or null,
	# which is a Variant, and := would try to infer a concrete type from it.
	var seed_cell = _covering_cell()
	_target_blend = 0.0 if seed_cell == null else 1.0

	if seed_cell != null:
		_apply_mask(seed_cell)

	if is_equal_approx(_blend, _target_blend):
		return
	_blend = move_toward(_blend, _target_blend, fade_speed * delta)
	_material.set_shader_parameter("blend", _blend)


## Chooses the mask shape and pushes it to the shader. Only recomputes the
## flood fill when the player crosses into a different cell.
func _apply_mask(seed_cell: Vector2i) -> void:
	# RADIAL never looks at the clump, so don't pay for the flood fill. Only
	# AUTO needs it to decide, and only CLUSTER needs the rect it produces.
	if fade_mode == FadeMode.RADIAL:
		_set_radial()
		return

	if seed_cell != _cached_seed:
		_cached_seed = seed_cell
		var cluster := _flood_fill(seed_cell)
		_cached_is_blob = cluster.size() > max_cluster_cells
		_cached_rect = _local_rect_for(cluster)

	if fade_mode == FadeMode.AUTO and _cached_is_blob:
		_set_radial()
		return

	_material.set_shader_parameter("fade_radius", 0.0)
	_material.set_shader_parameter(
		"fade_rect", Vector4(_cached_rect.position.x, _cached_rect.position.y,
			_cached_rect.size.x, _cached_rect.size.y))


## to_local, because the shader reads VERTEX - which is already in this layer's
## space. Converting here means both sides agree by construction instead of by
## assumption about how tilemap quads get batched.
func _set_radial() -> void:
	_material.set_shader_parameter("fade_center", to_local(_local_player.global_position))
	_material.set_shader_parameter("fade_radius", radial_radius)


## Breadth-first walk over painted, edge-connected cells. Diagonals are
## deliberately NOT followed: two palms whose canopies touch only at a corner
## are two trees, and treating them as one would fade both.
func _flood_fill(start: Vector2i) -> Array:
	var seen := {start: true}
	var queue: Array[Vector2i] = [start]
	var found: Array[Vector2i] = []
	const NEIGHBOURS: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

	while not queue.is_empty() and found.size() < MAX_FLOOD_CELLS:
		var cell: Vector2i = queue.pop_front()
		found.append(cell)
		# Stop expanding as soon as we know it's a blob - the exact size stops
		# mattering past the threshold, and the rect gets thrown away anyway.
		if found.size() > max_cluster_cells and fade_mode != FadeMode.CLUSTER:
			break
		for offset in NEIGHBOURS:
			var next: Vector2i = cell + offset
			if seen.has(next):
				continue
			seen[next] = true
			if get_cell_source_id(next) != -1:
				queue.append(next)

	return found


## Bounding box of a set of cells, in this layer's local space, expanded to the
## outer edges of the tiles rather than their centres - map_to_local returns a
## cell's centre, so a rect built straight from it would clip half a tile off
## every side of the canopy.
func _local_rect_for(cells: Array) -> Rect2:
	if cells.is_empty():
		return Rect2()

	var first: Vector2i = cells[0]
	var min_cell := first
	var max_cell := first
	for cell in cells:
		min_cell.x = mini(min_cell.x, cell.x)
		min_cell.y = mini(min_cell.y, cell.y)
		max_cell.x = maxi(max_cell.x, cell.x)
		max_cell.y = maxi(max_cell.y, cell.y)

	var half := Vector2(tile_set.tile_size) * 0.5
	var top_left := map_to_local(min_cell) - half
	var bottom_right := map_to_local(max_cell) + half
	return Rect2(top_left, bottom_right - top_left)


## The local character is respawned on replay, so the cached reference is
## re-resolved whenever it goes stale rather than looked up once in _ready().
func _refresh_local_player() -> void:
	if is_instance_valid(_local_player):
		return
	_local_player = null
	for node in get_tree().get_nodes_in_group("player"):
		var character := node as Node2D
		if character == null:
			continue
		if not character.is_multiplayer_authority():
			continue
		_local_player = character
		return


## The painted cell covering the player, or null if they are in the open.
##
## Returns the CLOSEST covering cell rather than the first one found, so the
## flood fill seeds inside the canopy the player is actually under when two
## different trees both have a cell within cover_radius.
func _covering_cell() -> Variant:
	if _local_player == null:
		return null

	var local_pos := to_local(_local_player.global_position)
	var origin := local_to_map(local_pos)
	var best: Vector2i = Vector2i.ZERO
	var best_distance := INF
	var found := false

	for dy in range(-cover_radius, cover_radius + 1):
		for dx in range(-cover_radius, cover_radius + 1):
			var cell := origin + Vector2i(dx, dy)
			if get_cell_source_id(cell) == -1:
				continue
			var distance := local_pos.distance_squared_to(map_to_local(cell))
			if distance < best_distance:
				best_distance = distance
				best = cell
				found = true

	return best if found else null
