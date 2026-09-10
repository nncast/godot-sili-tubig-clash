extends Node

## Guards the bug that made the canopy fade a Tubig-only feature.
##
## canopy_fade.gd finds whoever this client controls by scanning the "player"
## group. tubig.gd joined that group; sili.gd only ever joined "sili". So on
## the machine playing the Sili, _local_player stayed null for the whole match:
## no canopy ever lifted, and every "over"/"top" layer on the map re-scanned an
## empty group once per physics frame looking for something that could not be
## there.
##
## Nothing caught it because the fade LOOKS fine in any test where the local
## player happens to be a Tubig - which is four cases out of five.
##
## Run it as a SCENE, for the autoload reason spelled out in test_endgame.gd:
##
##     godot --headless --path . res://tools/test_canopy_local_player.tscn

const PORT := 37801

var _f := 0
var _arena: Node = null
var _frame := 0
var _phase := 0
## Idle frames run far faster than the 60Hz physics tick in headless, so an
## assertion on the very next _process would often land before canopy_fade's
## _physics_process had seen the move at all. Each phase waits this many frames,
## which is comfortably more than one physics tick at any sane frame rate.
const SETTLE_FRAMES := 20
var _settle := 0
## One-shot: the absent peer only has to check in once, and re-reporting every
## frame would keep resetting the settle countdown that waits for the spawn.
var _peers_reported := false
var _canopy: TileMapLayer = null
var _sili: Node2D = null
var _faded_alpha_seen: float = 1.0


func _c(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		print("  PASS  %s" % label)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [label, actual, expected])


func _ready() -> void:
	print("Canopy fade / local player tests")

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, 8)
	if err != OK:
		print("  FAIL  could not open a local server on %d (error %d)" % [PORT, err])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer

	# THIS PEER IS THE SILI. That is the whole point - the bug is invisible
	# from a Tubig's seat.
	NetworkManager.players = {1: "Host", 2: "Bee"}
	NetworkManager.roles = {1: "sili", 2: "tubig"}
	NetworkManager.current_map_id = MapRegistry.DEFAULT_MAP

	_arena = load("res://game/arena/arena.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_arena)


func _process(_delta: float) -> void:
	_frame += 1
	if _frame < 6:
		return
	# "Bee" is registered in the lobby but has no real peer behind her, and
	# arena.gd holds the round until everyone in NetworkManager.players reports
	# their scene built (see report_arena_ready). Standing in for her here is
	# what lets the round launch now instead of after READY_TIMEOUT, twenty
	# seconds from now, with this test long finished.
	if not _peers_reported:
		_peers_reported = true
		NetworkManager._record_arena_ready(2)
		_settle = 3
		return

	if _settle > 0:
		_settle -= 1
		return

	match _phase:
		0:
			var silis := get_tree().get_nodes_in_group("sili")
			_c("Sili spawned", silis.size(), 1)
			if silis.is_empty():
				_finish()
				return
			_sili = silis[0]

			_c("Sili is in the \"player\" group", _sili.is_in_group("player"), true)

			_canopy = _find_canopy()
			_c("found a canopy layer to test", _canopy != null, true)
			if _canopy == null:
				_finish()
				return

			_c("canopy is above the players", _canopy.z_index, 21)
			_c("faded alpha is the lowered value", _canopy.faded_alpha < 0.3, true)
			# WHOLE needs no ShaderMaterial, and building one anyway would mean
			# forty-odd compiled materials on boracay doing nothing.
			_c("prop canopy uses WHOLE", _canopy.fade_mode, 0)
			_c("WHOLE builds no material", _canopy.material, null)
			_c("canopy starts fully opaque", _canopy.modulate.a, 1.0)

			# Stand the Sili in the middle of that canopy. Physics has to run
			# for _physics_process to pick it up, hence the phases.
			_sili.global_position = _canopy.to_global(
				_canopy.map_to_local(_canopy.get_used_cells()[0]))
			_phase = 1
			_settle = SETTLE_FRAMES
			return

		1:
			# One physics tick is enough to resolve the player and start the
			# ramp; the ramp itself takes fade_speed seconds to finish, so the
			# assertion is "it moved", not "it arrived".
			_c("canopy resolved the local Sili", _canopy._local_player, _sili)
			_c("canopy started fading", _canopy._blend > 0.0, true)
			# The regression this file exists for: the old shader mask faded
			# ONE 16x16 tile of a 64x64 canopy, because it compared a
			# layer-local rect against a quadrant-local VERTEX. WHOLE fades the
			# layer, so the whole prop lifts and there is no space to mismatch.
			_c("the whole layer is fading, not one tile",
				_canopy.modulate.a < 1.0, true)

			_faded_alpha_seen = _canopy.modulate.a
			_sili.global_position += Vector2(100000, 100000)
			_phase = 2
			_settle = SETTLE_FRAMES
			return

		2:
			_c("canopy lets go when the Sili leaves", _canopy._target_blend, 0.0)
			_c("canopy fades back towards opaque", _canopy._blend < 1.0, true)
			_c("layer returns towards opaque", _canopy.modulate.a > _faded_alpha_seen, true)
			_check_every_prop_canopy()
			_finish()
			return


## Every overhead layer in the loaded map must carry the fade script. The
## umbrellas shipped with a "top" at z_index 21 and no script at all, so they
## drew over the player and never moved - the same symptom as the palms, from a
## different cause, and invisible unless something walks the whole tree.
func _check_every_prop_canopy() -> void:
	var missing: Array[String] = []
	var total := 0
	for node in _arena.find_children("*", "TileMapLayer", true, false):
		var layer := node as TileMapLayer
		if layer == null or String(layer.name) not in ["top", "over"]:
			continue
		if layer.get_used_cells().is_empty():
			continue
		total += 1
		if layer.get_script() == null:
			missing.append(String(_arena.get_path_to(layer)))
	_c("found overhead layers to check", total > 0, true)
	if not missing.is_empty():
		print("        missing the script: %s" % ", ".join(missing.slice(0, 6)))
	_c("every overhead layer fades", missing.size(), 0)


## The first "top"/"over" layer carrying the fade script that actually has
## tiles painted in it - an empty layer would pass every assertion vacuously.
func _find_canopy() -> TileMapLayer:
	for node in _arena.find_children("*", "TileMapLayer", true, false):
		var layer := node as TileMapLayer
		if layer == null or layer.get_script() == null:
			continue
		if String(layer.name) not in ["top", "over"]:
			continue
		if layer.get_used_cells().is_empty():
			continue
		return layer
	return null


func _finish() -> void:
	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d TEST(S) FAILED" % _f)
	get_tree().quit(1 if _f > 0 else 0)
