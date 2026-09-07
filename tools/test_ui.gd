extends SceneTree

## Checks every dialog actually ends up wearing the shared style, rather than
## just trusting a setup function ran. The reference values are read straight
## out of ui/theme/ui_theme.tres, so this fails if a scene stops inheriting the
## theme OR if somebody re-adds a per-node override that drifts from it.

var _f := 0
var _frame := 0
var _scenes := {}

func _c(l, a, e) -> void:
	if a == e: print("  PASS  %s" % l)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [l, a, e])

func _initialize() -> void:
	print("UI consistency")
	for key in {"title": "res://ui/title_screen/title_screen.tscn",
				"lobby": "res://ui/lobby/lobby.tscn",
				"settings": "res://ui/settings/settings.tscn",
				"arena": "res://game/arena/arena.tscn"}:
		var packed = load({"title": "res://ui/title_screen/title_screen.tscn",
			"lobby": "res://ui/lobby/lobby.tscn",
			"settings": "res://ui/settings/settings.tscn",
			"arena": "res://game/arena/arena.tscn"}[key])
		var n = packed.instantiate()
		root.add_child(n)
		_scenes[key] = n

var _reference: StyleBoxFlat = null

func _ref() -> StyleBoxFlat:
	if _reference == null:
		var theme: Theme = load("res://ui/theme/ui_theme.tres")
		_reference = theme.get_stylebox("panel", "PanelContainer")
	return _reference

func _matches_shell(panel) -> bool:
	if panel == null: return false
	var sb = panel.get_theme_stylebox("panel")
	if sb == null or not (sb is StyleBoxFlat): return false
	var r := _ref()
	return sb.bg_color.is_equal_approx(r.bg_color) \
		and sb.border_color.is_equal_approx(r.border_color) \
		and sb.border_width_top == r.border_width_top \
		and sb.corner_radius_top_left == r.corner_radius_top_left

func _process(_d: float) -> bool:
	_frame += 1
	if _frame < 2: return false

	var t = _scenes["title"]
	_c("title: How to Play is the reference shell",
		_matches_shell(t.get_node_or_null("HowToPanel/Panel")), true)
	_c("title: join prompt matches it",
		_matches_shell(t.get_node_or_null("JoinPanel/Panel")), true)
	_c("title: join prompt now blocks clicks behind it",
		t.get_node_or_null("JoinPanel/Dim") != null, true)

	_c("title: exit prompt is an in-scene modal, not a native Window",
		_matches_shell(t.get_node_or_null("ExitPanel/Panel")), true)
	_c("title: exit prompt has its own dim",
		t.get_node_or_null("ExitPanel/Dim") != null, true)
	_c("title: no native OS dialogs remain",
		t.find_children("*", "Window", true, false).size(), 0)
	_c("title: all three modals share the same shape",
		t.get_node_or_null("JoinPanel/Panel/Margin/VBox") != null
		and t.get_node_or_null("HowToPanel/Panel/Margin/VBox") != null
		and t.get_node_or_null("ExitPanel/Panel/Margin/VBox") != null, true)

	var l = _scenes["lobby"]
	_c("lobby: panel matches", _matches_shell(l.get_node_or_null("Panel")), true)
	var start = l.get_node_or_null("Panel/Margin/VBox/StartButton")
	_c("lobby: start button styled",
		start != null and start.get_theme_stylebox("normal").bg_color.is_equal_approx(
			load("res://ui/theme/ui_theme.tres").get_stylebox("normal", "Button").bg_color), true)
	_c("lobby: start button has a tooltip",
		start != null and not String(start.tooltip_text).is_empty(), true)
	_c("lobby: practice button has a tooltip",
		not String(l.get_node("Panel/Margin/VBox/ButtonRow/PracticeButton").tooltip_text).is_empty(), true)
	# disabled state must be overridden too, or the button looks broken at 0/5
	_c("lobby: start button has a disabled style",
		start.get_theme_stylebox("disabled") is StyleBoxFlat, true)
	_c("lobby: styling comes from the theme, not per-node overrides",
		not start.has_theme_stylebox_override("normal")
		and not l.get_node("Panel").has_theme_stylebox_override("panel"), true)

	_c("settings: wrapped in a panel",
		_matches_shell(_scenes["settings"].get_node_or_null("Panel")), true)
	_c("settings: sliders survived the reparent",
		_scenes["settings"].get_node_or_null("Panel/MarginContainer/VBox/MasterRow/MasterSlider") != null
		or _scenes["settings"].find_child("MasterSlider", true, false) != null, true)

	var a = _scenes["arena"]
	_c("arena: in-match settings popup matches",
		_matches_shell(a.get_node_or_null("HUD/SettingsPopup")), true)
	_c("arena: settings button has a tooltip",
		not String(a.get_node("HUD/SettingsButton").tooltip_text).is_empty(), true)

	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d TEST(S) FAILED" % _f)
	quit(1 if _f > 0 else 0)
	return true
