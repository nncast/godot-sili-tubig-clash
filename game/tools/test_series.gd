extends SceneTree

## Headless self-test for the series scoring rules.
##
##   godot --headless --script res://tools/test_series.gd
##
## Runs offline (no multiplayer peer), so SeriesManager's broadcast helpers
## take their local branch and the whole thing stays a pure-logic check.

var _failures := 0


func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("  PASS  %s" % label)
	else:
		_failures += 1
		print("  FAIL  %s  (got %s, expected %s)" % [label, actual, expected])


func _initialize() -> void:
	print("SeriesManager scoring tests")

	var sm = root.get_node("SeriesManager")
	var players := {1: "Janelle", 2: "Stefane", 3: "Romar", 4: "Hazel", 5: "Cristian"}

	sm.begin_series(players)
	_check("rotation covers every player", sm.rounds_total(), 5)
	_check("rotation has no duplicates", sm.rotation.size(), _unique(sm.rotation).size())
	_check("starts on round 1", sm.round_number(), 1)
	_check("series not complete at open", sm.series_complete(), false)

	# --- Round 1: the Sili wipes all four. 4*2 + 3 = 11.
	var sili_a: int = sm.current_sili()
	var tubig_a := _others(players, sili_a)
	var wipe := {}
	for id in tubig_a:
		wipe[id] = "out"
	sm.record_round(sili_a, wipe)
	_check("full wipe pays 11", sm.scores[sili_a]["points"], 11)
	_check("wipe recorded", sm.scores[sili_a]["wipes"], 1)
	_check("eliminations counted", sm.scores[sili_a]["eliminations"], 4)
	_check("wiped Tubig score nothing", sm.scores[tubig_a[0]]["points"], 0)
	_check("advances to round 2", sm.round_number(), 2)

	# --- Round 2: nobody caught, and one Tubig lands two rescues.
	var sili_b: int = sm.current_sili()
	_check("Sili rotates to a new player", sili_b == sili_a, false)
	var tubig_b := _others(players, sili_b)
	var rescuer: int = tubig_b[0]
	sm.credit_rescue(rescuer)
	sm.credit_rescue(rescuer)
	var all_safe := {}
	for id in tubig_b:
		all_safe[id] = "survived"
	var before: int = sm.scores[rescuer]["points"]
	sm.record_round(sili_b, all_safe)
	_check("survive 3 + two rescues 2 = 5", sm.scores[rescuer]["points"] - before, 5)
	_check("rescues tallied", sm.scores[rescuer]["rescues"], 2)
	_check("shut-out Sili scores 0", sm.scores[sili_b]["points"], 0)

	# Rescue credit must not leak into the next round.
	var carried: int = sm.scores[rescuer]["points"]
	var sili_c: int = sm.current_sili()
	var tubig_c := _others(players, sili_c)
	var out_all := {}
	for id in tubig_c:
		out_all[id] = "out"
	sm.record_round(sili_c, out_all)
	if rescuer != sili_c:
		_check("rescue counter cleared between rounds", sm.scores[rescuer]["points"], carried)

	# --- Play out the set.
	while not sm.series_complete():
		var s: int = sm.current_sili()
		var o := {}
		for id in _others(players, s):
			o[id] = "survived"
		sm.record_round(s, o)

	_check("series completes after 5 rounds", sm.series_complete(), true)
	_check("everyone was Sili exactly once", _all_sili_once(sm, players), true)

	var table: Array = sm.standings()
	_check("standings lists every player", table.size(), 5)
	_check("standings sorted high to low",
		table[0]["points"] >= table[table.size() - 1]["points"], true)

	print("")
	if _failures == 0:
		print("ALL TESTS PASSED")
	else:
		print("%d TEST(S) FAILED" % _failures)
	quit(1 if _failures > 0 else 0)


func _unique(arr: Array) -> Array:
	var seen := {}
	for v in arr:
		seen[v] = true
	return seen.keys()


func _others(players: Dictionary, exclude: int) -> Array:
	var out := []
	for id in players:
		if id != exclude:
			out.append(id)
	return out


func _all_sili_once(sm, players: Dictionary) -> bool:
	for id in players:
		if int(sm.scores[id]["sili_rounds"]) != 1:
			return false
	return true
