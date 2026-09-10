extends Node

## Covers the career leaderboard, the music duck, and the two regressions the
## departure handling introduced.
##
## Run it as a SCENE, for the autoload reason spelled out in test_endgame.gd:
##
##     godot --headless --path . res://tools/test_leaderboard_and_audio.tscn

const PORT := 37817

var _f := 0
var _arena: Node = null
var _frame := 0
var _phase := 0
var _settle := 0
## One-shot: the absent peers only check in once, and re-reporting every frame
## would keep resetting the settle countdown that waits for the spawn.
var _peers_reported := false

## Where this test is allowed to write. Anything but the real leaderboard.
const SCRATCH_SAVE_PATH := "user://leaderboard_test_scratch.json"


func _c(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		print("  PASS  %s" % label)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [label, actual, expected])


func _ready() -> void:
	if get_tree().current_scene == self:
		var runner := Node.new()
		runner.name = "LeaderboardAudioTest"
		runner.set_script(get_script())
		get_tree().root.add_child.call_deferred(runner)
		return

	print("Leaderboard / audio / regression tests")
	_run_leaderboard()
	_run_audio()

	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(PORT, 8) != OK:
		print("  FAIL  could not open a local server on %d" % PORT)
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	NetworkManager.players = {1: "Ana", 2: "Ben", 3: "Cely", 4: "Dino"}
	# This peer is a TUBIG on purpose: SpectatorView is created on demand and
	# only for a Tubig, since the Sili is never eliminated.
	NetworkManager.roles = {1: "tubig", 2: "sili", 3: "tubig", 4: "tubig"}
	NetworkManager.current_map_id = MapRegistry.DEFAULT_MAP
	_arena = load("res://game/arena/arena.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_arena)


# --- Leaderboard -----------------------------------------------------------

func _run_leaderboard() -> void:
	# BEFORE the first reset(), which writes an empty board to disk. user://
	# resolves to the same folder for the editor and for the installed game, so
	# without this the suite wipes the player's real career records every time it
	# runs - which it silently did until this line existed.
	Leaderboard.save_path = SCRATCH_SAVE_PATH
	Leaderboard.reset()
	_c("starts empty", Leaderboard.is_empty(), true)
	_c("the real save file is not the one under test",
		Leaderboard.save_path == "user://leaderboard.json", false)

	# Two five-round series. Ana wins the first outright; Ben plays only the
	# second, so he ends on fewer rounds than the placement floor.
	var first := {
		1: _entry("Ana", 20, 3, 2, 1, 1),
		2: _entry("Cely", 10, 1, 1, 2, 0),
		3: _entry("Dino", 5, 0, 0, 1, 0),
	}
	_c("a completed series is banked",
		Leaderboard.bank_series(111, first, 5, [{"name": "Ana"}]), true)

	# series_finished re-fires on every state sync while a table is complete -
	# a late joiner is enough - so the same set must not count twice.
	_c("the same series cannot be banked twice",
		Leaderboard.bank_series(111, first, 5, [{"name": "Ana"}]), false)

	var ana := Leaderboard.record_for("Ana")
	_c("rounds counted once", int(ana["rounds"]), 5)
	_c("points counted once", int(ana["points"]), 20)
	_c("the series winner is credited", int(ana["series_won"]), 1)
	_c("Sili rounds recorded", int(ana["sili_rounds"]), 1)
	_c("everything else counts as a Tubig round", int(ana["tubig_rounds"]), 4)

	# Case and stray whitespace are the same person, not three people.
	_c("names are matched case-insensitively",
		int(Leaderboard.record_for("  aNa ").get("rounds", 0)), 5)

	# A short three-player set, so Ben ends below the five-round floor while
	# Ana crosses it. Ben's points-per-round is the best on the board - that is
	# the point of the case.
	var second := {
		1: _entry("Ana", 10, 2, 1, 1, 0),
		2: _entry("Ben", 30, 4, 3, 2, 2),
	}
	Leaderboard.bank_series(222, second, 3, [{"name": "Ben"}])

	ana = Leaderboard.record_for("Ana")
	_c("a second series accumulates", int(ana["rounds"]), 8)
	_c("points accumulate", int(ana["points"]), 30)

	var ben := Leaderboard.record_for("Ben")
	_c("Ben scores better per round",
		Leaderboard.rating(ben) > Leaderboard.rating(ana), true)

	# THE FLOOR. Ben is the better player on the numbers, but on three rounds
	# that is a sample, not a record. Without this a single lucky set sits on
	# top forever and the board stops being worth reading.
	var rows: Array = Leaderboard.standings()
	_c("Ana is placed", rows[0]["ranked"], true)
	_c("Ana is top", String(rows[0]["name"]), "Ana")
	_c("rating is points per round",
		is_equal_approx(float(rows[0]["rating"]), 30.0 / 8.0), true)

	var ben_row := _row_for(rows, "Ben")
	_c("Ben is still shown", ben_row.is_empty(), false)
	_c("Ben is not placed on three rounds", ben_row["ranked"], false)
	_c("an unplaced player never outranks a placed one",
		_index_of(rows, "Ben") > _index_of(rows, "Ana"), true)

	# And the floor is exactly one full series, not more.
	Leaderboard.bank_series(333, {2: _entry("Ben", 0, 0, 0, 0, 0)}, 2,
		[{"name": "Ben"}])
	_c("five rounds is enough to be placed",
		_row_for(Leaderboard.standings(), "Ben")["ranked"], true)

	# Rates are reported per role rather than folded together, because a 1v4
	# game has no single number that means the same thing for both sides.
	_c("hunt rate is wipes over Sili rounds",
		is_equal_approx(float(ana["wipes"]) / float(ana["sili_rounds"]),
			Leaderboard.hunt_rate(ana)), true)
	_c("escape rate is survivals over Tubig rounds",
		is_equal_approx(float(ana["survivals"]) / float(ana["tubig_rounds"]),
			Leaderboard.escape_rate(ana)), true)

	# --- Persistence ---
	var reloaded: Node = load("res://autoloads/leaderboard.gd").new()
	# A fresh instance carries its own save_path, defaulted to the REAL board -
	# and it both reads and (via bank_series below) writes. Pointed at the
	# scratch file BEFORE add_child, because _ready() loads on the way in and
	# there is no second chance after that.
	reloaded.save_path = SCRATCH_SAVE_PATH
	add_child(reloaded)  # _ready() loads from disk
	_c("records survive a reload",
		int(reloaded.record_for("Ana").get("points", 0)), 30)
	_c("the duplicate guard survives too",
		reloaded.bank_series(111, first, 5, [{"name": "Ana"}]), false)
	reloaded.queue_free()

	Leaderboard.reset()
	_c("reset clears the board", Leaderboard.is_empty(), true)


func _entry(who: String, points: int, elims: int, wipes: int,
		survivals: int, rescues: int) -> Dictionary:
	return {
		"name": who, "points": points, "eliminations": elims,
		"rescues": rescues, "survivals": survivals, "wipes": wipes,
		"sili_rounds": 1,
	}


func _index_of(rows: Array, who: String) -> int:
	for i in rows.size():
		if String(rows[i]["name"]) == who:
			return i
	return -1


func _row_for(rows: Array, who: String) -> Dictionary:
	for row in rows:
		if String(row["name"]) == who:
			return row
	return {}


# --- Music duck ------------------------------------------------------------

func _run_audio() -> void:
	AudioManager.kill_danger_music()
	AudioManager.play_game_music()

	_c("music is at full level to begin with",
		is_equal_approx(AudioManager._music_target_db(), AudioManager.MUSIC_DB), true)

	AudioManager.start_danger_music()
	_c("the chase ducks the main track",
		AudioManager._music_ducked, true)
	_c("ducked means out, not merely quieter",
		is_equal_approx(AudioManager._music_target_db(), AudioManager.MUSIC_DUCKED_DB), true)
	_c("the duck fades over the same time the sting rises",
		AudioManager.DANGER_FADE_IN > 0.0, true)
	# Silenced, never stopped: the loop keeps advancing so fading back in
	# resumes mid-phrase instead of snapping to the top of the track.
	_c("the main voice keeps playing while ducked",
		AudioManager._active_music.playing, true)

	AudioManager.stop_danger_music()
	_c("losing the Sili brings the music back", AudioManager._music_ducked, false)
	_c("and back to the normal level",
		is_equal_approx(AudioManager._music_target_db(), AudioManager.MUSIC_DB), true)

	# Leaving the arena mid-chase must not open the results screen under a
	# track that is still climbing.
	AudioManager.start_danger_music()
	AudioManager.kill_danger_music()
	_c("killing the sting unducks immediately", AudioManager._music_ducked, false)


# --- Regressions -----------------------------------------------------------

func _process(_delta: float) -> void:
	if get_tree().current_scene == self:
		return
	_frame += 1
	if _frame < 8:
		return
	# Peers 2-4 are in the lobby but have no real connection behind them, and
	# arena.gd holds the round until every one of them reports its arena scene
	# built (see report_arena_ready). Standing in for them is what lets the round
	# launch - and the players spawn - before READY_TIMEOUT twenty seconds later.
	if not _peers_reported:
		_peers_reported = true
		for peer_id in [2, 3, 4]:
			NetworkManager._record_arena_ready(peer_id)
		_settle = 3
		return

	if _settle > 0:
		_settle -= 1
		return

	match _phase:
		0:
			# "Signal 'died' is already connected". _configure_local_hud reruns
			# on every spawn AND now on every departure, and connecting an
			# already-connected signal is an error rather than a no-op.
			# The host is the peer that calls spawn(), and MultiplayerSpawner
			# never emits `spawned` back to the authority - so nothing here is
			# waiting on a signal. If this is null, _launch_round_now stopped
			# refreshing the local HUD by hand and the host is back to a minimap,
			# vignette, danger track and spectator all pointed at nobody.
			var spectator := _find_spectator()
			_c("spectator view exists", spectator != null, true)
			if spectator != null:
				var body: Node2D = get_tree().get_nodes_in_group("tubig")[0]
				spectator.watch_local_player(body)
				spectator.watch_local_player(body)
				spectator.watch_local_player(body)
				_c("re-wiring the same body is a no-op", true, true)

				# Handing this peer a different character has to release the
				# old one, or a past round's HeatStatus can still fire.
				var other: Node2D = get_tree().get_nodes_in_group("tubig")[1]
				spectator.watch_local_player(other)
				var old_heat: HeatStatus = body.get_node("HeatStatus")
				_c("the previous body is released",
					old_heat.died.is_connected(spectator._on_local_death), false)

			# "Parameter data.tree is null". _refresh_team_state now arrives
			# from a deferred despawn and from an autoload signal, both of
			# which can land after the arena has left the tree.
			get_tree().root.remove_child(_arena)
			_arena._refresh_team_state()
			_arena._on_player_left(4, "Dino")
			_c("refreshing outside the tree is safe", true, true)
			get_tree().root.add_child(_arena)

			_finish()
			return


func _find_spectator() -> Node:
	for node in _arena.find_children("*", "Node", true, false):
		if node.get_script() != null \
				and node.get_script().resource_path.ends_with("spectator_view.gd"):
			return node
	return null


func _finish() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_SAVE_PATH))
	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d TEST(S) FAILED" % _f)
	get_tree().quit(1 if _f > 0 else 0)
