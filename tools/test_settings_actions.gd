extends Node

## Covers the in-match settings panel: Play Again, Leave Game, and the
## waiting-for-host label a client sees in place of the restart button.

const PORT := 37807

var _f := 0
var _arena: Node = null
var _frame := 0


func _c(l: String, a: Variant, e: Variant) -> void:
	if a == e: print("  PASS  %s" % l)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [l, a, e])


func _ready() -> void:
	print("In-match settings panel")
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(PORT, 8) != OK:
		print("  FAIL  no server"); get_tree().quit(1); return
	multiplayer.multiplayer_peer = peer

	NetworkManager.players = {1: "Host", 2: "Bee", 3: "Cee"}
	NetworkManager.roles = {1: "sili", 2: "tubig", 3: "tubig"}
	NetworkManager.current_map_id = MapRegistry.DEFAULT_MAP
	NetworkManager.arena_ready_peers = {1: true, 2: true, 3: true}

	_arena = load("res://game/arena/arena.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_arena)


func _process(_d: float) -> void:
	_frame += 1
	if _frame < 10:
		return

	var vbox := _arena.get_node("HUD/SettingsPopup/VBox")
	var play_again := vbox.get_node_or_null("PlayAgainButton") as Button
	var status := vbox.get_node_or_null("HostStatusLabel") as Label
	var leave := vbox.get_node_or_null("LeaveGameButton") as Button

	_c("Play Again exists", play_again != null, true)
	_c("Leave Game exists", leave != null, true)
	_c("host status label exists", status != null, true)
	if play_again == null or leave == null or status == null:
		_finish(); return

	_c("Leave Game label", leave.text, "Leave Game")
	_c("Play Again sits above Leave Game", play_again.get_index() < leave.get_index(), true)

	# Host, three players: restart offered, nothing to wait for.
	_c("host sees Play Again", play_again.visible, true)
	_c("host's button is usable", play_again.disabled, false)
	_c("no waiting label for the host", status.visible, false)

	# Drop below the practice minimum: the button must explain itself.
	NetworkManager.players = {1: "Host"}
	NetworkManager.player_list_changed.emit()
	_c("too few players disables it", play_again.disabled, true)
	_c("and says why", status.visible, true)

	# restart_round refuses at that size rather than launching a broken round.
	# Checked through the roles table: _launch_round rebuilds it from `players`,
	# so a round that fired would have collapsed it to the one player left.
	NetworkManager.restart_round()
	_c("restart_round refuses below the minimum", NetworkManager.roles.size(), 3)

	NetworkManager.players = {1: "Host", 2: "Bee", 3: "Cee"}
	NetworkManager.player_list_changed.emit()
	_c("re-enabled once the lobby refills", play_again.disabled, false)

	# A client is not offered the button at all - just told what it waits on.
	_simulate_client(play_again, status)

	_finish()


## The client branch needs multiplayer.has_multiplayer_peer() true AND
## is_host() false, which an offline stand-in does not produce - offline is
## treated AS host on purpose, so swapping the peer for null would exercise
## the wrong path and pass for the wrong reason.
##
## A client peer pointed at a port with nothing on it gives both conditions
## honestly: the peer object exists, is_server() is false, and no second
## process is needed.
func _simulate_client(play_again: Button, status: Label) -> void:
	var host_peer := multiplayer.multiplayer_peer
	var client := ENetMultiplayerPeer.new()
	client.create_client("127.0.0.1", 37899)  # nothing is listening; that's fine
	multiplayer.multiplayer_peer = client

	_c("is_host() is false for a client", NetworkManager.is_host(), false)
	_arena.call("_refresh_play_again_state")
	_c("client is NOT offered Play Again", play_again.visible, false)
	_c("client sees the waiting label", status.visible, true)
	_c("and it names what it waits on", status.text, "Waiting for host...")

	multiplayer.multiplayer_peer = host_peer


func _finish() -> void:
	print("ALL TESTS PASSED" if _f == 0 else "%d FAILED" % _f)
	get_tree().quit(1 if _f > 0 else 0)
