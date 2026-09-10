extends Control

## Top-right mini-map. The terrain image is baked once at match start by
## walking the arena's TileMapLayers and averaging each tile's pixels down to a
## single dot of colour, so the map always matches whatever the level actually
## looks like instead of being a hand-drawn picture that goes stale.
##
## What gets drawn on top of it depends on which team you're on:
##
##   Tubig  - every teammate as a blue dot (concealed ones drop off entirely),
##            a dashed PURPLE guide line to any teammate who is tagged and
##            still savable,
##            plus a red dot for the Sili IF any Tubig currently has it on
##            screen. The red dot is shared team-wide and vanishes the instant
##            the last person loses sight of it.
##   Sili   - every Tubig you've already caught (permanent, same as the
##            Tubig-side red dot's "already known" bucket), PLUS any free
##            Tubig who happens to be inside YOUR OWN camera view right now -
##            same on-screen-right-now rule as the Tubig side's red dot, just
##            evaluated locally instead of over the network since there's only
##            one Sili to ask. That live dot disappears the instant the Tubig
##            steps outside your view; it is never a lingering "last seen here"
##            marker and never reveals anyone you haven't actually laid eyes on.
##            Your own position is always shown as a red dot with a white ring,
##            exactly like every teammate's self-marker on the Tubig side.
##
## Colour is the only identifier here - names are deliberately not drawn on the
## map or above characters, so a mid-chase glance tells you team and position
## and nothing else.

const COLOR_TUBIG := Color(0.35, 0.65, 1.0)
const COLOR_SILI := Color(1.0, 0.25, 0.25)
const COLOR_BURNING_RING := Color(0.95, 0.6, 0.15)
## Purple is reserved on this map for ONE meaning: a teammate is tagged and the
## clock is running on saving them. Nothing else in the game uses it, so a
## purple line appearing in the corner of your eye is unambiguous without
## reading anything.
const COLOR_TAGGED_GUIDE := Color(0.72, 0.42, 0.98)
const GUIDE_DASH_LENGTH := 5.0
const GUIDE_GAP_LENGTH := 4.0
const COLOR_BACKDROP := Color(0.05, 0.06, 0.09, 0.72)
const COLOR_BORDER := Color(0.85, 0.88, 0.95, 0.35)
const TRANSPARENT := Color(0, 0, 0, 0)
## Terrain fades into the dark backdrop rather than being drawn full-strength,
## so it reads as background context instead of competing with the saturated
## team dots for attention. Alpha, not desaturation - the tiles keep their
## real colour (sand tan, sea blue), just toned down under it.
const TERRAIN_ALPHA := 0.7

@export var DOT_RADIUS: float = 3.0
@export var SELF_DOT_RADIUS: float = 4.0
@export var ENTITY_REFRESH_INTERVAL: float = 0.5  # how often we re-scan the groups
@export var MAX_BAKE_DIMENSION: int = 512         # sanity guard on huge tilemaps
## Ignore the outer edge of the Sili's own view when deciding whether a free
## Tubig counts as "on screen" for the live minimap dot below. Same value and
## same reasoning as tubig.gd's SIGHTING_MARGIN: a body that has only just
## clipped the very edge of the frame shouldn't light up a dot before the
## player themselves would say they can see it.
@export var SILI_VIEW_MARGIN: float = 0.08
## How often canopy cover is re-tested, in seconds. Not per-frame: the test
## walks every canopy layer on the map for every player, and cover changes at
## walking pace, so re-asking sixty times a second buys nothing. Same
## reasoning and roughly the same value as tubig.gd's SIGHTING_INTERVAL.
@export var CANOPY_CHECK_INTERVAL: float = 0.15

