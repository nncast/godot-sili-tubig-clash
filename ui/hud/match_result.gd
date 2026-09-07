extends Control

## Row colours for the standings table. These pick a colour per row from the
## result, so they are data rather than styling - a theme entry cannot say
## "gold if this player won". The panel itself is styled in ui_theme.tres.
const GOLD := Color(1.0, 0.824, 0.498)
const TEXT_MUTED := Color(0.62, 0.58, 0.55)

## End-of-match overlay: drops the world into slow motion, freezes the players,
## and puts the verdict in the middle of the screen with somewhere to go next.
##
## The verdict is per-player, not per-match. MatchManager only reports whether
## the Sili won; whether that means YOU WIN depends on which side you're on, so
## the same signal produces opposite text on different screens.
##
## Built in code rather than in the .tscn, matching pregame_reveal.gd - the
## layout is driven by outcome and by whether you're the host, so there's little
## worth laying out by hand.
##
## SLOW MOTION uses Engine.time_scale, which is global and does NOT reset on its
## own. Every exit path from this screen has to put it back to 1.0 or the title
## screen inherits the slowdown - hence _restore_time_scale() and the
## _exit_tree() safety net.

const SLOW_MOTION_SCALE := 0.25
const SLOW_MOTION_RAMP := 0.8
const BACKDROP_ALPHA := 0.72

const COLOR_WIN := Color(1.0, 0.85, 0.35)
const COLOR_LOSE := Color(1.0, 0.42, 0.38)

var _backdrop: ColorRect
var _verdict_label: Label
var _detail_label: Label
var _button_row: HBoxContainer
var _replay_button: Button
var _title_button: Button
var _hint_label: Label
var _fade_tween: Tween
var _standings_panel: PanelContainer
var _standings_rows: VBoxContainer
var _standings_title: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Ignore until there's actually something to click, so the overlay can't
	# swallow input from the HUD underneath it during play.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	_build_ui()

	MatchManager.match_ended.connect(_on_match_ended)
	# The scores arrive from the server a moment AFTER the match-ended signal,
	# so redrawing only in _on_match_ended would leave every client showing
	# last round's table. Listening to both means the host sees it instantly
	# and clients see it as soon as the packet lands.
	SeriesManager.standings_changed.connect(_on_standings_changed)


func _exit_tree() -> void:
	# Last line of defence: if this scene is torn down by anything other than
	# our own buttons (host reloading the arena, a disconnect), the slowdown
	# must not follow us into the next scene.
	_restore_time_scale()


func _build_ui() -> void:
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.color = Color(0.02, 0.03, 0.06, 0.0)
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 18)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)

	_verdict_label = Label.new()
	_verdict_label.name = "Verdict"
	_verdict_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_verdict_label.add_theme_font_size_override("font_size", 88)
	_verdict_label.add_theme_constant_override("outline_size", 12)
	_verdict_label.add_theme_color_override("font_outline_color", Color.BLACK)
	column.add_child(_verdict_label)

	_detail_label = Label.new()
	_detail_label.name = "Detail"
	_detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_label.add_theme_font_size_override("font_size", 26)
	_detail_label.add_theme_color_override("font_color", Color(0.88, 0.9, 0.95))
	column.add_child(_detail_label)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 18)
	column.add_child(spacer)

	_build_standings(column)

	var spacer_two := Control.new()
	spacer_two.custom_minimum_size = Vector2(0, 18)
	column.add_child(spacer_two)

	_button_row = HBoxContainer.new()
	_button_row.name = "Buttons"
	_button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_button_row.add_theme_constant_override("separation", 24)
	column.add_child(_button_row)

	_replay_button = Button.new()
	_replay_button.name = "ReplayButton"
	_replay_button.text = "Play Again"
	_replay_button.custom_minimum_size = Vector2(210, 56)
	_replay_button.pressed.connect(_on_replay_pressed)
	_button_row.add_child(_replay_button)

	_title_button = Button.new()
	_title_button.name = "TitleButton"
	_title_button.text = "Back to Title"
	_title_button.custom_minimum_size = Vector2(210, 56)
	_title_button.pressed.connect(_on_title_pressed)
	_button_row.add_child(_title_button)

	_hint_label = Label.new()
	_hint_label.name = "Hint"
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_font_size_override("font_size", 18)
	_hint_label.add_theme_color_override("font_color", Color(0.72, 0.75, 0.82))
	column.add_child(_hint_label)


