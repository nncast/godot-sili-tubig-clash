extends Control

## Status-line colours. These change with lobby STATE, so they are feedback
## rather than styling and cannot live in the theme. Everything else about this
## screen's appearance comes from ui/theme/ui_theme.tres and the scene file.
const READY_COLOR := Color(1.0, 0.824, 0.498)
const WAITING_COLOR := Color(0.62, 0.58, 0.55)

## Pre-match lobby.
##
## Two ways out of here, and the difference matters:
##
##   Start Series   - the competitive mode. Requires exactly
##                    NetworkManager.MATCH_SIZE players because the match is
##                    balanced for 4v1 and nothing else. Opens a rotation
##                    where every player is the Sili once, and keeps a
##                    running score across the set.
##   Practice Match - unranked, any size from 2 up, random Sili. For testing
##                    and for letting people try the game between sets. It
##                    clears any series in progress rather than scoring into
##                    it, so a casual round can't touch the standings.

@onready var panel: PanelContainer = $Panel
@onready var title_label: Label = $Panel/Margin/VBox/Title
@onready var code_label: Label = $Panel/Margin/VBox/CodeLabel
@onready var player_list: ItemList = $Panel/Margin/VBox/PlayerList
@onready var start_button: Button = $Panel/Margin/VBox/StartButton
@onready var practice_button: Button = $Panel/Margin/VBox/ButtonRow/PracticeButton
@onready var leave_button: Button = $Panel/Margin/VBox/ButtonRow/LeaveButton
@onready var status_label: Label = $Panel/Margin/VBox/StatusLabel

## A one-off network notice (e.g. discovery being unavailable on this
## Wi-Fi/hotspot) used to be written straight into status_label - but that
## label sits inside the same fixed-height VBox as StartButton/ButtonRow, so a
## message long enough to wrap pushed those buttons around or off the bottom
## of the panel. Routing it through this modal instead means it can never
## resize anything the buttons live in.
@onready var notice_panel: Control = $NoticePanel
@onready var notice_message: Label = $NoticePanel/Panel/Margin/VBox/Message
@onready var notice_ok_button: Button = $NoticePanel/Panel/Margin/VBox/OkButton

## Set only for the host-left notice - lets the shared OK button either just
## dismiss a routine notice (discovery unavailable) or actually leave the
## lobby, depending on which one is currently showing.
var _notice_leads_to_title: bool = false


func _ready() -> void:
	NetworkManager.player_list_changed.connect(_refresh_player_list)
	NetworkManager.lobby_code_ready.connect(_on_lobby_code_ready)
	NetworkManager.discovery_unavailable.connect(_on_discovery_unavailable)
	NetworkManager.server_disconnected.connect(_on_disconnected)

	start_button.pressed.connect(_on_start_pressed)
	practice_button.pressed.connect(_on_practice_pressed)
	leave_button.pressed.connect(_on_leave_pressed)
	notice_ok_button.pressed.connect(_on_notice_ok_pressed)

	status_label.text = ""
	notice_panel.visible = false

	if NetworkManager.is_host():
		_update_host_label()
		start_button.visible = true
		practice_button.visible = true
	else:
		code_label.text = "Joined lobby"
		start_button.visible = false
		practice_button.visible = false

	_refresh_player_list()


func _on_lobby_code_ready(_code: String) -> void:
	_update_host_label()


func _on_discovery_unavailable() -> void:
	_update_host_label()
	_show_notice("Lobby codes unavailable - join by IP.")


func _show_notice(message: String) -> void:
	notice_message.text = message
	notice_panel.visible = true


func _on_notice_ok_pressed() -> void:
	notice_panel.visible = false
	if _notice_leads_to_title:
		_notice_leads_to_title = false
		get_tree().change_scene_to_file("res://ui/title_screen/title_screen.tscn")


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

	var count := NetworkManager.players.size()
	var needed := NetworkManager.MATCH_SIZE

	for id in NetworkManager.players.keys():
		var suffix := " (host)" if id == 1 else ""
		player_list.add_item(str(NetworkManager.players[id]) + suffix)

	# Empty seats are drawn rather than left blank, so the host sees at a
	# glance how many are still missing - one generic row rather than a
	# numbered slot per seat, since "player 2" means nothing to whoever is
	# about to fill it.
	for i in range(count, needed):
		var idx := player_list.add_item("WAITING FOR PLAYERS")
		player_list.set_item_disabled(idx, true)
		player_list.set_item_custom_fg_color(idx, Color(0.55, 0.55, 0.58))

	if not NetworkManager.is_host():
		status_label.text = "Waiting for the host..."
		return

	var ready_to_start: bool = count == needed
	start_button.disabled = not ready_to_start
	start_button.text = "Start Series  %d/%d" % [count, needed]
	practice_button.disabled = count < NetworkManager.MIN_PRACTICE_PLAYERS

	# One short line. The reasoning behind the player count and the two modes
	# lives in the button tooltips, so the panel does not have to explain the
	# rules of the game every time somebody opens it.
	if ready_to_start:
		status_label.text = "Ready - %d rounds." % needed
		status_label.add_theme_color_override("font_color", READY_COLOR)
	else:
		status_label.text = "Waiting for %d more..." % (needed - count)
		status_label.add_theme_color_override("font_color", WAITING_COLOR)


func _on_start_pressed() -> void:
	if NetworkManager.players.size() != NetworkManager.MATCH_SIZE:
		ModalDialog.show_message("Not Enough Players",
			"Need exactly %d players to start a Ranked Series." % NetworkManager.MATCH_SIZE,
			ModalDialog.ERROR_COLOR)
		return
	NetworkManager.start_series()


func _on_practice_pressed() -> void:
	if NetworkManager.players.size() < NetworkManager.MIN_PRACTICE_PLAYERS:
		ModalDialog.show_message("Not Enough Players",
			"Need at least %d players for a Classic match." % NetworkManager.MIN_PRACTICE_PLAYERS,
			ModalDialog.ERROR_COLOR)
		return
	NetworkManager.start_practice_match()


## Host migration isn't supported (see _on_disconnected), so the host walking out
## is not the same act as a client walking out - it ends the lobby for everyone
## still sitting in it. The confirmation says which of the two this is.
func _on_leave_pressed() -> void:
	var message := "You'll go back to the title screen."
	if NetworkManager.is_host():
		message = "You're hosting. Leaving closes this lobby for everyone in it."
	ModalDialog.show_confirm("Leave Lobby?", message, "Leave", "Stay", _leave_to_title)


func _leave_to_title() -> void:
	NetworkManager.leave_game()
	get_tree().change_scene_to_file("res://ui/title_screen/title_screen.tscn")


## Host migration isn't supported, so a host dropping while everyone is still
## sitting in the lobby is exactly as unrecoverable as it is mid-match - see
## match_result.gd's version of this same rule. Shown as a modal rather than
## a silent scene change so nobody watching the player list is left wondering
## why they were suddenly bounced.
func _on_disconnected() -> void:
	_notice_leads_to_title = true
	_show_notice("Host has left the match. Game cannot continue.")
	# Auto-advance in case nobody clicks OK - same 2.5s beat match_result.gd
	# uses for the equivalent mid-match notice.
	get_tree().create_timer(2.5).timeout.connect(_auto_return_to_title)


func _auto_return_to_title() -> void:
	if not _notice_leads_to_title or not is_inside_tree():
		return
	_notice_leads_to_title = false
	get_tree().change_scene_to_file("res://ui/title_screen/title_screen.tscn")