var _map_texture: ImageTexture = null
var _world_rect: Rect2 = Rect2()
## Where the world is drawn inside this Control, after aspect-fitting. Written
## by _draw and read by _map_point, so terrain and dots always share one rect.
var _view_rect: Rect2 = Rect2()
var _local_player: Node2D = null
var _local_is_sili: bool = false
var _tubig_players: Array = []
var _sili_player: Node2D = null
var _refresh_accum: float = 0.0
var _pulse_time: float = 0.0
## instance_id -> true for every character currently under a canopy the local
## player is not also under. Recomputed on CANOPY_CHECK_INTERVAL and read by
## _draw, so the per-frame redraw stays a lookup rather than a map-wide scan.
var _canopy_hidden: Dictionary = {}
var _canopy_accum: float = 0.0

# Baking caches - keyed so a tile atlas is only ever averaged once.
var _color_cache: Dictionary = {}
var _image_cache: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	SightingTracker.sili_spotted_changed.connect(_on_sili_spotted_changed)


## Bakes the terrain image straight off the level's own tilemap, whichever
## authoring style it's in - a classic single TileMap node with internal
## "layer_0/name", "layer_1/name"... layers, OR a container with separate
## TileMapLayer child nodes (what you get after using Godot's "Convert to
## TileMapLayers" tool). Pass whatever root node the level actually uses;
## this figures out which format it's dealing with and bakes accordingly, so
## converting the level's layer format later needs no change here or at the
## call site.
func build_from_node(root: Node) -> void:
	if root == null:
		return

	if root is TileMap and root.tile_set != null and root.get_layers_count() > 0:
		_bake_legacy_tilemap(root)
		return

	var layers: Array = []
	_collect_tile_map_layers(root, layers)
	if not layers.is_empty():
		_bake_tile_map_layers(layers)


func _collect_tile_map_layers(node: Node, out: Array) -> void:
	if node is TileMapLayer and node.tile_set != null:
		out.append(node)
	for child in node.get_children():
		_collect_tile_map_layers(child, out)


## Classic TileMap node: layers are indices on the one node, walked bottom to
## top via the per-layer methods (get_cell_source_id(layer, cell) etc).
func _bake_legacy_tilemap(tile_map: TileMap) -> void:
	var indices: Array = range(tile_map.get_layers_count())
	if indices.is_empty():
		return

	var used: Rect2i = tile_map.get_used_rect()
	if used.size == Vector2i.ZERO:
		return
	if not _size_within_limit(used.size):
		return

	var image := _new_bake_image(used.size)
	for y in used.size.y:
		for x in used.size.x:
			var cell := Vector2i(used.position.x + x, used.position.y + y)
			var pixel := TRANSPARENT
			for i in range(indices.size() - 1, -1, -1):
				var candidate := _legacy_cell_color(tile_map, indices[i], cell)
				if candidate.a > 0.05:
					pixel = candidate
					break
			image.set_pixel(x, y, pixel)

	var tile_size := Vector2(tile_map.tile_set.tile_size)
	var local_origin: Vector2 = tile_map.map_to_local(used.position) - tile_size * 0.5
	_finish_bake(image, tile_map.to_global(local_origin), Vector2(used.size) * tile_size)