func _on_match_ended(sili_won: bool) -> void:
	var i_won := _local_role() == ("sili" if sili_won else "tubig")

	_verdict_label.text = "YOU WIN!" if i_won else "YOU LOSE!"
	_verdict_label.add_theme_color_override("font_color", COLOR_WIN if i_won else COLOR_LOSE)
	_detail_label.text = "The Sili caught everyone." if sili_won else "The Tubig lasted the whole match."

	_refresh_standings()

	# Only the host can advance the series - a client pressing this would be
	# reassigning roles for a lobby it doesn't own. Clients get told to wait
	# instead of being handed a button that quietly does nothing.
	var can_advance := NetworkManager.is_host() or not multiplayer.has_multiplayer_peer()
	var series_done: bool = SeriesManager.is_active and SeriesManager.series_complete()

	if not SeriesManager.is_active:
		_replay_button.text = "Play Again"
	elif series_done:
		_replay_button.text = "Back to Lobby"
	else:
		_replay_button.text = "Next Round (%d/%d)" % [
			SeriesManager.round_number(), SeriesManager.rounds_total()]

	_replay_button.visible = can_advance
	if can_advance:
		_hint_label.text = ""
	elif series_done:
		_hint_label.text = "Series complete. Waiting for the host..."
	else:
		_hint_label.text = "Waiting for the host to start the next round..."

	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_title_button.grab_focus()

	_start_slow_motion()

	# ignore_time_scale, or the fade would crawl at the slowed rate and the
	# verdict would take three seconds to become readable.
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.set_ignore_time_scale(true)
	_fade_tween.tween_property(_backdrop, "color:a", BACKDROP_ALPHA, 0.45)


## Whose side the person at this screen is on. Falls back to Tubig for an
## offline test session, where there are no assigned roles at all.
func _local_role() -> String:
	var my_id := multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1
	return NetworkManager.roles.get(my_id, "tubig")



## Eased rather than snapped: the moment of the tag reads better if the world
## drags to a halt over a beat instead of stuttering into it.
func _start_slow_motion() -> void:
	var tween := create_tween()
	tween.set_ignore_time_scale(true)
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# tween_method rather than tween_property: Engine is an engine singleton,
	# not a scene node, and driving its property through a setter is the
	# unambiguous way to animate it.
	tween.tween_method(_set_time_scale, 1.0, SLOW_MOTION_SCALE, SLOW_MOTION_RAMP)


func _set_time_scale(value: float) -> void:
	Engine.time_scale = value


func _restore_time_scale() -> void:
	Engine.time_scale = 1.0


## Three different jobs behind one button, because from the player's side it is
## always just "the thing that happens next".
func _on_replay_pressed() -> void:
	_restore_time_scale()

	if not NetworkManager.is_host():
		# Offline session - nothing to coordinate, just run the level again.
		get_tree().reload_current_scene()
		return

	if SeriesManager.is_active and SeriesManager.series_complete():
		# The set is over. Back to the lobby with the standings intact, so the
		# table stays readable while people decide whether to run another.
		get_tree().change_scene_to_file("res://ui/lobby/lobby.tscn")
	elif SeriesManager.is_active:
		# Hands the Sili role to the next player in the fixed rotation.
		NetworkManager.start_next_round()
	else:
		NetworkManager.start_practice_match()


