extends CanvasLayer

## Global, reusable modal - the one visual shape for "the game needs to tell
## you something" or "the game needs a yes/no before doing something it can't
## undo". Before this, every screen rolled its own version: title_screen's
## exit/join panels, lobby's notice panel, and (worst of all) plain coloured
## status Labels for error text with no dialog around them at all - a
## connection failure and a slider value looked the same, just in a different
## colour.
##
## Built in code, on an autoload CanvasLayer at a high layer, so it always
## draws above whatever scene is active and never needs to be added to a
## scene tree by hand.

const DIM_COLOR := Color(0, 0, 0, 0.6)
const ERROR_COLOR := Color(1.0, 0.45, 0.40)
const INFO_COLOR := Color(0.85, 0.87, 0.9)

var _dim: ColorRect
var _panel: PanelContainer
var _title_label: Label
var _message_label: Label
var _secondary_button: Button
var _primary_button: Button

var _confirm_callback: Callable = Callable()
var _cancel_callback: Callable = Callable()


func _ready() -> void:
	# Above loading_screen.gd's curtain (layer 128) too, so a disconnect or
	# validation message raised mid-transition is still readable instead of
	# being hidden behind it.
	layer = 200
	_build()


func _build() -> void:
	_dim = ColorRect.new()
	_dim.color = DIM_COLOR
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	# CenterContainer, not PRESET_CENTER on the panel itself: set_anchors_preset
	# moves the anchors to the middle but leaves the offsets where they were
	# (zero, for a freshly built Control), which collapses the anchor rect to a
	# single point and lets the panel's minimum size grow down-and-right from
	# it instead of being centered - same bug leaderboard_panel.gd hit and
	# fixed the same way.
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(380, 0)
	centre.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_bottom", 18)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 22)
	vbox.add_child(_title_label)

	_message_label = Label.new()
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_message_label)

	var button_row := HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	button_row.add_theme_constant_override("separation", 10)
	vbox.add_child(button_row)

	# Secondary (Cancel) sits to the LEFT of Primary, so the affirmative action
	# is always the rightmost button - the same left-to-right convention every
	# other confirm dialog in the game already uses (see title_screen's
	# ExitPanel and lobby's NoticePanel).
	_secondary_button = Button.new()
	_secondary_button.custom_minimum_size = Vector2(120, 0)
	_secondary_button.visible = false
	_secondary_button.pressed.connect(_on_secondary_pressed)
	button_row.add_child(_secondary_button)

	_primary_button = Button.new()
	_primary_button.custom_minimum_size = Vector2(120, 0)
	_primary_button.pressed.connect(_on_primary_pressed)
	button_row.add_child(_primary_button)

	visible = false


## A single-button dialog for something the player just needs to see and
## acknowledge - a connection error, a validation message. `color` tints the
## message text so severity reads at a glance without a second modal shape
## for "error" versus "just letting you know".
func show_message(title: String, message: String, color: Color = INFO_COLOR, button_text: String = "OK") -> void:
	_title_label.text = title
	_message_label.text = message
	_message_label.add_theme_color_override("font_color", color)
	_primary_button.text = button_text
	_secondary_button.visible = false
	_confirm_callback = Callable()
	_cancel_callback = Callable()
	visible = true
	_primary_button.grab_focus()


## A yes/no dialog for anything the game shouldn't do without being asked -
## leaving a match, quitting, and so on. Either callback may be left empty; a
## confirmation with nothing to do on cancel just closes the dialog.
func show_confirm(title: String, message: String, confirm_text: String, cancel_text: String,
		on_confirm: Callable, on_cancel: Callable = Callable()) -> void:
	_title_label.text = title
	_message_label.text = message
	_message_label.add_theme_color_override("font_color", INFO_COLOR)
	_primary_button.text = confirm_text
	_secondary_button.text = cancel_text
	_secondary_button.visible = true
	_confirm_callback = on_confirm
	_cancel_callback = on_cancel
	visible = true
	_secondary_button.grab_focus()


func hide_modal() -> void:
	visible = false
	_confirm_callback = Callable()
	_cancel_callback = Callable()


func _on_primary_pressed() -> void:
	var callback := _confirm_callback
	hide_modal()
	if callback.is_valid():
		callback.call()


func _on_secondary_pressed() -> void:
	var callback := _cancel_callback
	hide_modal()
	if callback.is_valid():
		callback.call()


## Escape backs out the same way clicking the "negative" button would - Cancel
## on a confirm, or just dismiss on a one-button message.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		if _secondary_button.visible:
			_on_secondary_pressed()
		else:
			_on_primary_pressed()
		get_viewport().set_input_as_handled()