## Separate TileMapLayer nodes, baked in WORLD space rather than cell space.
##
## The obvious version of this - merge every layer's get_used_rect() and index
## the result with one shared cell coordinate - is wrong the moment two layers
## do not share a transform, and they routinely don't. In boracay.tscn,
## ground/sea and decorations/sand sit at position (1264, 144) while
## ground/sand and ground/grass sit at the origin. Cell (0, 0) therefore means
## two different places in the world depending on which layer you ask, so
## merging their rects stacked the sea 79 cells left and 9 cells up from the
## sand it is supposed to border, and anchoring the finished image to layers[0]
## dragged the whole world_rect off by that same offset - which is why the
## terrain looked scrambled AND the dots sat away from the ground under them.
##
## So: bounds are merged in world space, and each output pixel is converted
## back through each layer's OWN transform to find the cell to sample. Layers
## can now sit anywhere, at any offset, with different tile sizes, and still
## line up - and the world_rect the dots are plotted against is the real one.
func _bake_tile_map_layers(layers: Array) -> void:
	var world_bounds := Rect2()
	var has_bounds := false
	# Output resolution is set by the FINEST layer, so a coarse decorative
	# layer can't force the whole map to be sampled at its own chunky grid.
	var pixel_size := Vector2(INF, INF)

	var painted: Array = []
	for layer in layers:
		var used: Rect2i = layer.get_used_rect()
		if used.size == Vector2i.ZERO:
			continue
		var tile_size := Vector2(layer.tile_set.tile_size)
		var layer_rect := _layer_world_rect(layer, used, tile_size)
		world_bounds = layer_rect if not has_bounds else world_bounds.merge(layer_rect)
		has_bounds = true

		# basis_xform, not the raw tile_size: a layer that has been scaled
		# covers more world per cell, and the pixel grid has to follow.
		var world_tile: Vector2 = layer.get_global_transform().basis_xform(tile_size).abs()
		pixel_size.x = minf(pixel_size.x, maxf(world_tile.x, 1.0))
		pixel_size.y = minf(pixel_size.y, maxf(world_tile.y, 1.0))
		painted.append(layer)

	if not has_bounds or painted.is_empty():
		return
	if world_bounds.size.x <= 0.0 or world_bounds.size.y <= 0.0:
		return

	pixel_size = _fit_pixel_size(world_bounds.size, pixel_size)
	var image_size := Vector2i(
		maxi(1, int(ceil(world_bounds.size.x / pixel_size.x))),
		maxi(1, int(ceil(world_bounds.size.y / pixel_size.y))))

	var image := _new_bake_image(image_size)
	for y in image_size.y:
		for x in image_size.x:
			# Centre of this output pixel, in world space - the one coordinate
			# every layer agrees on.
			var world_pos := world_bounds.position + Vector2(x + 0.5, y + 0.5) * pixel_size
			var pixel := TRANSPARENT
			for i in range(painted.size() - 1, -1, -1):
				var layer: TileMapLayer = painted[i]
				var cell: Vector2i = layer.local_to_map(layer.to_local(world_pos))
				var candidate := _layer_cell_color(layer, cell)
				if candidate.a > 0.05:
					pixel = candidate
					break
			image.set_pixel(x, y, pixel)

	_finish_bake(image, world_bounds.position, world_bounds.size)


## World-space bounds of a layer's painted area, via its own global transform
## so an offset, rotated or scaled layer reports where it actually is.
func _layer_world_rect(layer: TileMapLayer, used: Rect2i, tile_size: Vector2) -> Rect2:
	var top_left: Vector2 = layer.map_to_local(used.position) - tile_size * 0.5
	var bottom_right: Vector2 = layer.map_to_local(used.end) - tile_size * 0.5
	var rect := Rect2(layer.to_global(top_left), Vector2.ZERO)
	rect = rect.expand(layer.to_global(Vector2(bottom_right.x, top_left.y)))
	rect = rect.expand(layer.to_global(Vector2(top_left.x, bottom_right.y)))
	return rect.expand(layer.to_global(bottom_right))


## Coarsens the sample grid until the output fits MAX_BAKE_DIMENSION.
##
## The previous behaviour on an oversized map was to bail and draw no terrain
## at all, which reads to a player as a broken mini-map. A blurrier map is a
## far better answer than an empty one, and at this display size (a 180x140
## corner box) the difference is close to invisible anyway.
func _fit_pixel_size(world_size: Vector2, pixel_size: Vector2) -> Vector2:
	var limit := float(MAX_BAKE_DIMENSION)
	var over := maxf(world_size.x / pixel_size.x / limit, world_size.y / pixel_size.y / limit)
	if over <= 1.0:
		return pixel_size
	return pixel_size * over


