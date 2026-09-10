extends TileMapLayer
class_name CanopyFade

## Attach to the overhead TileMapLayers - the tree canopies, umbrellas, fountain
## tops and building roofs drawn at z_index 21, above the players. Maps name
## theirs "over"; prop scenes name theirs "top", paired with a "bottom".
##
## Those layers sit in front of characters so you can walk behind a palm or
## under a roof. Without this they would hide you forever, since nothing ever
## gets out of the way.
##
## WHOLE VS THE MASKED MODES
##
## modulate belongs to the whole CanvasItem, and a TileMapLayer is one
## CanvasItem - so fading through it fades every tile in that layer at once.
##
## For a PROP that is fine, and it is what WHOLE does. palm.tscn, the umbrellas
## and the fountain each own their "top" layer outright: one object, one layer,
## so "fade the layer" and "fade the object" mean the same thing. No shader, no
## flood fill, no coordinate spaces to get wrong.
##
## The masked modes exist for a MAP-WIDE layer that holds many separate canopies
## in one CanvasItem, where fading the layer would lift every tree on the map.
## No map currently ships one - boracay builds its canopies out of prop scenes -
## so WHOLE is the default and the masked modes are for later.
##
## WHY THE MASK USED TO FADE EXACTLY ONE TILE
##
## The mask was written against `VERTEX`, on the assumption that it is in the
## layer's own space. It is not. TileMapLayer renders in QUADRANTS
## (rendering_quadrant_size, 16 tiles by default), and each quadrant is a
## separate canvas item with its own transform - so VERTEX is quadrant-local.
## The rect handed to the shader was built with map_to_local(), which is
## layer-local. The two only agree inside quadrant (0, 0).
##
## The palm's canopy is 15 cells spanning quadrants (-1,-1), (-1,0), (0,-1) and
## (0,0), so the only part that ever satisfied the rect test was the single cell
## sitting at the layer origin: one 16x16 tile out of a 64x64 canopy. Both the
## shader and this script now work in GLOBAL space, which is the one space every
## quadrant agrees on.
##
## ONLY the locally controlled character triggers the fade. That is a gameplay
## rule, not an optimisation: in a hide-and-seek game, a roof going transparent
## because a *remote* player walked under it would broadcast their position to
## everyone looking at that part of the map.

## NOTE: WHOLE was added at index 0, so the stored numbers shifted. Any scene
## that still reads `fade_mode = 0` now means WHOLE, which is the correct answer
## for every prop that had it. CLUSTER is 1 from here on.
enum FadeMode {
	## Fade the entire layer with modulate.a. Correct whenever the layer IS the
	## object - which is every prop in the game.
	WHOLE,
	## Fade the connected clump of tiles the player is under, found by a flood
	## fill. For a map-wide layer holding several distinct canopies.
	CLUSTER,
	## Fade a soft circle around the player. Correct where the canopy is painted
	## as one continuous mass and there is no single tree to isolate.
	RADIAL,
	## CLUSTER when the clump is small enough to be one object, RADIAL when it
	## turns out to be a blob, for a layer that holds both.
	AUTO,
}

@export var fade_mode: FadeMode = FadeMode.WHOLE

## Alpha while you are underneath. Not 0 - a faint canopy reads as "you are
## under something", where clearing it fully just looks like the art vanished.
##
## Lowered from 0.3 to 0.15 and now to 0.10: the fronds kept enough weight at
## 0.15 to swallow a 24px character standing under them, which defeats the
## point of fading at all. 0.10 leaves the tree's silhouette legible - you can
## still tell you are under cover - while letting you actually read yourself
## and anyone beside you.
##
## Written through a setter rather than only in _ready() so dragging this in
## the inspector updates the shader on the spot - the previous version pushed
## the value once at startup, so tuning it meant restarting the scene every
## time.
@export var faded_alpha: float = 0.10:
	set(value):
		faded_alpha = clampf(value, 0.0, 1.0)
		if _material != null:
			_material.set_shader_parameter("faded_alpha", faded_alpha)

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

## Every canopy layer joins this, so the stealth helpers at the bottom of this
## file can ask "what is over this spot" without knowing where in the scene
## any particular palm, umbrella or roof happens to live.
const GROUP := "canopy"

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
	# Before the WHOLE early-out below: a WHOLE layer still hides whoever is
	# standing under it, so it has to be findable by the stealth helpers even
	# though it needs no shader.
	add_to_group(GROUP)

	# WHOLE needs no material at all. Skipping it here is not just tidiness:
	# boracay instances forty-odd palms, and each one used to compile and hold
	# its own ShaderMaterial to run a mask that only ever covered one tile.
	if fade_mode == FadeMode.WHOLE:
		return

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

	if seed_cell != null and fade_mode != FadeMode.WHOLE:
		_apply_mask(seed_cell)

	if is_equal_approx(_blend, _target_blend):
		return
	_blend = move_toward(_blend, _target_blend, fade_speed * delta)
	_push_blend()


