extends Node

## Covers the title screen's leaderboard entry point and its flat buttons.
##
## THE FOCUS BOX. Godot draws a Button's normal/hover/pressed styleboxes behind
## an `if (!flat)` guard, but it draws the FOCUS stylebox unconditionally. So a
## flat button that has been clicked keeps painting the theme's focus box -
## which here is an opaque dark panel with a gold border - and looks exactly
## like `flat` had been switched off. It persists too, because the button holds
## focus after the click.
##
## The fix is a "FlatButton" theme variation with an empty focus stylebox, not
## focus_mode = NONE: keyboard and gamepad navigation still has to work, and the
## theme's gold font_focus_color still marks where you are.
##
## THE PANEL. set_anchors_preset() moves anchors and leaves offsets alone, so
## the panel Control kept its zero size and everything inside it hugged the
## top-left corner. Centring is a CenterContainer's job.
##
## Run it as a SCENE, for the autoload reason spelled out in test_endgame.gd:
##
##     godot --headless --path . res://tools/test_title_screen.tscn

const FLAT_BUTTONS := [
	"VBox/HostButton", "VBox/JoinButton", "VBox/HowToButton",
	"VBox/SettingsButton", "VBox/ExitButton", "LeaderboardButton",
]

var _f := 0
var _title: Control = null


func _c(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		print("  PASS  %s" % label)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [label, actual, expected])


func _ready() -> void:
	if get_tree().current_scene == self:
		var runner := Node.new()
		runner.name = "TitleScreenTest"
		runner.set_script(get_script())
		get_tree().root.add_child.call_deferred(runner)
		return

	print("Title screen tests")
	_title = (load("res://ui/title_screen/title_screen.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_title)
	await get_tree().process_frame
	await _run()
	_finish()


func _run() -> void:
	# --- Flat buttons ---
	for path in FLAT_BUTTONS:
		var button := _title.get_node_or_null(path) as Button
		if button == null:
			_c("%s exists" % path, false, true)
			continue
		_c("%s is flat" % path.get_file(), button.flat, true)
		_c("%s has no focus box" % path.get_file(),
			button.get_theme_stylebox("focus").get_class(), "StyleBoxEmpty")
		# The variation must only override focus. Everything else still comes
		# from Button, so a non-flat button using it would look normal.
		_c("%s still inherits the rest of the theme" % path.get_file(),
			button.get_theme_stylebox("normal").get_class(), "StyleBoxFlat")
		# Not focus_mode = NONE: keyboard navigation has to survive this.
		_c("%s is still focusable" % path.get_file(),
			button.focus_mode != Control.FOCUS_NONE, true)
		_c("%s still marks focus by colour" % path.get_file(),
			button.get_theme_color("font_focus_color") != button.get_theme_color("font_color"),
			true)

	# --- Leaderboard entry point ---
	var trophy := _title.get_node_or_null("LeaderboardButton") as Button
	_c("the button comes from the scene, not from code",
		trophy != null and trophy.icon != null, true)
	# Declared after VBox but before the modals, so it stops drawing over their
	# dim - and stops being clickable through it.
	_c("the button sits under the modal panels",
		trophy.get_index() < _title.get_node("JoinPanel").get_index(), true)

	var panel := _title.get_node_or_null("LeaderboardPanel")
	_c("the panel is built", panel != null, true)
	if panel == null:
		return
	_c("the panel starts hidden", panel.visible, false)

	trophy.pressed.emit()
	_c("the scene button opens it", panel.visible, true)

	# Containers lay out on the frame AFTER their children change, so measuring
	# straight after open() reads the geometry from before the table was built.
	await get_tree().process_frame
	await get_tree().process_frame

	# --- Centring ---
	var box := panel.get_node_or_null("Centre/Panel") as PanelContainer
	_c("the panel is inside a CenterContainer", box != null, true)
	if box == null:
		return
	var viewport: Vector2 = _title.get_viewport_rect().size
	var centre: Vector2 = box.get_global_rect().get_center()
	# Within a pixel: a container can land on a half-pixel for an odd-sized
	# child, which is not the bug this is guarding.
	_c("it is centred horizontally", absf(centre.x - viewport.x * 0.5) <= 1.0, true)
	_c("it is centred vertically", absf(centre.y - viewport.y * 0.5) <= 1.0, true)
	_c("and it is not collapsed to nothing", box.get_global_rect().size.x > 100.0, true)

	panel.close()
	_c("escape-style close works", panel.visible, false)


func _finish() -> void:
	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d TEST(S) FAILED" % _f)
	get_tree().quit(1 if _f > 0 else 0)
