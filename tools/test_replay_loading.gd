extends Node

## Covers the end-of-match overlay's exit paths, and the fountain's resting
## look.
##
## PLAY AGAIN. Four different things hide behind that one button, and only two
## of them used to raise the loading curtain - the two that advance a networked
## round, because those route through NetworkManager._rpc_load_arena. The
## offline replay called get_tree().reload_current_scene() directly and the
## end-of-series exit called change_scene_to_file() directly, so both rebuilt
## the arena on the main thread with the results still frozen on screen. This
## asserts the curtain is up for the replay path.
##
## FOUNTAIN TINT. The basin is tinted to show whether a drink is waiting. Spent
## used to be a 0.55 grey multiply, and since every round starts spent and only
## charges at the first speed stage (30s in), the fountain spent the opening of
## every match looking like broken art. Spent must now be the sprite as drawn.
##
## Run it as a SCENE, for the autoload reason spelled out in test_endgame.gd:
##
##     godot --headless --path . res://tools/test_replay_loading.tscn

const PORT := 37807
const TIMEOUT_SECONDS := 30.0

var _f := 0
var _arena: Node = null
var _frame := 0
var _phase := 0
var _settle := 0
var _started_at := 0
var _saw_curtain := false


func _c(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		print("  PASS  %s" % label)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [label, actual, expected])


func _ready() -> void:
	# Under the root, not as the current scene: the replay frees the current
	# scene, and that must not be the test.
	if get_tree().current_scene == self:
		var runner := Node.new()
		runner.name = "ReplayLoadingTest"
		runner.set_script(get_script())
		get_tree().root.add_child.call_deferred(runner)
		return

	print("Replay curtain / fountain tint tests")
	_started_at = Time.get_ticks_msec()

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, 8)
	if err != OK:
		print("  FAIL  could not open a local server on %d (error %d)" % [PORT, err])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer

	NetworkManager.players = {1: "Host", 2: "Bee"}
	NetworkManager.roles = {1: "sili", 2: "tubig"}
	NetworkManager.current_map_id = MapRegistry.DEFAULT_MAP

	_arena = load("res://game/arena/arena.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_arena)


func _process(_delta: float) -> void:
	if get_tree().current_scene == self:
		return

	_frame += 1
	if _frame < 8:
		return
	if _settle > 0:
		_settle -= 1
		return
	if (Time.get_ticks_msec() - _started_at) / 1000.0 > TIMEOUT_SECONDS:
		_c("finished within %ds" % int(TIMEOUT_SECONDS), false, true)
		_finish()
		return

	match _phase:
		0:
			var fountains := get_tree().get_nodes_in_group("fountain")
			_c("fountain is in the map", fountains.size() > 0, true)
			if fountains.is_empty():
				_finish()
				return
			var fountain: Node = fountains[0]
			var basin := fountain.get_node_or_null("bottom") as CanvasItem

			_c("fountain starts spent", fountain.is_charged, false)
			_c("spent basin is not darkened", basin.modulate, Color(1, 1, 1, 1))
			# The state worth noticing is the one that stands out, so ready has
			# to be BRIGHTER than resting rather than resting being dimmer.
			var ready_tint: Color = fountain.READY_TINT
			var spent_tint: Color = fountain.SPENT_TINT
			_c("ready reads brighter than spent",
				ready_tint.g > spent_tint.g and ready_tint.b > spent_tint.b, true)

			# The fountain's own canopy has to fade like any other prop.
			var top := fountain.get_node_or_null("top") as TileMapLayer
			_c("fountain has a canopy layer", top != null, true)
			if top != null:
				_c("fountain canopy carries the fade script", top.get_script() != null, true)
				_c("fountain canopy is above the players", top.z_index, 21)
				# Only the basin used to be tinted, so one prop rendered in two
				# states: the bowl lit up for a ready drink while the top of the
				# fountain stayed flat.
				_c("both halves share a tint", top.modulate, basin.modulate)

				# And the tint must not touch alpha - canopy_fade owns that, and
				# a full Color write here would snap a fading canopy back to
				# opaque every time the fountain changed state.
				top.modulate.a = 0.3
				fountain._apply_tint()
				# is_equal_approx, not ==: Color stores 32-bit floats, so 0.3
				# does not survive the round trip exactly.
				_c("tinting leaves the fade alpha alone",
					is_equal_approx(top.modulate.a, 0.3), true)
				fountain.is_charged = true
				_c("charging still leaves it alone",
					is_equal_approx(top.modulate.a, 0.3), true)
				_c("charging brightens the canopy too",
					top.modulate.r > spent_tint.r or top.modulate.g > spent_tint.g, true)
				fountain.is_charged = false
				top.modulate.a = 1.0

			_phase = 1
			return

		1:
			# End the match for real, so the overlay comes up the way it does
			# in play rather than by being poked into visibility.
			MatchManager._rpc_start_match(MatchManager.MATCH_DURATION)
			MatchManager.end_match(true)
			_settle = 5
			_phase = 2
			return

		2:
			var overlay := _find_result_overlay()
			_c("result overlay is showing", overlay != null and overlay.visible, true)
			if overlay == null:
				_finish()
				return
			var replay: Button = overlay.get_node_or_null("Column/Buttons/ReplayButton")
			_c("replay button exists", replay != null, true)
			if replay == null:
				_finish()
				return

			# NetworkManager.is_host() is true here, and no series is running,
			# so this is the practice branch - which goes through
			# _rpc_load_arena and therefore through the curtain.
			replay.pressed.emit()
			_c("replay button disables itself against a double press",
				replay.disabled, true)
			_phase = 3
			return

		3:
			if _curtain().visible:
				_saw_curtain = true
				_c("Play Again raised the curtain", true, true)
				_c("time scale was restored before loading",
					is_equal_approx(Engine.time_scale, 1.0), true)
				_finish()
				return
			# Still waiting; the timeout above is the failure path.
			return


func _curtain() -> Control:
	return LoadingScreen.get_node("Root") as Control


func _find_result_overlay() -> Control:
	for node in _arena.find_children("*", "Control", true, false):
		var control := node as Control
		if control == null or control.get_script() == null:
			continue
		if control.get_script().resource_path.ends_with("match_result.gd"):
			return control
	return null


func _finish() -> void:
	if not _saw_curtain:
		_c("Play Again raised the curtain", false, true)
	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d TEST(S) FAILED" % _f)
	get_tree().quit(1 if _f > 0 else 0)
