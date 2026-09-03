extends Control

@onready var name_edit: LineEdit = $VBox/NameRow/NameEdit
@onready var host_button: Button = $VBox/HostButton
@onready var join_button: Button = $VBox/JoinButton
@onready var settings_button: Button = $VBox/SettingsButton
@onready var exit_button: Button = $VBox/ExitButton
@onready var status_label: Label = $VBox/StatusLabel

@onready var join_panel: PanelContainer = $JoinPanel
@onready var code_edit: LineEdit = $JoinPanel/VBox/CodeEdit
@onready var join_confirm_button: Button = $JoinPanel/VBox/ButtonsRow/JoinConfirmButton
@onready var join_cancel_button: Button = $JoinPanel/VBox/ButtonsRow/JoinCancelButton

@onready var exit_confirm: ConfirmationDialog = $ExitConfirm


func _ready() -> void:
	AudioManager.play_title_music()
	join_panel.visible = false
	status_label.text = ""

	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	exit_button.pressed.connect(_on_exit_pressed)

	join_confirm_button.pressed.connect(_on_join_confirm_pressed)
	join_cancel_button.pressed.connect(_on_join_cancel_pressed)
	code_edit.text_submitted.connect(func(_t: String) -> void: _on_join_confirm_pressed())

	exit_confirm.confirmed.connect(_on_exit_confirmed)

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
	status_label.text = ""
	join_panel.visible = true
	code_edit.grab_focus()


func _on_join_cancel_pressed() -> void:
	join_panel.visible = false
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


func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file("res://ui/settings/settings.tscn")


func _on_exit_pressed() -> void:
	exit_confirm.popup_centered()


func _on_exit_confirmed() -> void:
	get_tree().quit()


func _resolved_name() -> String:
	var typed := name_edit.text.strip_edges()
	return typed if not typed.is_empty() else "Player%d" % (randi() % 1000)
