extends Control

@onready var name_edit: LineEdit = $VBox/NameRow/NameEdit
@onready var host_button: Button = $VBox/HostButton
@onready var join_button: Button = $VBox/JoinButton
@onready var how_to_button: Button = $VBox/HowToButton
@onready var settings_button: Button = $VBox/SettingsButton
@onready var exit_button: Button = $VBox/ExitButton
@onready var status_label: Label = $VBox/StatusLabel

## All three modals - join, how to play, exit - are now the same shape in the
## scene: a full-rect Control holding a Dim plate and a centred PanelContainer.
## The dim is a sibling of the panel INSIDE that Control, which is what makes
## the whole thing show and hide as one node and stops clicks reaching the
## title buttons underneath.
@onready var join_panel: Control = $JoinPanel
@onready var exit_panel: Control = $ExitPanel

@onready var code_edit: LineEdit = $JoinPanel/Panel/Margin/VBox/CodeEdit
@onready var join_confirm_button: Button = $JoinPanel/Panel/Margin/VBox/ButtonsRow/JoinConfirmButton
@onready var join_cancel_button: Button = $JoinPanel/Panel/Margin/VBox/ButtonsRow/JoinCancelButton

var _leaderboard_panel: Control = null

@onready var leaderboard_button: Button = $LeaderboardButton
@onready var how_to_panel: Control = $HowToPanel
@onready var how_to_body: RichTextLabel = $HowToPanel/Panel/Margin/VBox/Body
@onready var how_to_close_button: Button = $HowToPanel/Panel/Margin/VBox/CloseButton


