extends Node

## Proves the match is decided the moment no Tubig is left standing, rather
## than idling until the last burn clock runs out.
##
## The distinction this guards is the whole point of arena.gd's
## _check_for_sili_win: a BURNING player is only savable while some teammate is
## on their feet to save them, because heat_status.gd refuses a rescue from an
## incapacitated peer and refuses a self-rescue. So "everyone is burning" and
## "everyone is dead" are the same result, reached BURN_TIMEOUT seconds apart.
##
## Runs against the real arena scene over a real (if lonely) ENet server, so
## the spawners, the team panel rebuild and the signal wiring all take part.
## Asserting against a reimplementation of the rule would only prove the
## reimplementation.
##
## Run it as a SCENE, not with --script:
##
##     godot --headless --path . res://tools/test_endgame.tscn
##
## The older tools here are SceneTree scripts, which is fine while a test only
## touches class_names. This one needs MatchManager and NetworkManager, and
## --script compiles the script before the autoloads are registered - so the
## identifiers are simply not found. A one-node scene gets the normal startup
## path and therefore the normal singletons.

const PORT := 37799

var _f := 0
var _arena: Node = null
var _frame := 0
var _phase := 0
var _tubigs: Array = []
var _ended_with: Variant = null


func _c(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		print("  PASS  %s" % label)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [label, actual, expected])


func _ready() -> void:
	print("End-of-match tests")

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, 8)
	if err != OK:
		print("  FAIL  could not open a local server on %d (error %d)" % [PORT, err])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer

	# One Sili and two Tubigs. Two is the smallest number that can tell the
	# two rules apart: with one Tubig, "nobody free" and "everybody dead"
	# happen on the same tag.
	NetworkManager.players = {1: "Host", 2: "Bee", 3: "Cee"}
	NetworkManager.roles = {1: "sili", 2: "tubig", 3: "tubig"}
	NetworkManager.current_map_id = MapRegistry.DEFAULT_MAP

	MatchManager.match_ended.connect(func(sili_won: bool): _ended_with = sili_won)

	_arena = load("res://game/arena/arena.tscn").instantiate()
	# Deferred: this node's own _ready() is running, so the tree is mid-setup
	# and a direct add_child() is refused.
	get_tree().root.add_child.call_deferred(_arena)


func _process(_delta: float) -> void:
	_frame += 1
	# Spawning is deferred and the team panel wires its signals a frame after
	# that, so nothing is asserted until the tree has settled.
	if _frame < 6:
		return

	match _phase:
		0:
			_tubigs = get_tree().get_nodes_in_group("tubig")
			_c("both Tubigs spawned", _tubigs.size(), 2)
			if _tubigs.size() != 2:
				_finish()
				return
			# Skip the reveal countdown; this is about the end of the match.
			MatchManager._rpc_start_match(MatchManager.MATCH_DURATION)
			_c("match is running", MatchManager.is_running, true)
			_phase = 1
			return

		1:
			# First tag. One teammate is still free, so the burn is genuinely
			# savable and the match must keep going.
			_heat(0).ignite()
			_c("first Tubig is burning", _heat(0).is_burning(), true)
			_c("burning, not dead", _heat(0).is_dead(), false)
			_c("match continues while a teammate is up", MatchManager.is_over, false)
			_c("no result announced yet", _ended_with, null)
			_phase = 2
			return

		2:
			# Second tag. Nobody is left who could run the rescue, so both
			# burns are already decided and the match ends on this frame -
			# without waiting out HeatStatus.BURN_TIMEOUT.
			_heat(1).ignite()
			_c("second Tubig is burning", _heat(1).is_burning(), true)
			_c("neither Tubig burned out", _heat(1).is_dead(), false)
			_c("match ended immediately", MatchManager.is_over, true)
			_c("match stopped running", MatchManager.is_running, false)
			_c("Sili is credited with the win", _ended_with, true)
			_finish()
			return



func _heat(index: int) -> HeatStatus:
	return _tubigs[index].get_node("HeatStatus") as HeatStatus


func _finish() -> void:
	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d TEST(S) FAILED" % _f)
	get_tree().quit(1 if _f > 0 else 0)
