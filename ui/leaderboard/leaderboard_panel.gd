extends Control

## The career board, as a modal over the title screen.
##
## Built in code rather than in a .tscn, matching match_result.gd and
## pregame_reveal.gd: the contents are a variable-length table driven by saved
## data, so there is very little here worth laying out by hand. The shell
## (dim + PanelContainer + margin + column) mirrors the title screen's other
## panels so it reads as one of them.

const GOLD := Color(1.0, 0.824, 0.498)
const TEXT := Color(0.88, 0.90, 0.95)
const TEXT_MUTED := Color(0.62, 0.58, 0.55)
const SILI_RED := Color(0.90, 0.28, 0.18)
const TUBIG_BLUE := Color(0.24, 0.55, 0.95)

const MAX_ROWS := 10

var _rows: VBoxContainer
var _empty_label: Label
var _reset_button: Button
var _confirming_reset := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()
	Leaderboard.changed.connect(_refresh)


func open() -> void:
	_confirming_reset = false
	_reset_button.text = "Clear board"
	_refresh()
	visible = true


func close() -> void:
	visible = false


func _build() -> void:
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.02, 0.03, 0.06, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	# No stylebox override: PanelContainer is themed in ui/theme/ui_theme.tres,
	# so this picks up the same shell as the Join and How To dialogs for free.
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(700, 0)
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var title := Label.new()
	title.text = "LEADERBOARD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", GOLD)
	column.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Ranked on points per round, over completed series only."
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 14)
	subtitle.add_theme_color_override("font_color", TEXT_MUTED)
	column.add_child(subtitle)

	column.add_child(_header_row())

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 4)
	column.add_child(_rows)

	_empty_label = Label.new()
	_empty_label.text = "No completed series yet.\nFinish a series to get on the board - practice matches don't count."
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_font_size_override("font_size", 15)
	_empty_label.add_theme_color_override("font_color", TEXT_MUTED)
	column.add_child(_empty_label)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 16)
	column.add_child(buttons)

	_reset_button = Button.new()
	_reset_button.text = "Clear board"
	_reset_button.custom_minimum_size = Vector2(170, 44)
	_reset_button.pressed.connect(_on_reset_pressed)
	buttons.add_child(_reset_button)

	var close_button := Button.new()
	close_button.text = "Close"
	close_button.custom_minimum_size = Vector2(170, 44)
	close_button.pressed.connect(close)
	buttons.add_child(close_button)


func _header_row() -> HBoxContainer:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	var headers := [
		["#", 34, HORIZONTAL_ALIGNMENT_LEFT],
		["PLAYER", 170, HORIZONTAL_ALIGNMENT_LEFT],
		["RATING", 76, HORIZONTAL_ALIGNMENT_RIGHT],
		["HUNT", 66, HORIZONTAL_ALIGNMENT_RIGHT],
		["ESCAPE", 76, HORIZONTAL_ALIGNMENT_RIGHT],
		["SETS", 60, HORIZONTAL_ALIGNMENT_RIGHT],
		["RNDS", 60, HORIZONTAL_ALIGNMENT_RIGHT],
		["PTS", 60, HORIZONTAL_ALIGNMENT_RIGHT],
	]
	for header in headers:
		var label := Label.new()
		label.text = String(header[0])
		label.custom_minimum_size = Vector2(int(header[1]), 0)
		label.horizontal_alignment = header[2]
		label.add_theme_font_size_override("font_size", 13)
		label.add_theme_color_override("font_color", TEXT_MUTED)
		line.add_child(label)
	return line


func _refresh() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()

	var standings: Array = Leaderboard.standings()
	_empty_label.visible = standings.is_empty()

	var place := 0
	var shown := 0
	for row in standings:
		if shown >= MAX_ROWS:
			break
		shown += 1
		# Unplaced players are numbered "-", not given a rank they haven't
		# earned - they are on the list to show progress, not standing.
		var label := "-"
		if row["ranked"]:
			place += 1
			label = "%d" % place
		_rows.add_child(_player_row(label, row))


func _player_row(place_label: String, row: Dictionary) -> HBoxContainer:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)

	var ranked: bool = row["ranked"]
	var is_me: bool = String(row["name"]).to_lower() == NetworkManager.my_name.strip_edges().to_lower()
	var colour := TEXT_MUTED
	if not ranked:
		colour = Color(TEXT_MUTED.r, TEXT_MUTED.g, TEXT_MUTED.b, 0.75)
	elif place_label == "1":
		colour = GOLD
	elif is_me:
		colour = Color.WHITE

	var rounds := int(row["rounds"])
	var needed: int = Leaderboard.PLACEMENT_ROUNDS - rounds

	var cells := [
		[place_label, 34, HORIZONTAL_ALIGNMENT_LEFT, colour],
		[String(row["name"]) + ("  (you)" if is_me else ""), 170,
			HORIZONTAL_ALIGNMENT_LEFT, colour],
		# Unplaced players show what they still owe instead of a number that
		# would be read as a ranking.
		["%.2f" % row["rating"] if ranked else "%d more" % needed, 76,
			HORIZONTAL_ALIGNMENT_RIGHT, colour],
		["%d%%" % roundi(row["hunt_rate"] * 100.0), 66,
			HORIZONTAL_ALIGNMENT_RIGHT, SILI_RED if ranked else colour],
		["%d%%" % roundi(row["escape_rate"] * 100.0), 76,
			HORIZONTAL_ALIGNMENT_RIGHT, TUBIG_BLUE if ranked else colour],
		["%d" % int(row["series_won"]), 60, HORIZONTAL_ALIGNMENT_RIGHT, colour],
		["%d" % rounds, 60, HORIZONTAL_ALIGNMENT_RIGHT, colour],
		["%d" % int(row["points"]), 60, HORIZONTAL_ALIGNMENT_RIGHT, colour],
	]

	for cell in cells:
		var label := Label.new()
		label.text = String(cell[0])
		label.custom_minimum_size = Vector2(int(cell[1]), 0)
		label.horizontal_alignment = cell[2]
		label.clip_text = true
		label.add_theme_font_size_override("font_size", 16)
		label.add_theme_color_override("font_color", cell[3])
		line.add_child(label)

	return line


## Two presses, because this throws away every record on the machine and there
## is no undo.
func _on_reset_pressed() -> void:
	if not _confirming_reset:
		_confirming_reset = true
		_reset_button.text = "Press again to clear"
		return
	_confirming_reset = false
	_reset_button.text = "Clear board"
	Leaderboard.reset()
