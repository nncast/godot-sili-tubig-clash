extends Node

## Covers the match feed and what happens when the lobby empties out.
##
## FEED. Lines name the player rather than the role, and colour each name by the
## side it is on - so "Ana tagged Ben" reads red / plain / blue. That means the
## feed renders BBCode now, which in turn means names typed by players have to
## be escaped before they reach it.
##
## THE DOUBLED NAME. The Sili's TagHitbox is a real Area2D and exists in every
## peer's copy of the character, so body_entered fired on all of them and each
## one broadcast its own copy of the line. Two players, two lines. Hit detection
## is authority-only now.
##
## LEAVING. Someone quitting has to show up in the feed, and has to be able to
## turn "Play Again" off - start_practice_match() refuses a short lobby by
## returning silently, so the button used to look like it had frozen.
##
## Run it as a SCENE, for the autoload reason spelled out in test_endgame.gd:
##
##     godot --headless --path . res://tools/test_feed_and_disconnect.tscn

const PORT := 37813

var _f := 0
var _arena: Node = null
var _frame := 0
var _phase := 0
var _settle := 0
var _lines: Array[String] = []
var _kinds: Array[String] = []


func _c(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		print("  PASS  %s" % label)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [label, actual, expected])


func _ready() -> void:
	if get_tree().current_scene == self:
		var runner := Node.new()
		runner.name = "FeedDisconnectTest"
		runner.set_script(get_script())
		get_tree().root.add_child.call_deferred(runner)
		return

	print("Feed / disconnect tests")

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, 8)
	if err != OK:
		print("  FAIL  could not open a local server on %d (error %d)" % [PORT, err])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer

	NetworkManager.players = {1: "Ana", 2: "Ben", 3: "Cely", 4: "Dino"}
	NetworkManager.roles = {1: "sili", 2: "tubig", 3: "tubig", 4: "tubig"}
	NetworkManager.current_map_id = MapRegistry.DEFAULT_MAP

	MatchManager.event_logged.connect(func(msg: String, kind: String):
		_lines.append(msg)
		_kinds.append(kind))

	_arena = load("res://game/arena/arena.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_arena)


func _process(_delta: float) -> void:
	if get_tree().current_scene == self:
		return
	_frame += 1
	if _frame < 8:
		return
	if _settle > 0:
		_settle -= 1
		return

	match _phase:
		0:
			# --- Name colouring ---
			var red := "#" + MatchManager.FEED_SILI_COLOR
			var blue := "#" + MatchManager.FEED_TUBIG_COLOR
			_c("Sili names are red",
				MatchManager.sili_name("Ana"), "[color=%s]Ana[/color]" % red)
			_c("Tubig names are blue",
				MatchManager.tubig_name("Ben"), "[color=%s]Ben[/color]" % blue)
			_c("the two roles are different colours",
				MatchManager.FEED_SILI_COLOR != MatchManager.FEED_TUBIG_COLOR, true)

			# A player calling themselves "[color=red]" would otherwise be
			# writing markup straight into everyone else's HUD.
			_c("a bracket in a name cannot open a tag",
				MatchManager.tubig_name("[color=red]x").contains("[color=red]x"), false)
			_c("the bracket still displays",
				MatchManager.escape_bbcode("[img]"), "[lb]img]")

			# --- Let the other three finish loading ---
			# arena.gd holds the round until every peer in NetworkManager.players
			# has reported its own arena scene built (see report_arena_ready), and
			# peer 1 is the only one that actually exists here. Without standing
			# in for the other three, nothing spawns until READY_TIMEOUT - twenty
			# seconds after this test has finished running.
			for peer_id in [2, 3, 4]:
				NetworkManager._record_arena_ready(peer_id)
			_settle = 3
			_phase = 1
			return

		1:
			# --- One tag, one line ---
			_lines.clear()
			_kinds.clear()
			var sili: Node2D = get_tree().get_nodes_in_group("sili")[0]
			var tubig: Node2D = get_tree().get_nodes_in_group("tubig")[0]
			MatchManager._rpc_start_match(MatchManager.MATCH_DURATION)
			sili._try_tag(tubig)
			_settle = 3
			_phase = 2
			return

		2:
			var tag_lines: Array[String] = []
			for i in _lines.size():
				if _kinds[i] == "tag":
					tag_lines.append(_lines[i])
			_c("a tag logs exactly one line", tag_lines.size(), 1)
			if tag_lines.is_empty():
				_finish()
				return

			var line: String = tag_lines[0]
			_c("the Sili is named, not called \"Sili\"", line.contains("Ana"), true)
			_c("the tagged Tubig is named", line.contains("Ben") or line.contains("Cely"), true)
			_c("the line no longer says \"Sili tagged\"", line.begins_with("Sili tagged"), false)
			_c("the Sili's name is red",
				line.contains("[color=#%s]Ana[/color]" % MatchManager.FEED_SILI_COLOR), true)
			_c("the verb is left uncoloured", line.contains("[/color] tagged [color="), true)

			# --- The gate itself ---
			# The line above went through _try_tag directly, which proves the
			# message but not the guard. A remote peer's copy of the Sili must
			# refuse to claim the hit at all - that copy existing on every
			# machine is what produced one line per peer.
			var sili2: Node2D = get_tree().get_nodes_in_group("sili")[0]
			var victim: Node2D = get_tree().get_nodes_in_group("tubig")[1]
			var real_authority := sili2.get_multiplayer_authority()
			sili2.set_multiplayer_authority(999)  # pretend this is someone else's copy
			_lines.clear()
			_kinds.clear()
			sili2._on_tag_hitbox_body_entered(victim)
			var remote_tags := 0
			for k in _kinds:
				if k == "tag":
					remote_tags += 1
			_c("a non-authority copy claims nothing", remote_tags, 0)
			sili2.set_multiplayer_authority(real_authority)

			# --- Someone leaves ---
			_lines.clear()
			_kinds.clear()
			NetworkManager._on_peer_disconnected(4)  # "Dino", a Tubig
			_settle = 2
			_phase = 3
			return

		3:
			_c("leaving is announced", _lines.size(), 1)
			if not _lines.is_empty():
				_c("the leaver is named", _lines[0].contains("Dino"), true)
				_c("the leaver's name is coloured by their side",
					_lines[0].contains("[color=#%s]" % MatchManager.FEED_TUBIG_COLOR), true)
			_c("they are dropped from the lobby", NetworkManager.players.has(4), false)
			_c("and from the role table", NetworkManager.roles.has(4), false)
			_c("their body is removed from the arena",
				_arena.get_node("TubigContainer").get_node_or_null("player_4"), null)
			_c("only the remaining Tubigs are left in the group",
				get_tree().get_nodes_in_group("tubig").size(), 2)

			# Three left, which practice still allows.
			_c("three players can still start a round",
				NetworkManager.can_start_another_round(), true)
			_c("nothing to explain while it is startable",
				NetworkManager.round_blocked_reason(), "")

			# THE HANG. The quitter's body used to stay standing, and
			# _check_for_sili_win read it as a Tubig still on their feet - so
			# the Sili could never win and the round always ran the full clock
			# out. Tagging out everyone who is actually still here must end it.
			for tubig in get_tree().get_nodes_in_group("tubig"):
				var heat: HeatStatus = tubig.get_node("HeatStatus")
				heat.lives_left = 1
				heat.ignite()
			_c("tagging out the real players ends the round",
				MatchManager.is_over, true)

			NetworkManager._on_peer_disconnected(3)
			NetworkManager._on_peer_disconnected(2)
			_settle = 2
			_phase = 4
			return

		4:
			_c("every departed body is gone",
				get_tree().get_nodes_in_group("tubig").size(), 0)
			_c("one player cannot start a round",
				NetworkManager.can_start_another_round(), false)
			_c("and is told why",
				NetworkManager.round_blocked_reason().is_empty(), false)

			# The overlay has to agree, and it has to keep up on its own -
			# nobody calls it when a peer drops except the signal.
			var overlay := _find_result_overlay()
			_c("result overlay exists", overlay != null, true)
			if overlay != null:
				overlay._refresh_advance_controls()
				var replay: Button = overlay.get_node_or_null("Column/Buttons/ReplayButton")
				_c("Play Again is disabled with nobody to play",
					replay != null and replay.disabled, true)
				_c("and the screen says something", overlay._hint_label.text.is_empty(), false)
			_finish()
			return


func _find_result_overlay() -> Control:
	for node in _arena.find_children("*", "Control", true, false):
		var control := node as Control
		if control == null or control.get_script() == null:
			continue
		if control.get_script().resource_path.ends_with("match_result.gd"):
			return control
	return null


func _finish() -> void:
	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d TEST(S) FAILED" % _f)
	get_tree().quit(1 if _f > 0 else 0)
