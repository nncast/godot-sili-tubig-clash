extends Control

## Feedback colours. These track STATE rather than styling, so they belong here
## and not in ui_theme.tres.
const ERROR_COLOR := Color(1.0, 0.45, 0.40)
const INFO_COLOR := Color(0.80, 0.82, 0.86)
## CodeEdit has no border in the base theme (see ui_theme.tres's
## StyleBoxFlat_surface) - this is added on top of it, not swapped in, so the
## field keeps its normal look otherwise.
const BORDER_ACTIVE_COLOR := Color(0.45, 0.85, 0.95)

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
## Anything that happens WHILE the join modal is open reports here, not to
## StatusLabel.
##
## StatusLabel is the last child of $VBox - the same container as the Host/Join/
## Settings/Exit buttons. The join modal covers that column with a dim plate, so
## a "no lobby found" written to StatusLabel was being drawn behind the dim, in
## the button stack, underneath the very dialog the player was looking at. The
## message about the code you just typed has to appear next to the field you
## typed it into.
@onready var join_status: Label = $JoinPanel/Panel/Margin/VBox/JoinStatus
@onready var join_confirm_button: Button = $JoinPanel/Panel/Margin/VBox/ButtonsRow/JoinConfirmButton
@onready var join_cancel_button: Button = $JoinPanel/Panel/Margin/VBox/ButtonsRow/JoinCancelButton
@onready var auto_join_button: Button = $JoinPanel/Panel/Margin/VBox/AutoJoinButton

## Set the moment the player backs out of a join attempt (Cancel or Escape) and
## cleared the moment a new one starts. Guards the async replies below - a code
## lookup can take up to five seconds, and without this flag a cancel followed
## by a stale code_lookup_failed/connection_failed would still pop an error, or
## a stale success would still drop the player into a lobby they already quit.
var _join_cancelled: bool = false

## True while the CURRENT lookup is an Auto Join (searching for any nearby
## game) rather than a typed code/IP - only changes which wording
## _on_code_lookup_failed shows, since both paths fail the same way.
var _auto_join_in_progress: bool = false

@onready var how_to_panel: Control = $HowToPanel
@onready var how_to_body: RichTextLabel = $HowToPanel/Panel/Margin/VBox/Body
@onready var how_to_close_button: Button = $HowToPanel/Panel/Margin/VBox/CloseButton


