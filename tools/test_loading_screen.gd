extends Node

## Covers the curtain that hides the arena load.
##
## The three things that can quietly break it, in the order they would bite:
##
##   1. It has to SURVIVE the scene change it is covering. It is an autoload,
##      so it hangs off the tree root rather than off any scene - if it ever
##      became a child of a scene instead, it would be freed halfway through
##      the swap and the freeze would be back, uncovered.
##   2. It has to actually reach the screen BEFORE the blocking work starts.
##      change_scene() waits two process frames for that reason; a version that
##      loaded first would draw the curtain only after the stutter it exists to
##      hide.
##   3. It has to come back down. A curtain that sticks is worse than none.
##
## Run it as a SCENE, for the autoload reason spelled out in test_endgame.gd:
##
##     godot --headless --path . res://tools/test_loading_screen.tscn

## Longer than MIN_VISIBLE_TIME + FADE_OUT_TIME with room to spare, so a slow
## machine reports a real failure rather than a timeout.
const TIMEOUT_SECONDS := 20.0

const TARGET_SCENE := "res://ui/title_screen/title_screen.tscn"

var _f := 0
var _frame := 0
var _phase := 0
var _started_at := 0
var _seen_visible := false
var _runner_moved := false
var _first_runner_x := 0.0


func _c(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		print("  PASS  %s" % label)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [label, actual, expected])


func _ready() -> void:
	# Run from under the ROOT, not as the current scene. change_scene_to_packed
	# frees whatever the current scene is - which, if that were this node,
	# would be the test itself, halfway through the thing it is testing.
	if get_tree().current_scene == self:
		var runner := Node.new()
		runner.name = "LoadingScreenTest"
		runner.set_script(get_script())
		get_tree().root.add_child.call_deferred(runner)
		return

	print("Loading screen tests")
	_started_at = Time.get_ticks_msec()


func _process(_delta: float) -> void:
	if get_tree().current_scene == self:
		return  # the launcher copy; the real run is the sibling under root

	_frame += 1
	if _frame < 3:
		return

	if (Time.get_ticks_msec() - _started_at) / 1000.0 > TIMEOUT_SECONDS:
		_c("finished within %ds" % int(TIMEOUT_SECONDS), false, true)
		_finish()
		return

	match _phase:
		0:
			_c("curtain starts hidden", _curtain().visible, false)
			_c("curtain is above every in-game layer", LoadingScreen.layer, 128)
			_c("curtain sits under the tree root, not in a scene",
				LoadingScreen.get_parent(), get_tree().root)
			LoadingScreen.change_scene(TARGET_SCENE)
			_phase = 1
			return

		1:
			# Up within a couple of frames, and before the load has had any
			# chance to finish - that ordering is the point of the curtain.
			if not _curtain().visible:
				return
			_seen_visible = true
			_c("curtain came up", true, true)
			_c("dim plate is 50% black",
				_dim().color, Color(0.0, 0.0, 0.0, 0.5))
			_c("label reads Loading", _label().text.begins_with("Loading"), true)
			_c("both runners are on screen", _runners().size(), 2)
			_c("runners are playing", _runners()[0].is_playing(), true)
			_c("runners use the east-facing run frames",
				_runners()[0].sprite_frames.get_frame_count(&"run"),
				LoadingScreen.RUN_FRAME_ORIGINS.size())
			_first_runner_x = _runners()[0].position.x
			_phase = 2
			return

		2:
			# The characters have to actually move, or the screen reads as
			# frozen - which is the exact impression it exists to prevent.
			if not is_equal_approx(_runners()[0].position.x, _first_runner_x):
				_runner_moved = true
			if _curtain().visible:
				return
			_c("runners animated while loading", _runner_moved, true)
			_c("curtain came back down", _curtain().visible, false)
			_c("curtain is fully opaque again for next time",
				_curtain().modulate.a, 1.0)
			_c("the scene actually changed",
				get_tree().current_scene.scene_file_path, TARGET_SCENE)
			_c("curtain outlived the scene change",
				is_instance_valid(LoadingScreen), true)
			_c("it was visible at some point", _seen_visible, true)
			_finish()
			return


func _curtain() -> Control:
	return LoadingScreen.get_node("Root") as Control


func _dim() -> ColorRect:
	return _curtain().get_node("Dim") as ColorRect


func _label() -> Label:
	return _curtain().get_node("Centre/Column/LoadingLabel") as Label


func _runners() -> Array:
	return _curtain().find_children("*", "AnimatedSprite2D", true, false)


func _finish() -> void:
	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d TEST(S) FAILED" % _f)
	get_tree().quit(1 if _f > 0 else 0)