## Still used by the legacy single-TileMap path above, which shares one
## transform across all its layers and so can safely stay in cell space.
func _size_within_limit(cell_size: Vector2i) -> bool:
	if cell_size.x > MAX_BAKE_DIMENSION or cell_size.y > MAX_BAKE_DIMENSION:
		push_warning("Minimap: tilemap too large to bake (%s cells), skipping terrain." % cell_size)
		return false
	return true


func _new_bake_image(cell_size: Vector2i) -> Image:
	var image := Image.create(cell_size.x, cell_size.y, false, Image.FORMAT_RGBA8)
	image.fill(TRANSPARENT)
	return image


func _finish_bake(image: Image, world_origin: Vector2, world_size: Vector2) -> void:
	_map_texture = ImageTexture.create_from_image(image)
	_world_rect = Rect2(world_origin, world_size)
	_color_cache.clear()
	_image_cache.clear()
	queue_redraw()


## Told by the arena which character belongs to this peer, so the map knows
## which set of dots it's allowed to show.
##
## A null `local_player` is not treated as "there is nobody" - arena.gd calls
## this from _refresh_team_state(), which fires on every spawn, so the early
## calls legitimately land before this peer's own body exists. Keeping a body
## we already resolved (and asking _refresh_entities to look again when we
## haven't) is what stops one of those early calls from blanking the map for
## the rest of the round.
func configure(local_player: Node2D, is_sili: bool) -> void:
	_local_is_sili = is_sili
	if local_player != null:
		_local_player = local_player
	_refresh_entities()
	queue_redraw()


func _process(delta: float) -> void:
	_pulse_time += delta
	_refresh_accum += delta
	if _refresh_accum >= ENTITY_REFRESH_INTERVAL:
		_refresh_accum = 0.0
		_refresh_entities()

	_canopy_accum += delta
	if _canopy_accum >= CANOPY_CHECK_INTERVAL:
		_canopy_accum = 0.0
		_refresh_canopy_cover()

	queue_redraw()


## Who is currently tucked under cover this screen's player cannot see into.
##
## The map is deliberately stricter than the screen here: a canopy hides you
## from it even when someone standing outside your palm can make out your
## sprite, because a dot on a map is readable from across the level and a
## sprite at that distance is not. Sharing the cover cancels it - see
## CanopyFade.conceals().
func _refresh_canopy_cover() -> void:
	_canopy_hidden.clear()
	if not is_instance_valid(_local_player):
		return

	var viewpoint := _local_player.global_position
	for character in _tubig_players + [_sili_player]:
		if not is_instance_valid(character) or character == _local_player:
			continue
		if CanopyFade.conceals(get_tree(), character.global_position, viewpoint):
			_canopy_hidden[character.get_instance_id()] = true


func _under_hidden_canopy(character: Node) -> bool:
	return _canopy_hidden.has(character.get_instance_id())


func _refresh_entities() -> void:
	_tubig_players = get_tree().get_nodes_in_group("tubig")
	_sili_player = get_tree().get_first_node_in_group("sili")
	# Self-heal, every ENTITY_REFRESH_INTERVAL. Without it the map depends
	# entirely on configure() having been called at a moment when this peer's
	# own body already existed, and a Sili whose body landed after the last
	# such call spent the whole round unable to see EITHER their own dot or
	# any Tubig in their camera - _draw_for_sili() needs _local_player for
	# both, since _local_camera() reads it too.
	if not is_instance_valid(_local_player):
		_local_player = _find_own_body()


## This peer's own character, found by authority rather than by node path.
## Character bodies get set_multiplayer_authority(peer_id) in arena.gd's
## _build_player, so the body whose authority is our own id is ours - the same
## way heat_status.gd resolves a peer's body.
func _find_own_body() -> Node2D:
	var my_id := multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1
	for body in get_tree().get_nodes_in_group("sili" if _local_is_sili else "tubig"):
		if is_instance_valid(body) and body.get_multiplayer_authority() == my_id:
			return body
	return null


