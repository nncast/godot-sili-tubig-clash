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
## FOUNTAIN STATE. The fountain ships two whole art variants, "active"
## (drinkable) and "inactive" (drained), as siblings under the fountain node -
## exactly one is visible at a time, chosen by is_charged. The inactive variant
## additionally carries a grey tint so a drained fountain still reads as
## drained rather than merely as a second bowl design; the active variant is
## shown exactly as authored, untinted.
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
			var active: Node = fountain.get_node_or_null("active")
			var inactive: Node = fountain.get_node_or_null("inactive")
			_c("fountain has an active variant", active != null, true)
			_c("fountain has an inactive variant", inactive != null, true)
			if active == null or inactive == null:
				_finish()
				return

			var inactive_basin := inactive.get_node_or_null("bottom") as CanvasItem
			var active_basin := active.get_node_or_null("bottom") as CanvasItem

			_c("fountain starts spent", fountain.is_charged, false)
			_c("spent shows the inactive variant", inactive.visible, true)
			_c("spent hides the active variant", active.visible, false)
			var spent_tint: Color = fountain.SPENT_TINT
			_c("inactive basin carries the spent tint",
				Color(inactive_basin.modulate.r, inactive_basin.modulate.g, inactive_basin.modulate.b),
				Color(spent_tint.r, spent_tint.g, spent_tint.b))
			_c("active basin is untinted while hidden",
				active_basin.modulate, Color(1, 1, 1, 1))

			# Both variants' own canopies have to fade like any other prop.
			var inactive_top := inactive.get_node_or_null("top") as TileMapLayer
			var active_top := active.get_node_or_null("top") as TileMapLayer
			_c("inactive variant has a canopy layer", inactive_top != null, true)
			_c("active variant has a canopy layer", active_top != null, true)
			if inactive_top != null and active_top != null:
				_c("inactive canopy carries the fade script", inactive_top.get_script() != null, true)
				_c("active canopy carries the fade script", active_top.get_script() != null, true)
				_c("inactive canopy is above the players", inactive_top.z_index, 21)
				_c("active canopy is above the players", active_top.z_index, 21)
				_c("inactive canopy shares the basin's tint",
					Color(inactive_top.modulate.r, inactive_top.modulate.g, inactive_top.modulate.b),
					Color(inactive_basin.modulate.r, inactive_basin.modulate.g, inactive_basin.modulate.b))

				# The tint must not touch alpha - canopy_fade owns that, and a
				# full Color write here would snap a fading canopy back to
				# opaque every time the fountain changed state.
				inactive_top.modulate.a = 0.3
				fountain._apply_visual_state()
				# is_equal_approx, not ==: Color stores 32-bit floats, so 0.3
				# does not survive the round trip exactly.
				_c("tinting leaves the fade alpha alone",
					is_equal_approx(inactive_top.modulate.a, 0.3), true)
				fountain.is_charged = true
				_c("charging swaps to the active variant", active.visible, true)
				_c("charging hides the inactive variant", inactive.visible, false)
				fountain.is_charged = false
				inactive_top.modulate.a = 1.0

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