func _ready() -> void:
	AudioManager.play_title_music()
	join_panel.visible = false
	how_to_panel.visible = false
	exit_panel.visible = false
	status_label.text = ""

	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	how_to_button.pressed.connect(_on_how_to_pressed)
	how_to_close_button.pressed.connect(_on_how_to_close_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	exit_button.pressed.connect(_on_exit_pressed)

	join_confirm_button.pressed.connect(_on_join_confirm_pressed)
	join_cancel_button.pressed.connect(_on_join_cancel_pressed)
	code_edit.text_submitted.connect(func(_t: String) -> void: _on_join_confirm_pressed())

	$ExitPanel/Panel/Margin/VBox/ButtonsRow/ExitConfirmButton.pressed.connect(_on_exit_confirmed)
	$ExitPanel/Panel/Margin/VBox/ButtonsRow/ExitCancelButton.pressed.connect(_on_exit_cancel_pressed)

	_build_leaderboard()

	NetworkManager.player_list_changed.connect(_on_player_list_changed)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.code_lookup_failed.connect(_on_code_lookup_failed)


func _on_host_pressed() -> void:
	var err := NetworkManager.host_game(_resolved_name())
	if err != OK:
		if err == ERR_ALREADY_IN_USE or err == ERR_CANT_CREATE:
			status_label.text = "Port %d is already in use. Close any other copy of the game and try again." % NetworkManager.GAME_PORT
		else:
			status_label.text = "Couldn't host (error %s)." % err
		return
	get_tree().change_scene_to_file("res://ui/lobby/lobby.tscn")


func _on_join_pressed() -> void:
	_close_all_panels()
	status_label.text = ""
	join_panel.visible = true
	code_edit.text = ""
	code_edit.grab_focus()
	join_confirm_button.disabled = false


func _on_join_cancel_pressed() -> void:
	join_panel.visible = false
	join_button.grab_focus()
	join_confirm_button.disabled = false


## Accepts either a 4-digit lobby code (LAN broadcast lookup) or the host's IP
## address, shown on the host's lobby screen. The IP path is the reliable one on
## phone hotspots and guest Wi-Fi, where broadcast is often dropped.
func _on_join_confirm_pressed() -> void:
	if join_confirm_button.disabled:
		return

	var entry := code_edit.text.strip_edges()

	if _looks_like_ip(entry):
		status_label.text = "Connecting to %s..." % entry
		join_confirm_button.disabled = true
		NetworkManager.join_by_ip(entry, _resolved_name())
		return

	if entry.length() != 4 or not entry.is_valid_int():
		status_label.text = "Enter the 4-digit lobby code, or the host's IP address."
		return

	status_label.text = "Looking for lobby %s..." % entry
	join_confirm_button.disabled = true
	NetworkManager.join_by_code(entry, _resolved_name())


## Fires once we're actually registered with the host - safe to move on.
func _on_player_list_changed() -> void:
	if not NetworkManager.is_host() and NetworkManager.players.size() > 0:
		get_tree().change_scene_to_file("res://ui/lobby/lobby.tscn")


func _on_connection_failed() -> void:
	status_label.text = "Couldn't reach the host. Check both devices are on the same Wi-Fi and that the host's firewall allows the game."
	join_confirm_button.disabled = false


func _on_code_lookup_failed() -> void:
	status_label.text = "No lobby found with that code. If you're on a phone hotspot, type the host's IP address instead (shown on their lobby screen)."
	join_confirm_button.disabled = false


func _looks_like_ip(text: String) -> bool:
	var parts := text.split(".")
	if parts.size() != 4:
		return false
	for part in parts:
		if part.is_empty() or not part.is_valid_int():
			return false
		var value := int(part)
		if value < 0 or value > 255:
			return false
	return true


## The rules overlay. Closing the join prompt first means the two panels can
## never end up stacked on top of each other.
func _on_how_to_pressed() -> void:
	_close_all_panels()
	status_label.text = ""
	how_to_panel.visible = true
	# Reopening always starts at the top rather than wherever the last reader
	# left the scroll.
	how_to_body.scroll_to_line(0)
	how_to_close_button.grab_focus()


func _on_how_to_close_pressed() -> void:
	how_to_panel.visible = false
	how_to_button.grab_focus()


func _on_exit_pressed() -> void:
	_close_all_panels()
	exit_panel.visible = true


func _on_exit_cancel_pressed() -> void:
	exit_panel.visible = false
	exit_button.grab_focus()


func _on_exit_confirmed() -> void:
	get_tree().quit()


## Escape closes any open overlay instead of falling through to anything else.
## The event is swallowed so it can't also reach other dialogs.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	
	if how_to_panel.visible:
		_on_how_to_close_pressed()
		get_viewport().set_input_as_handled()
	elif join_panel.visible:
		_on_join_cancel_pressed()
		get_viewport().set_input_as_handled()
	elif exit_panel.visible:
		_on_exit_cancel_pressed()
		get_viewport().set_input_as_handled()
	elif _leaderboard_panel != null and _leaderboard_panel.visible:
		_leaderboard_panel.close()
		get_viewport().set_input_as_handled()


## The BUTTON lives in title_screen.tscn - it is a corner icon, positioned and
## given its trophy art there, which is a layout decision and belongs in the
## scene. Only the panel is built here, for the same reason match_result.gd
## builds its own: the contents are a variable-length table driven by saved
## data, with very little worth laying out by hand.
func _build_leaderboard() -> void:
	_leaderboard_panel = load("res://ui/leaderboard/leaderboard_panel.gd").new()
	_leaderboard_panel.name = "LeaderboardPanel"
	add_child(_leaderboard_panel)
	leaderboard_button.pressed.connect(_on_leaderboard_pressed)


func _on_leaderboard_pressed() -> void:
	_close_all_panels()
	_leaderboard_panel.open()


func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file("res://ui/settings/settings.tscn")


func _resolved_name() -> String:
	var typed := name_edit.text.strip_edges()
	return typed if not typed.is_empty() else "Player%d" % (randi() % 1000)


## Helper to close all panels at once
func _close_all_panels() -> void:
	join_panel.visible = false
	how_to_panel.visible = false
	exit_panel.visible = false
	if _leaderboard_panel != null:
		_leaderboard_panel.close()