func _on_sili_spotted_changed(_is_spotted: bool) -> void:
	queue_redraw()


# --- Drawing ---

func _draw() -> void:
	var frame := Rect2(Vector2.ZERO, size)
	draw_rect(frame, COLOR_BACKDROP, true)

	# The panel is 180x140; a level is rarely that shape. Stretching the world
	# to fill it squashes one axis, so distances read wrong on the map - two
	# teammates equally far away look like one is much closer, which is exactly
	# the judgement the rescue guide lines are asking players to make. Fitting
	# and letterboxing costs a strip of empty backdrop and keeps the geometry
	# honest. Cached because _map_point needs the same rect for the dots; using
	# `size` there while drawing the texture here would put every dot back off
	# the terrain again.
	_view_rect = _fitted_view_rect(frame)

	if _map_texture:
		draw_texture_rect(_map_texture, _view_rect, false, Color(1, 1, 1, TERRAIN_ALPHA))

	draw_rect(frame, COLOR_BORDER, false, 1.0)

	if _world_rect.size.x <= 0.0 or _world_rect.size.y <= 0.0:
		return

	if _local_is_sili:
		_draw_for_sili()
	else:
		_draw_for_tubig()


func _draw_for_tubig() -> void:
	for tubig in _tubig_players:
		if not is_instance_valid(tubig):
			continue

		var is_self: bool = tubig == _local_player
		var concealed: bool = tubig.get("is_concealed") == true

		# A hidden teammate is off the map for everyone. You still see your own
		# marker (as a hollow ring) so you know the concealment actually took.
		if concealed and not is_self:
			continue
		# Same rule for a teammate under a palm you are not under yourself.
		if not is_self and _under_hidden_canopy(tubig):
			continue

		var heat = tubig.get_node_or_null("HeatStatus")
		var point := _map_point(tubig.global_position)
		var radius: float = SELF_DOT_RADIUS if is_self else DOT_RADIUS
		var color := COLOR_TUBIG

		if heat and heat.is_dead():
			color = Color(COLOR_TUBIG.r, COLOR_TUBIG.g, COLOR_TUBIG.b, 0.35)

		if concealed and is_self:
			draw_arc(point, radius, 0.0, TAU, 20, color, 1.5)
		else:
			draw_circle(point, radius, color)

		# Burning teammates get an orange ring - status, not a new team colour.
		if heat and heat.is_burning():
			var ring_alpha := 0.45 + 0.55 * (0.5 + 0.5 * sin(_pulse_time * 6.0))
			draw_arc(point, radius + 2.5, 0.0, TAU, 20,
				Color(COLOR_BURNING_RING.r, COLOR_BURNING_RING.g, COLOR_BURNING_RING.b, ring_alpha), 1.5)

		if is_self and not concealed:
			draw_arc(point, radius + 1.5, 0.0, TAU, 20, Color(1, 1, 1, 0.85), 1.0)

	# Drawn after every dot so a guide is never buried under a teammate marker.
	_draw_tagged_guides()

	# Red dot only while a teammate genuinely has eyes on the Sili - and never
	# while the Sili is under cover this player is not sharing. A Sili who has
	# stepped under a palm has broken line of sight for map purposes even if
	# somebody across the level still has them technically on screen.
	if is_instance_valid(_sili_player) and _under_hidden_canopy(_sili_player):
		return
	if SightingTracker.is_sili_spotted and is_instance_valid(_sili_player):
		var sili_point := _map_point(_sili_player.global_position)
		draw_circle(sili_point, DOT_RADIUS + 0.5, COLOR_SILI)
		draw_arc(sili_point, DOT_RADIUS + 3.0, 0.0, TAU, 20, Color(COLOR_SILI.r, COLOR_SILI.g, COLOR_SILI.b, 0.5), 1.0)


