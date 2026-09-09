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
##   Sili   - only Tubig you've already caught, so the map is empty until your
##            first tag lands and it never leads you to anyone still free.
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

@export var DOT_RADIUS: float = 3.0
@export var SELF_DOT_RADIUS: float = 4.0
@export var ENTITY_REFRESH_INTERVAL: float = 0.5  # how often we re-scan the groups
@export var MAX_BAKE_DIMENSION: int = 512         # sanity guard on huge tilemaps

var _map_texture: ImageTexture = null
var _world_rect: Rect2 = Rect2()
var _local_player: Node2D = null
var _local_is_sili: bool = false
var _tubig_players: Array = []
var _sili_player: Node2D = null
var _refresh_accum: float = 0.0
var _pulse_time: float = 0.0

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


## Separate TileMapLayer nodes: each is its own object with its own used_rect,
## walked in the order they were found (bottom to top), same as the legacy path.
func _bake_tile_map_layers(layers: Array) -> void:
	var used := Rect2i()
	var has_bounds := false
	for layer in layers:
		var layer_rect: Rect2i = layer.get_used_rect()
		if layer_rect.size == Vector2i.ZERO:
			continue
		used = layer_rect if not has_bounds else used.merge(layer_rect)
		has_bounds = true
	if not has_bounds or not _size_within_limit(used.size):
		return

	var image := _new_bake_image(used.size)
	for y in used.size.y:
		for x in used.size.x:
			var cell := Vector2i(used.position.x + x, used.position.y + y)
			var pixel := TRANSPARENT
			for i in range(layers.size() - 1, -1, -1):
				var candidate := _layer_cell_color(layers[i], cell)
				if candidate.a > 0.05:
					pixel = candidate
					break
			image.set_pixel(x, y, pixel)

	var reference: TileMapLayer = layers[0]
	var tile_size := Vector2(reference.tile_set.tile_size)
	var local_origin: Vector2 = reference.map_to_local(used.position) - tile_size * 0.5
	_finish_bake(image, reference.to_global(local_origin), Vector2(used.size) * tile_size)


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
func configure(local_player: Node2D, is_sili: bool) -> void:
	_local_player = local_player
	_local_is_sili = is_sili
	_refresh_entities()
	queue_redraw()


func _process(delta: float) -> void:
	_pulse_time += delta
	_refresh_accum += delta
	if _refresh_accum >= ENTITY_REFRESH_INTERVAL:
		_refresh_accum = 0.0
		_refresh_entities()
	queue_redraw()


func _refresh_entities() -> void:
	_tubig_players = get_tree().get_nodes_in_group("tubig")
	_sili_player = get_tree().get_first_node_in_group("sili")


func _on_sili_spotted_changed(_is_spotted: bool) -> void:
	queue_redraw()


# --- Drawing ---

func _draw() -> void:
	var frame := Rect2(Vector2.ZERO, size)
	draw_rect(frame, COLOR_BACKDROP, true)

	if _map_texture:
		draw_texture_rect(_map_texture, frame, false)

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

	# Red dot only while a teammate genuinely has eyes on the Sili.
	if SightingTracker.is_sili_spotted and is_instance_valid(_sili_player):
		var sili_point := _map_point(_sili_player.global_position)
		draw_circle(sili_point, DOT_RADIUS + 0.5, COLOR_SILI)
		draw_arc(sili_point, DOT_RADIUS + 3.0, 0.0, TAU, 20, Color(COLOR_SILI.r, COLOR_SILI.g, COLOR_SILI.b, 0.5), 1.0)


## A dashed purple line from your own dot to every tagged teammate, ending in a
## pulsing purple ring on their position.
##
## The orange burning ring already said "this person is tagged"; it did not say
## WHICH WAY TO RUN, which is the only thing that matters while a fifteen-second
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
	# Caught Tubig only. Nobody caught yet means an empty map - the Sili never
	# gets a free read on players who are still free.
	for tubig in _tubig_players:
		if not is_instance_valid(tubig):
			continue
		var heat = tubig.get_node_or_null("HeatStatus")
		if heat == null or not heat.is_incapacitated():
			continue

		var point := _map_point(tubig.global_position)
		var alpha: float = 0.4 if heat.is_dead() else 1.0
		draw_circle(point, DOT_RADIUS, Color(COLOR_TUBIG.r, COLOR_TUBIG.g, COLOR_TUBIG.b, alpha))

		if heat.is_burning():
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
	return uv * size


# --- Terrain baking helpers ---

func _legacy_cell_color(tile_map: TileMap, layer_idx: int, cell: Vector2i) -> Color:
	var source_id: int = tile_map.get_cell_source_id(layer_idx, cell)
	if source_id == -1:
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
	if source_id == -1:
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
