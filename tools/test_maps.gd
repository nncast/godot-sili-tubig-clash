extends SceneTree

## Two things:
##   1. Every map in MapRegistry satisfies the map contract.
##   2. The arena shell actually assembles a playable tree from one.
##
## Assertions run from _process, not _initialize - nodes added during
## _initialize have not had _ready() called yet, so the arena has not loaded
## its map and the canopy layers have not built their materials.

const GROUND := ["sea", "sand", "grass", "road", "stairs", "sandfade", "plank"]

var _f := 0
var _frame := 0
var _arena: Node = null

func _c(l, a, e) -> void:
	if a == e: print("  PASS  %s" % l)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [l, a, e])

func _initialize() -> void:
	print("Map contract + arena assembly")
	_arena = load("res://game/arena/arena.tscn").instantiate()
	root.add_child(_arena)

func _process(_d: float) -> bool:
	_frame += 1
	if _frame < 2:
		return false

	# ---- contract, per registered map ----
	for id in MapRegistry.ids():
		print("\n  [%s] %s" % [id, MapRegistry.display_name(id)])
		var packed = load(MapRegistry.scene_path(id))
		_c("%s: scene loads" % id, packed != null, true)
		if packed == null: continue
		var m = packed.instantiate()
		root.add_child(m)

		_c("%s: root is Node2D" % id, m is Node2D, true)
		_c("%s: no player containers" % id,
			m.get_node_or_null("SiliContainer") == null
			and m.get_node_or_null("TubigContainer") == null, true)

		var spawns = m.get_node_or_null("SpawnPoints")
		_c("%s: has SpawnPoints" % id, spawns != null, true)
		if spawns:
			var sili := 0
			var tubig := 0
			for sp in spawns.get_children():
				if "role" in sp:
					# SpawnPoint.Role is { TUBIG = 0, SILI = 1 }.
					if sp.role == 1: sili += 1
					else: tubig += 1
			_c("%s: >=1 sili spawn" % id, sili >= 1, true)
			_c("%s: >=4 tubig spawns" % id, tubig >= 4, true)

		# Ground layers are optional per map, but any that exist must be named
		# from the SurfaceAudio vocabulary or footsteps go silent with no error.
		# Recursive, matching how surface_audio.gd now resolves layers - a map
		# may group its ground under a "ground" node.
		var named := []
		for child in m.find_children("*", "TileMapLayer", true, false):
			if child.name in GROUND:
				named.append(String(child.name))
		print("        ground layers found: %s" % str(named))
		_c("%s: has at least one known ground layer" % id, named.size() >= 1, true)

		# Every overhead layer must be fully wired, wherever it sits - including
		# the ones inside prop scenes, which is where both bugs were hiding.
		for layer in _find_over_layers(m):
			var path := String(m.get_path_to(layer))
			_c("%s: %s has canopy script" % [id, path], layer.get_script() != null, true)
			_c("%s: %s z_index 21" % [id, path], layer.z_index, 21)
			# A material is required only where the fade is drawn by the shader.
			# WHOLE mode fades the layer through modulate.a and builds no material
			# at all on purpose (see canopy_fade.gd's _ensure_material), and WHOLE
			# is what every prop in the game uses - so demanding a ShaderMaterial
			# unconditionally, as this did, failed every correctly-wired canopy on
			# the map. What actually matters is that a layer which NEEDS a shader
			# has one.
			if layer.fade_mode == CanopyFade.FadeMode.WHOLE:
				_c("%s: %s fades whole, needs no material" % [id, path],
					layer.material == null, true)
			else:
				_c("%s: %s has shader material" % [id, path],
					layer.material is ShaderMaterial, true)
		m.queue_free()

	# ---- arena assembly ----
	print("\n  [arena shell]")
	_c("map was instanced", _arena.map_instance != null, true)
	_c("instance is named Map",
		String(_arena.map_instance.name) if _arena.map_instance else "", "Map")
	_c("spawn points resolved", _arena.spawn_points_root != null, true)
	_c("containers are on the SHELL, not the map",
		_arena.sili_container.get_parent() == _arena, true)
	_c("SiliSpawner path is map-independent",
		String(_arena.get_node("SiliSpawner").spawn_path), "../SiliContainer")
	_c("TubigSpawner path is map-independent",
		String(_arena.get_node("TubigSpawner").spawn_path), "../TubigContainer")

	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d TEST(S) FAILED" % _f)
	quit(1 if _f > 0 else 0)
	return true

## Two spellings, one rule. The map scenes name their overhead layers "over"
## (one per terrain group); the prop scenes under game/props name theirs "top",
## paired with a "bottom". Only "over" used to be checked here, which is exactly
## why palm.tscn shipped with z_index 21 and canopy_fade.gd on its BOTTOM layer
## and nothing caught it: the trunk was drawing over the player and fading,
## while the canopy sat underneath. Both names are validated now.
const OVERHEAD_LAYER_NAMES := ["over", "top"]


func _find_over_layers(n: Node) -> Array:
	var out := []
	if n is TileMapLayer and String(n.name) in OVERHEAD_LAYER_NAMES:
		out.append(n)
	for c in n.get_children():
		out.append_array(_find_over_layers(c))
	return out