## A dashed purple line from your own dot to every tagged teammate, ending in a
## pulsing purple ring on their position.
##
## The orange burning ring already said "this person is tagged"; it did not say
## WHICH WAY TO RUN, which is the only thing that matters while a thirty-second
## burn timer is running. A dot on a small map still needs to be found. A line
## from you to them can be read at a glance and turns a rescue into a decision
## about distance rather than a hunt for a marker.
##
## BURNING only, never DEAD. A guide to someone who can no longer be saved would
## walk you across the map into a Sili camping the body for nothing, which is
## worse than no guide at all.
func _draw_tagged_guides() -> void:
	if not is_instance_valid(_local_player):
		return
	# Rooted players cannot go anywhere, so pointing them at a rescue is noise.
	var own_heat = _local_player.get_node_or_null("HeatStatus")
	if own_heat and own_heat.is_incapacitated():
		return

	var origin := _map_point(_local_player.global_position)
	var pulse: float = 0.55 + 0.45 * (0.5 + 0.5 * sin(_pulse_time * 5.0))

	for tubig in _tubig_players:
		if not is_instance_valid(tubig) or tubig == _local_player:
			continue
		var heat = tubig.get_node_or_null("HeatStatus")
		if heat == null or not heat.is_burning():
			continue

		var target := _map_point(tubig.global_position)
		_draw_dashed_line(origin, target,
			Color(COLOR_TAGGED_GUIDE.r, COLOR_TAGGED_GUIDE.g, COLOR_TAGGED_GUIDE.b, 0.75 * pulse))
		draw_arc(target, DOT_RADIUS + 4.0, 0.0, TAU, 22,
			Color(COLOR_TAGGED_GUIDE.r, COLOR_TAGGED_GUIDE.g, COLOR_TAGGED_GUIDE.b, pulse), 1.6)


## Dashed rather than solid on purpose: with three teammates down at once, three
## solid lines from your dot become a filled purple wedge that hides the terrain
## underneath. Dashes stay readable when they overlap.
func _draw_dashed_line(from: Vector2, to: Vector2, color: Color) -> void:
	var span := to - from
	var distance := span.length()
	if distance < 1.0:
		return
	var step := span / distance
	var travelled := 0.0
	while travelled < distance:
		var segment_end: float = minf(travelled + GUIDE_DASH_LENGTH, distance)
		draw_line(from + step * travelled, from + step * segment_end, color, 1.4)
		travelled = segment_end + GUIDE_GAP_LENGTH


func _draw_for_sili() -> void:
	# Caught Tubig show up unconditionally (they're already known). A free
	# Tubig only shows up while they are actually inside the Sili's own camera
	# view right now - mirrors the Tubig side's red dot, which likewise only
	# exists while somebody currently has eyes on the target. No occlusion
	# test here, same as tubig.gd's _can_see_sili(): if it's inside the view
	# rect it counts, same as what the player's own eyes are already seeing.
	var camera: Camera2D = _local_camera()

	for tubig in _tubig_players:
		if not is_instance_valid(tubig):
			continue
		var heat = tubig.get_node_or_null("HeatStatus")
		var caught: bool = heat != null and heat.is_incapacitated()

		if not caught:
			# Concealed Tubig stay hidden from the Sili's minimap the same way
			# they vanish from the Tubig-side map - being tucked into a hiding
			# spot should not be undone by merely walking past with a camera.
			var concealed: bool = tubig.get("is_concealed") == true
			if concealed or camera == null or not _point_in_view(camera, tubig.global_position):
				continue
			# Under a palm the Sili is not under: on screen at this range, but
			# not on the map. Walking under it with them cancels this.
			if _under_hidden_canopy(tubig):
				continue

		var point := _map_point(tubig.global_position)
		var alpha: float = 0.4 if (caught and heat.is_dead()) else 1.0
		draw_circle(point, DOT_RADIUS, Color(COLOR_TUBIG.r, COLOR_TUBIG.g, COLOR_TUBIG.b, alpha))

		if caught and heat.is_burning():
			# Pulses while the burn timer is still running, i.e. while this
			# marker is worth camping.
			var ring_alpha := 0.35 + 0.45 * (0.5 + 0.5 * sin(_pulse_time * 4.0))
			draw_arc(point, DOT_RADIUS + 2.5, 0.0, TAU, 20,
				Color(COLOR_BURNING_RING.r, COLOR_BURNING_RING.g, COLOR_BURNING_RING.b, ring_alpha), 1.5)

	if is_instance_valid(_local_player):
		var self_point := _map_point(_local_player.global_position)
		draw_circle(self_point, SELF_DOT_RADIUS, COLOR_SILI)
		draw_arc(self_point, SELF_DOT_RADIUS + 1.5, 0.0, TAU, 20, Color(1, 1, 1, 0.85), 1.0)


