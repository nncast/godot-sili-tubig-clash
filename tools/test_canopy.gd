extends SceneTree

## Proves the flood fill isolates individual canopies on the REAL map instead
## of grabbing the whole layer, and that blob detection fires where it should.
##
## Assertions run from _process, not _initialize: nodes added during
## _initialize have not had _ready() called yet, so the shader material each
## layer builds for itself does not exist until a frame has passed.

var _f := 0
var _arena: Node = null
var _frame := 0

func _c(l, a, e) -> void:
	if a == e: print("  PASS  %s" % l)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [l, a, e])

func _initialize() -> void:
	print("Canopy clustering tests")
	_arena = load("res://maps/boracay_shore/boracay_shore.tscn").instantiate()
	root.add_child(_arena)

func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 2:
		return false

	for path in ["Map/sand/over", "Map/grass/over", "Map/buildings/over"]:
		var layer = _arena.get_node(path.replace("Map/",""))
		_c("%s ran _ready" % path, layer.is_node_ready(), true)
		_c("%s has the script" % path, layer.get_script() != null, true)
		_c("%s is above the players" % path, layer.z_index, 21)
		_c("%s built its own shader material" % path, layer.material is ShaderMaterial, true)

		# Measure with the early-out disabled, so the numbers are the true
		# clump sizes rather than "however far the fill got before it decided
		# this was scenery".
		var real_mode = layer.fade_mode
		layer.fade_mode = 0  # CLUSTER
		var sizes := _clump_sizes(layer)
		layer.fade_mode = real_mode

		print("  %-20s %4d cells -> %2d clumps, largest %d, mode=%d" % [
			path, layer.get_used_cells().size(), sizes.size(), sizes[0], real_mode])

		if path == "Map/sand/over":
			_c("sand: palms are separate objects", sizes.size() >= 20, true)
			_c("sand: no palm reads as scenery", sizes[0] <= layer.max_cluster_cells, true)
			_c("sand: fill does NOT grab the layer",
				sizes[0] < layer.get_used_cells().size(), true)
			var r: Rect2 = layer._local_rect_for(layer._flood_fill(layer.get_used_cells()[0]))
			_c("sand: one palm's rect is a small box",
				r.size.x < 200.0 and r.size.y < 200.0, true)
		elif path == "Map/grass/over":
			_c("grass: canopy really is a contiguous mass", sizes.size() <= 4, true)
			_c("grass: mass exceeds the blob threshold",
				sizes[0] > layer.max_cluster_cells, true)
			_c("grass: set to RADIAL", real_mode, 1)
		elif path == "Map/buildings/over":
			_c("buildings: roofs are separate", sizes.size() >= 10, true)
			_c("buildings: biggest roof still fades whole",
				sizes[0] <= layer.max_cluster_cells, true)

	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d TEST(S) FAILED" % _f)
	quit(1 if _f > 0 else 0)
	return true

func _clump_sizes(layer) -> Array:
	var seen := {}
	var sizes: Array[int] = []
	for cell in layer.get_used_cells():
		if seen.has(cell): continue
		var group: Array = layer._flood_fill(cell)
		for c in group: seen[c] = true
		sizes.append(group.size())
	sizes.sort()
	sizes.reverse()
	return sizes
