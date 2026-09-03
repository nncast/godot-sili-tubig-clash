extends Control

@onready var code_label: Label = $VBox/CodeLabel
@onready var player_list: ItemList = $VBox/PlayerList
@onready var start_button: Button = $VBox/StartButton
@onready var leave_button: Button = $VBox/LeaveButton
@onready var status_label: Label = $VBox/StatusLabel


func _ready() -> void:
	NetworkManager.player_list_changed.connect(_refresh_player_list)
	NetworkManager.lobby_code_ready.connect(_on_lobby_code_ready)
	NetworkManager.discovery_unavailable.connect(_on_discovery_unavailable)
	NetworkManager.server_disconnected.connect(_on_disconnected)

	start_button.pressed.connect(_on_start_pressed)
	leave_button.pressed.connect(_on_leave_pressed)

	status_label.text = ""

	if NetworkManager.is_host():
		code_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_update_host_label()
		start_button.visible = true
	else:
		code_label.text = "Joined lobby"
		start_button.visible = false

	_refresh_player_list()


func _on_lobby_code_ready(_code: String) -> void:
	_update_host_label()


func _on_discovery_unavailable() -> void:
	_update_host_label()
	status_label.text = "Lobby codes are unavailable on this device - have players join by IP."


## The IP is always shown: on phone hotspots and guest Wi-Fi the broadcast that
## backs lobby codes is frequently dropped, and typing the IP always works.
func _update_host_label() -> void:
	var ip := NetworkManager.get_local_ip()
	var lines: Array[String] = []
	if NetworkManager.discovery_active:
		lines.append("Lobby Code: %s" % NetworkManager.lobby_code)
	if ip.is_empty():
		lines.append("No network connection detected")
	else:
		lines.append("Or join by IP: %s" % ip if NetworkManager.discovery_active else "Join by IP: %s" % ip)
	code_label.text = "\n".join(lines)


func _refresh_player_list() -> void:
	player_list.clear()
	for id in NetworkManager.players.keys():
		var suffix := " (host)" if id == 1 else ""
		player_list.add_item(str(NetworkManager.players[id]) + suffix)

	if NetworkManager.is_host():
		start_button.disabled = NetworkManager.players.size() < 2


func _on_start_pressed() -> void:
	if NetworkManager.players.size() < 2:
		status_label.text = "Need at least 2 players to start."
		return
	NetworkManager.start_match()


func _on_leave_pressed() -> void:
	NetworkManager.leave_game()
	get_tree().change_scene_to_file("res://ui/title_screen/title_screen.tscn")


func _on_disconnected() -> void:
	get_tree().change_scene_to_file("res://ui/title_screen/title_screen.tscn")