## World position -> pixel inside this Control. Clamped so anyone who wanders
## off the baked area still shows on the edge rather than disappearing.
func _map_point(world_pos: Vector2) -> Vector2:
	var uv := (world_pos - _world_rect.position) / _world_rect.size
	uv.x = clampf(uv.x, 0.0, 1.0)
	uv.y = clampf(uv.y, 0.0, 1.0)
	var view := _view_rect if _view_rect.size.x > 0.0 else Rect2(Vector2.ZERO, size)
	return view.position + uv * view.size


## Largest rect with the world's aspect ratio that fits inside the panel,
## centred. Falls back to the whole panel before the first bake lands.
func _fitted_view_rect(frame: Rect2) -> Rect2:
	if _world_rect.size.x <= 0.0 or _world_rect.size.y <= 0.0:
		return frame
	var scale: float = minf(frame.size.x / _world_rect.size.x, frame.size.y / _world_rect.size.y)
	var fitted := _world_rect.size * scale
	return Rect2(frame.position + (frame.size - fitted) * 0.5, fitted)


## The local player's own Camera2D, if it has one and it's the active one.
## Remote-controlled copies of a body have their Camera2D disabled (see
## arena.gd's _build_player), so this can only ever resolve to a camera that
## is actually feeding this peer's screen.
func _local_camera() -> Camera2D:
	if not is_instance_valid(_local_player):
		return null
	var camera := _local_player.get_node_or_null("Camera2D") as Camera2D
	if camera == null or not camera.enabled:
		return null
	return camera


## Is this world position inside the given camera's current view, minus a
## small edge margin? Identical rule to tubig.gd's _can_see_sili(): a plain
## rect containment test against the camera's own zoom and screen centre, no
## occlusion check - "on screen" here means exactly what the player's own eyes
## are already seeing, nothing more and nothing less.
func _point_in_view(camera: Camera2D, world_pos: Vector2) -> bool:
	var view_size: Vector2 = get_viewport_rect().size / camera.zoom
	var margin: Vector2 = view_size * SILI_VIEW_MARGIN
	var view_rect := Rect2(
		camera.get_screen_center_position() - view_size * 0.5 + margin * 0.5,
		view_size - margin
	)
	return view_rect.has_point(world_pos)


# --- Terrain baking helpers ---