## The one place the current blend reaches the screen, so the two rendering
## paths cannot drift apart.
func _push_blend() -> void:
	if fade_mode == FadeMode.WHOLE:
		# Only the alpha channel, never the colour: the fountain tints its own
		# layers to show whether it is charged, and stamping a full Color here
		# would wipe that out every frame.
		modulate.a = lerpf(1.0, faded_alpha, _blend)
		return
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
		_cached_rect = _global_rect_for(cluster)

	if fade_mode == FadeMode.AUTO and _cached_is_blob:
		_set_radial()
		return

	_material.set_shader_parameter("fade_radius", 0.0)
	_material.set_shader_parameter(
		"fade_rect", Vector4(_cached_rect.position.x, _cached_rect.position.y,
			_cached_rect.size.x, _cached_rect.size.y))


## GLOBAL, not to_local(). The shader converts its VERTEX up to global space
## with MODEL_MATRIX, because VERTEX on its own is relative to the rendering
## QUADRANT rather than to the layer - see the note at the top of this file.
## Global is the only space both sides can agree on.
func _set_radial() -> void:
	_material.set_shader_parameter("fade_center", _local_player.global_position)
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


## Bounding box of a set of cells, in GLOBAL space, expanded to the outer edges
## of the tiles rather than their centres - map_to_local returns a cell's
## centre, so a rect built straight from it would clip half a tile off every
## side of the canopy.
##
## Global rather than layer-local because the shader cannot express layer-local:
## it only ever sees a quadrant. Converting here keeps the conversion in one
## place instead of leaving the shader to guess.
func _global_rect_for(cells: Array) -> Rect2:
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
	var top_left := to_global(map_to_local(min_cell) - half)
	var bottom_right := to_global(map_to_local(max_cell) + half)
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


## The painted cell covering the local player, or null if they are in the open.
func _covering_cell() -> Variant:
	if _local_player == null:
		return null
	return covering_cell_for(_local_player.global_position)


## True when this canopy is over `global_pos` - the same test the fade itself
## runs, so "the palm lifted for me" and "the palm hides me" can never
## disagree about where its edges are.
func covers_point(global_pos: Vector2) -> bool:
	return covering_cell_for(global_pos) != null


## The painted cell covering `global_pos`, or null if it is in the open.
##
## Returns the CLOSEST covering cell rather than the first one found, so the
## flood fill seeds inside the canopy the player is actually under when two
## different trees both have a cell within cover_radius.
func covering_cell_for(global_pos: Vector2) -> Variant:
	var local_pos := to_local(global_pos)
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


# --- Canopy stealth ----------------------------------------------------------
#
# A canopy hides whoever is under it, and it hides them from the MAP and from
# the name tags rather than from the screen. Standing under a palm does not
# make you invisible - anyone close enough still sees your sprite, and the
# Sili can still walk into you and tag you - it takes you off the mini-map and
# takes your name off your head.
#
# The exception is the whole point of the rule: a canopy that is lifted for
# BOTH of you hides neither of you from the other. Two players under the same
# palm are looking at each other through the same faded fronds, so the map has
# to agree with what their eyes already report. Under DIFFERENT palms, or one
# in the open and one under cover, the cover does its job.


## Is `target_pos` hidden from someone standing at `observer_pos`?
##
## True only when some canopy covers the target and NO canopy covering the
## target also covers the observer. Passing the same point for both always
## returns false, which is what keeps a player's own marker on their own map.
static func conceals(tree: SceneTree, target_pos: Vector2, observer_pos: Vector2) -> bool:
	if tree == null:
		return false

	var covered := false
	for node in tree.get_nodes_in_group(GROUP):
		var layer := node as CanopyFade
		if layer == null or not layer.covers_point(target_pos):
			continue
		if layer.covers_point(observer_pos):
			return false  # shared cover - they can see each other for real
		covered = true
	return covered


## The character this client controls, or null. Same scan the fade itself runs
## to find who to lift for, exposed so callers that have to judge "can the
## person AT THIS SCREEN see that" don't each reimplement it.
static func local_viewer(tree: SceneTree) -> Node2D:
	if tree == null:
		return null
	for node in tree.get_nodes_in_group("player"):
		var character := node as Node2D
		if character != null and character.is_multiplayer_authority():
			return character
	return null


## Is `target_pos` hidden from this screen's own player? Answers false when
## there is nobody local to hide from, so a spectator view hides nothing.
static func hidden_from_local(tree: SceneTree, target_pos: Vector2) -> bool:
	var viewer := local_viewer(tree)
	if viewer == null:
		return false
	return conceals(tree, target_pos, viewer.global_position)
