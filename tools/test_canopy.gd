extends SceneTree

## Covers the canopy flood fill: which painted tiles count as ONE canopy, and
## when a clump is big enough to stop being an object and start being scenery.
##
## WHY THIS BUILDS ITS OWN LAYER INSTEAD OF LOADING A MAP
##
## The previous version of this file loaded
## res://maps/boracay_shore/boracay_shore.tscn and asserted against
## Map/sand/over, Map/grass/over and Map/buildings/over. That map was replaced
## by maps/boracay, and none of those layers exist any more - so load() returned
## null, instantiate() failed on it, _initialize aborted before its first
## assertion, and the suite exited 0 having tested nothing at all. A test that
## reports success while doing nothing is worse than one that fails, because
## nobody looks at it again. It also called _local_rect_for(), which had been
## renamed _global_rect_for() long enough ago that the rename cannot have been
## the thing that broke it.
##
## Painting the fixture here means the assertions describe the ALGORITHM rather
## than one particular map's art, so re-painting Boracay can never silently
## switch this off again.
##
## Run with --script; it needs no autoloads and never enters the tree.

const TILE := 16
## Comfortably past canopy_fade.gd's max_cluster_cells default of 64.
const BLOB_SIDE := 10

var _f := 0


func _c(l: String, a: Variant, e: Variant) -> void:
	if a == e:
		print("  PASS  %s" % l)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [l, a, e])


## A CanopyFade with a one-tile atlas, never added to the tree. _flood_fill and
## _global_rect_for read only tile_set and the painted cells, so keeping it out
## of the tree avoids _ready() loading a shader and _process() hunting for a
## local player that does not exist in a headless script.
func _make_layer() -> CanopyFade:
	var image := Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)

	var source := TileSetAtlasSource.new()
	source.texture = ImageTexture.create_from_image(image)
	source.texture_region_size = Vector2i(TILE, TILE)
	source.create_tile(Vector2i.ZERO)

	var tiles := TileSet.new()
	tiles.tile_size = Vector2i(TILE, TILE)
	tiles.add_source(source, 0)

	var layer := CanopyFade.new()
	layer.tile_set = tiles
	# CLUSTER, so _flood_fill reports the TRUE size of a clump. Every other mode
	# bails out the moment it knows the clump is a blob, which is the right
	# behaviour in game and useless for measuring.
	layer.fade_mode = CanopyFade.FadeMode.CLUSTER
	return layer


func _paint(layer: CanopyFade, origin: Vector2i, width: int, height: int) -> void:
	for y in height:
		for x in width:
			layer.set_cell(origin + Vector2i(x, y), 0, Vector2i.ZERO)


func _initialize() -> void:
	print("Canopy clustering tests")

	var layer := _make_layer()

	# Two 3x3 palms with clear ground between them.
	_paint(layer, Vector2i(0, 0), 3, 3)
	_paint(layer, Vector2i(20, 0), 3, 3)

	var first := layer._flood_fill(Vector2i(0, 0))
	_c("a palm is its own clump", first.size(), 9)
	_c("the fill stops at the edge of the art",
		first.has(Vector2i(20, 0)), false)
	_c("the fill does not swallow the whole layer",
		first.size() < layer.get_used_cells().size(), true)

	# The rect is what the shader masks with, and it has to cover the tiles'
	# outer edges rather than their centres - 3 tiles of 16px is 48px, and a
	# rect built straight from map_to_local would come out 32 and clip a half
	# tile off every side.
	var rect: Rect2 = layer._global_rect_for(first)
	_c("the clump's rect spans whole tiles", rect.size, Vector2(48, 48))
	_c("the rect starts at the tile's outer corner", rect.position, Vector2(0, 0))

	# Corner-touching palms are two trees. Following diagonals here would fade
	# both of them the moment somebody walked under either.
	var diagonal := _make_layer()
	_paint(diagonal, Vector2i(0, 0), 2, 2)
	_paint(diagonal, Vector2i(2, 2), 2, 2)
	var corner := diagonal._flood_fill(Vector2i(0, 0))
	_c("a corner touch is still two canopies", corner.size(), 4)
	_c("the diagonal neighbour is not followed",
		corner.has(Vector2i(2, 2)), false)
	diagonal.free()

	# A mass this size is scenery, not an object - AUTO switches it to a radial
	# hole rather than fading the lot.
	var blob := _make_layer()
	_paint(blob, Vector2i(0, 0), BLOB_SIDE, BLOB_SIDE)
	var whole := blob._flood_fill(Vector2i(0, 0))
	_c("a painted mass fills as one clump", whole.size(), BLOB_SIDE * BLOB_SIDE)
	_c("and is over the blob threshold",
		whole.size() > blob.max_cluster_cells, true)

	# Same art, non-CLUSTER mode: the fill must give up early instead of walking
	# thousands of cells to measure something it already knows is scenery.
	blob.fade_mode = CanopyFade.FadeMode.AUTO
	var early := blob._flood_fill(Vector2i(0, 0))
	_c("a blob stops being counted once it is known to be one",
		early.size() <= blob.max_cluster_cells + 1, true)
	_c("and that is cheaper than measuring it in full",
		early.size() < whole.size(), true)
	blob.free()

	layer.free()

	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d TEST(S) FAILED" % _f)
	quit(1 if _f > 0 else 0)
