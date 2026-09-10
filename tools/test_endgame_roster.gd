extends Node

## Guards the end-of-match rule against ROSTER changes, as opposed to tags.
##
## test_endgame.tscn covers "everyone has been caught". This covers the other
## way a round becomes unwinnable: the Tubig side emptying out by quitting.
## Both end the match, but they arrive through different code, and the empty
## case used to not end it at all.
##
## The cause was a stale read. _check_for_sili_win looped over the cached
## _tubig_players, which only _refresh_team_state rewrites - and queue_free()
## does not actually remove a node until the end of the frame, so even a
## refresh running in the same frame as a departure still found the departing
## body in the group, alive and NORMAL. The check therefore ran one departure
## behind, and once the last body was gone there were no burned/died signals
## left to fire it again. The round played its full clock out with nobody in
## it.
##
## Run as a SCENE, not with --script - it needs the autoloads:
##
##     godot --headless --path . res://tools/test_endgame_roster.tscn

const PORT := 37805

var _f := 0
var _arena: Node = null
var _frame := 0
var _phase := 0
var _ended_with: Variant = null
## Seconds to sit still before the next phase, for the one assertion that has to
## outlast a real interval rather than a frame count.
var _wait := 0.0


func _c(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		print("  PASS  %s" % label)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [label, actual, expected])


func _ready() -> void:
	print("End-of-match roster tests")

	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(PORT, 8) != OK:
		print("  FAIL  could not open a local server on %d" % PORT)
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer

	NetworkManager.players = {1: "Host", 2: "Bee", 3: "Cee"}
	NetworkManager.roles = {1: "sili", 2: "tubig", 3: "tubig"}
	NetworkManager.current_map_id = MapRegistry.DEFAULT_MAP
	# Peers 2 and 3 are not real processes, so they would never check in and
	# the round would sit on arena.gd's READY_TIMEOUT. Check them in by hand.
	NetworkManager.arena_ready_peers = {1: true, 2: true, 3: true}

	MatchManager.match_ended.connect(func(won: bool): _ended_with = won)

	_arena = load("res://game/arena/arena.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_arena)


func _tubigs() -> Array:
	return get_tree().get_nodes_in_group("tubig")


## How many rows the team panel is actually showing. _build_team_panel calls
## remove_child before queue_free, so this reads the truth immediately after a
## rebuild rather than a frame later.
func _panel_rows() -> int:
	var panel := _arena.get_node_or_null("HUD/TeamPanel")
	if panel == null:
		return -1
	return panel.get_child_count()


func _quit_player(peer_id: int, display_name: String) -> void:
	NetworkManager.players.erase(peer_id)
	NetworkManager.roles.erase(peer_id)
	NetworkManager.player_left.emit(peer_id, display_name)


func _process(delta: float) -> void:
	_frame += 1
	if _frame < 10:
		return
	if _wait > 0.0:
		_wait -= delta
		return

	match _phase:
		0:
			_c("both Tubigs spawned", _tubigs().size(), 2)
			if _tubigs().size() != 2:
				_finish()
				return
			MatchManager._rpc_start_match(MatchManager.MATCH_DURATION)
			_c("match is running", MatchManager.is_running, true)
			_phase = 1

		1:
			# --- A peer that missed a spawn signal repairs itself ---
			# Redrawing the panel from an empty roster reproduces exactly what a
			# client sees when a spawned signal arrives out of order or not at
			# all: bodies present in the tree, no rows on screen, and no further
			# signal coming to correct it. Only the periodic reconcile can
			# notice, and before it existed this state lasted the whole round.
			_c("panel is drawn to begin with", _panel_rows(), 2)
			_arena._tubig_players = []
			_arena._build_team_panel()
			_c("panel is now out of step with the tree", _panel_rows(), 0)
			_wait = _arena.PANEL_CHECK_INTERVAL + 0.2
			_phase = 2

		2:
			_c("the panel repaired itself with no signal to prompt it",
				_panel_rows(), 2)
			_phase = 3

		3:
			# One quits. A teammate is still on their feet, so there is still
			# a round to play and it must NOT end here.
			_quit_player(2, "Bee")
			_phase = 4

		4:
			# Counted a frame later on purpose: queue_free() does not remove
			# the node until the end of the frame it was called in, which is
			# the exact lag this whole test exists for. Asserting in the same
			# frame would just measure the engine's deletion schedule.
			_c("one Tubig body remains", _tubigs().size(), 1)
			_c("match continues with one Tubig left", MatchManager.is_over, false)
			_phase = 5

		5:
			# The last one quits. Nobody is left to catch, no tag can ever
			# fire, and nothing else would revisit the question.
			_quit_player(3, "Cee")
			_phase = 6

		6:
			_c("no Tubig bodies remain", _tubigs().size(), 0)
			_c("match ended rather than idling", MatchManager.is_over, true)
			_c("match stopped running", MatchManager.is_running, false)
			_c("Sili credited", _ended_with, true)
			_finish()


func _finish() -> void:
	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d FAILED" % _f)
	get_tree().quit(1 if _f > 0 else 0)