func _on_title_pressed() -> void:
	_restore_time_scale()
	NetworkManager.leave_game()
	get_tree().change_scene_to_file("res://ui/title_screen/title_screen.tscn")


# --- Series standings ---

## A compact table under the verdict: place, name, points, and this round's
## gain. Shown after every round rather than only at the end of the set,
## because the whole point of a rotation is knowing where you stand while
## there are still rounds left to change it.
func _build_standings(column: VBoxContainer) -> void:
	_standings_panel = PanelContainer.new()
	_standings_panel.name = "Standings"
	_standings_panel.visible = false
	_standings_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_standings_panel.custom_minimum_size = Vector2(460, 0)

	# No stylebox override here on purpose. PanelContainer is styled in the
	# project theme (ui/theme/ui_theme.tres), so this board picks up the same
	# shell as every other dialog just by being a PanelContainer.
	column.add_child(_standings_panel)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)
	_standings_panel.add_child(inner)

	_standings_title = Label.new()
	_standings_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_standings_title.add_theme_font_size_override("font_size", 20)
	_standings_title.add_theme_color_override("font_color", GOLD)
	inner.add_child(_standings_title)

	_standings_rows = VBoxContainer.new()
	_standings_rows.add_theme_constant_override("separation", 4)
	inner.add_child(_standings_rows)


## Only repaints once the overlay is actually up. A mid-match sync (a player
## dropping, say) should not pop the results board over live gameplay.
func _on_standings_changed() -> void:
	if visible:
		_refresh_standings()


func _refresh_standings() -> void:
	if _standings_panel == null:
		return
	if not SeriesManager.is_active:
		_standings_panel.visible = false
		return

	for child in _standings_rows.get_children():
		_standings_rows.remove_child(child)
		child.queue_free()

	var done: bool = SeriesManager.series_complete()
	_standings_title.text = "FINAL STANDINGS" if done else "STANDINGS - after round %d of %d" % [
		SeriesManager.round_index, SeriesManager.rounds_total()]

	var my_id := multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1
	var place := 0
	for row in SeriesManager.standings():
		place += 1
		_standings_rows.add_child(_standings_row(place, row, row["peer_id"] == my_id, done))

	_standings_panel.visible = true


func _standings_row(place: int, row: Dictionary, is_me: bool, done: bool) -> HBoxContainer:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)

	# The winner is gold, you are white, everyone else is dimmed - so a glance
	# finds your own line without having to read the names.
	var colour := TEXT_MUTED
	if done and place == 1:
		colour = GOLD
	elif is_me:
		colour = Color.WHITE

	var place_label := Label.new()
	place_label.text = "%d." % place
	place_label.custom_minimum_size = Vector2(34, 0)
	place_label.add_theme_font_size_override("font_size", 18)
	place_label.add_theme_color_override("font_color", colour)
	line.add_child(place_label)

	var name_label := Label.new()
	name_label.text = String(row["name"]) + ("  (you)" if is_me else "")
	name_label.custom_minimum_size = Vector2(210, 0)
	name_label.clip_text = true
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", colour)
	line.add_child(name_label)

	# Eliminations and rescues sit next to the total so the number is
	# explainable: you can see WHY somebody is ahead, not just that they are.
	var detail := Label.new()
	detail.text = "%d elim  %d resc" % [int(row["eliminations"]), int(row["rescues"])]
	detail.custom_minimum_size = Vector2(130, 0)
	detail.add_theme_font_size_override("font_size", 15)
	detail.add_theme_color_override("font_color", Color(colour.r, colour.g, colour.b, 0.65))
	line.add_child(detail)

	var points := Label.new()
	points.text = "%d pts" % int(row["points"])
	points.custom_minimum_size = Vector2(70, 0)
	points.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	points.add_theme_font_size_override("font_size", 18)
	points.add_theme_color_override("font_color", colour)
	line.add_child(points)

	return line