func _legacy_cell_color(tile_map: TileMap, layer_idx: int, cell: Vector2i) -> Color:
	var source_id: int = tile_map.get_cell_source_id(layer_idx, cell)
	# -1 means "nothing painted here". A cell can also carry a source id that
	# used to exist but was later removed from the TileSet resource (an atlas
	# deleted after the level was painted) - that id is stale data, not "no
	# tile", so it still reaches here as something other than -1.  Without this
	# check get_source() below logs a "No TileSet atlas source with id N" C++
	# error for every such cell sampled during the bake instead of just being
	# treated as an empty tile.
	if source_id == -1 or not tile_map.tile_set.has_source(source_id):
		return TRANSPARENT

	var source := tile_map.tile_set.get_source(source_id) as TileSetAtlasSource
	if source == null:
		return TRANSPARENT

	var atlas_coords: Vector2i = tile_map.get_cell_atlas_coords(layer_idx, cell)
	var alternative: int = tile_map.get_cell_alternative_tile(layer_idx, cell)
	var key := "legacy:%d:%d:%d,%d:%d" % [layer_idx, source_id, atlas_coords.x, atlas_coords.y, alternative]
	if _color_cache.has(key):
		return _color_cache[key]

	# get_tile_texture_region's second argument is the ANIMATION FRAME, not the
	# alternative tile. Passing `alternative` in here meant every flipped or
	# transposed tile on the map sent a bit-flagged value like 4096 or 24576
	# into a frame slot with one frame in it, which threw an out-of-bounds
	# error per tile and left that cell un-sampled. Frame 0 is correct, and the
	# alternative is irrelevant to the answer anyway: flipping a tile does not
	# change its average colour.
	var region: Rect2i = source.get_tile_texture_region(atlas_coords, 0)
	var color := _average_region_color(source.texture, region)
	_color_cache[key] = color
	return color


func _layer_cell_color(layer: TileMapLayer, cell: Vector2i) -> Color:
	var source_id: int = layer.get_cell_source_id(cell)
	# Same stale-id guard as _legacy_cell_color above: a source id can survive
	# in a layer's cell data after the atlas it pointed to was removed from the
	# TileSet, and calling get_source() with that id is what was spamming
	# "No TileSet atlas source with id N" during every bake.
	if source_id == -1 or not layer.tile_set.has_source(source_id):
		return TRANSPARENT

	var source := layer.tile_set.get_source(source_id) as TileSetAtlasSource
	if source == null:
		return TRANSPARENT

	var atlas_coords: Vector2i = layer.get_cell_atlas_coords(cell)
	var alternative: int = layer.get_cell_alternative_tile(cell)
	var key := "layer:%d:%d:%d,%d:%d" % [layer.get_instance_id(), source_id, atlas_coords.x, atlas_coords.y, alternative]
	if _color_cache.has(key):
		return _color_cache[key]

	# get_tile_texture_region's second argument is the ANIMATION FRAME, not the
	# alternative tile. Passing `alternative` in here meant every flipped or
	# transposed tile on the map sent a bit-flagged value like 4096 or 24576
	# into a frame slot with one frame in it, which threw an out-of-bounds
	# error per tile and left that cell un-sampled. Frame 0 is correct, and the
	# alternative is irrelevant to the answer anyway: flipping a tile does not
	# change its average colour.
	var region: Rect2i = source.get_tile_texture_region(atlas_coords, 0)
	var color := _average_region_color(source.texture, region)
	_color_cache[key] = color
	return color


## Averages a tile's pixels into one colour, weighted by alpha so a mostly
## transparent tile doesn't get dragged toward black by its empty pixels.
func _average_region_color(texture: Texture2D, region: Rect2i) -> Color:
	if texture == null:
		return TRANSPARENT

	var image: Image = _image_cache.get(texture)
	if image == null:
		image = texture.get_image()
		if image == null:
			return TRANSPARENT
		if image.is_compressed():
			image.decompress()
		_image_cache[texture] = image

	var accumulated := Vector3.ZERO
	var weight := 0.0
	var step := 2  # every other pixel is plenty at this output scale

	var x: int = region.position.x
	while x < region.position.x + region.size.x:
		var y: int = region.position.y
		while y < region.position.y + region.size.y:
			if x >= 0 and y >= 0 and x < image.get_width() and y < image.get_height():
				var pixel := image.get_pixel(x, y)
				if pixel.a > 0.1:
					accumulated += Vector3(pixel.r, pixel.g, pixel.b) * pixel.a
					weight += pixel.a
			y += step
		x += step

	if weight <= 0.0:
		return TRANSPARENT
	accumulated /= weight
	return Color(accumulated.x, accumulated.y, accumulated.z, 1.0)