func _ready() -> void:
	AudioManager.play_title_music()
	join_panel.visible = false
	how_to_panel.visible = false
	exit_panel.visible = false
	status_label.text = ""
	join_status.text = ""

	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	how_to_button.pressed.connect(_on_how_to_pressed)
	how_to_close_button.pressed.connect(_on_how_to_close_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	exit_button.pressed.connect(_on_exit_pressed)

	join_confirm_button.pressed.connect(_on_join_confirm_pressed)
	join_cancel_button.pressed.connect(_on_join_cancel_pressed)
	auto_join_button.pressed.connect(_on_auto_join_pressed)
	code_edit.text_submitted.connect(func(_t: String) -> void: _on_join_confirm_pressed())

	$ExitPanel/Panel/Margin/VBox/ButtonsRow/ExitConfirmButton.pressed.connect(_on_exit_confirmed)
	$ExitPanel/Panel/Margin/VBox/ButtonsRow/ExitCancelButton.pressed.connect(_on_exit_cancel_pressed)

	NetworkManager.player_list_changed.connect(_on_player_list_changed)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.code_lookup_failed.connect(_on_code_lookup_failed)


func _on_host_pressed() -> void:
	var err := NetworkManager.host_game(_resolved_name())
	if err != OK:
		var message: String
		if err == ERR_ALREADY_IN_USE or err == ERR_CANT_CREATE:
			message = "Port %d is already in use. Close any other copy of the game and try again." % NetworkManager.GAME_PORT
		else:
			message = "Couldn't host (error %s)." % err
		ModalDialog.show_message("Couldn't Host", message, ERROR_COLOR)
		return
	get_tree().change_scene_to_file("res://ui/lobby/lobby.tscn")


func _on_join_pressed() -> void:
	_close_all_panels()
	status_label.text = ""
	_set_join_status("")
	join_panel.visible = true
	code_edit.text = ""
	code_edit.grab_focus()
	join_confirm_button.disabled = false
	auto_join_button.disabled = false
	_join_cancelled = false
	_auto_join_in_progress = false


func _on_join_cancel_pressed() -> void:
	# A code lookup or an IP connect may already be in flight - leave_game()
	# tears down whatever peer NetworkManager opened for it (or does nothing
	# if there wasn't one) so cancelling here can never leave a half-open
	# connection quietly trying to finish in the background. _join_cancelled
	# then tells any reply that arrives afterwards (a late code_lookup_failed,
	# connection_failed, or even a successful connect racing the click) to be
	# ignored instead of resurrecting a dialog the player already left.
	_join_cancelled = true
	NetworkManager.leave_game()
	join_panel.visible = false
	_set_join_status("")
	join_button.grab_focus()
	join_confirm_button.disabled = false
	auto_join_button.disabled = false


## Routes to whichever surface the player can actually see. A join attempt can
## outlive its dialog - the discovery lookup runs for five seconds and the
## player may cancel partway through - and a status written to a hidden panel
## would be silently swallowed. If the modal is gone, the title screen's own
## status line takes the message instead.
##
## Progress only ("Connecting to X...", "Looking for lobby X..."), never
## errors - a failure is disruptive enough to warrant ModalDialog instead (see
## _on_connection_failed and _on_code_lookup_failed), which also means it's
## never silently lost the way a label behind a closed panel would be.
##
## JoinStatus and the CodeEdit border are updated unconditionally, not inside
## the branch below - both callers that clear this (_on_join_pressed,
## _on_join_cancel_pressed) call it while join_panel.visible is momentarily
## the OPPOSITE of what it's about to become, so gating this on that flag
## left the label stuck visible and the border stuck highlighted from the
## previous attempt. Writing to a hidden label is harmless; not writing to a
## visible one is the actual bug.
func _set_join_status(message: String) -> void:
	join_status.text = message
	join_status.visible = not message.is_empty()
	join_status.add_theme_color_override("font_color", INFO_COLOR)
	_set_code_edit_active(not message.is_empty())

	if join_panel.visible:
		status_label.text = ""
	else:
		status_label.text = message
		status_label.add_theme_color_override("font_color", INFO_COLOR)


## The label text carries the message; the border is just a second, glance-
## able cue that something about this field is in flight - lit while a lookup
## or connection attempt is running, plain the rest of the time.
func _set_code_edit_active(active: bool) -> void:
	if not active:
		code_edit.remove_theme_stylebox_override("normal")
		return
	var base := code_edit.get_theme_stylebox("normal")
	if not (base is StyleBoxFlat):
		return
	var highlighted: StyleBoxFlat = (base as StyleBoxFlat).duplicate()
	highlighted.border_color = BORDER_ACTIVE_COLOR
	highlighted.set_border_width_all(2)
	code_edit.add_theme_stylebox_override("normal", highlighted)


## Accepts either a 4-digit lobby code (LAN broadcast lookup) or the host's IP
## address, shown on the host's lobby screen. The IP path is the reliable one on
## phone hotspots and guest Wi-Fi, where broadcast is often dropped.
func _on_join_confirm_pressed() -> void:
	if join_confirm_button.disabled:
		return

	var entry := code_edit.text.strip_edges()

	if _looks_like_ip(entry):
		_auto_join_in_progress = false
		_set_join_status("Connecting to %s..." % entry)
		join_confirm_button.disabled = true
		auto_join_button.disabled = true
		NetworkManager.join_by_ip(entry, _resolved_name())
		return

	if entry.length() != 4 or not entry.is_valid_int():
		ModalDialog.show_message("Invalid Entry",
			"Enter the 4-digit lobby code, or the host's IP address.", ERROR_COLOR)
		code_edit.grab_focus()
		return

	_auto_join_in_progress = false
	_set_join_status("Looking for lobby %s..." % entry)
	join_confirm_button.disabled = true
	auto_join_button.disabled = true
	NetworkManager.join_by_code(entry, _resolved_name())


## The "Auto Join" button: skips the code entirely and asks the LAN/hotspot
## whether anyone is hosting at all. Meant for the common case - one other
## person on the same Wi-Fi - where making someone read out a 4-digit code is
## friction for no reason.
func _on_auto_join_pressed() -> void:
	if auto_join_button.disabled:
		return

	_auto_join_in_progress = true
	_set_join_status("Searching this network for a game...")
	join_confirm_button.disabled = true
	auto_join_button.disabled = true
	NetworkManager.join_auto(_resolved_name())


## Fires once we're actually registered with the host - safe to move on.
func _on_player_list_changed() -> void:
	if NetworkManager.is_host() or NetworkManager.players.is_empty():
		return
	if _join_cancelled:
		# The player backed out while this connection was still landing -
		# don't drop them into a lobby they already chose to leave.
		NetworkManager.leave_game()
		return
	get_tree().change_scene_to_file("res://ui/lobby/lobby.tscn")


func _on_connection_failed() -> void:
	if _join_cancelled:
		return
	_set_join_status("")
	ModalDialog.show_message("Connection Failed",
		"Couldn't reach the host.\nCheck you're on the same Wi-Fi, and that the host's firewall allows the game.",
		ERROR_COLOR)
	join_confirm_button.disabled = false
	auto_join_button.disabled = false


func _on_code_lookup_failed() -> void:
	if _join_cancelled:
		return
	_set_join_status("")
	if _auto_join_in_progress:
		ModalDialog.show_message("No Game Found",
			"No games found on this network.\nAsk the host for their lobby code or IP and type it in above.",
			ERROR_COLOR)
	else:
		ModalDialog.show_message("No Game Found",
			"No lobby found with that code.\nOn a phone hotspot, type the host's IP instead - it's on their lobby screen.",
			ERROR_COLOR)
	join_confirm_button.disabled = false
	auto_join_button.disabled = false


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


func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file("res://ui/settings/settings.tscn")


func _resolved_name() -> String:
	var typed := name_edit.text.strip_edges()
	return typed if not typed.is_empty() else "Player%d" % (randi() % 1000)


## Helper to close all panels at once
func _close_all_panels() -> void:
	join_panel.visible = false
	_set_join_status("")
	how_to_panel.visible = false
	exit_panel.visible = false
