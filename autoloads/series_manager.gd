extends Node

## Autoload singleton. Turns a pile of one-off matches into a tournament set.
##
## A SERIES is one round per player: with five in the lobby you play five
## rounds, and every player is the Sili in exactly one of them. That is the
## whole reason this exists. Picking the Sili at random - which is what the
## lobby used to do - means one player can be hunted four rounds running while
## another never holds the knife, and no result taken from that is worth
## comparing. Rotation makes every scoreline mean the same thing for everyone.
##
## The server owns all of it. Clients receive the standings through
## _rpc_sync_state and never compute a point themselves.

## --- Scoring -----------------------------------------------------------
## Both roles have to be worth playing well, so both can score, and the
## ceilings are deliberately close: a perfect Sili round is 11, a perfect
## Tubig round is 3 survival + up to 4 rescues. Nobody wins a series on the
## strength of one lucky draw.
const POINTS_PER_ELIMINATION := 2  # Sili, per Tubig who ends the round out
const POINTS_FULL_WIPE := 3        # Sili, for clearing every Tubig
## Tubig ceiling, not a flat award any more - record_round scales this by
## outcomes[peer_id]["fraction"] (arena.gd's HeatStatus.survived_fraction()),
## how much of the match a Tubig was free before their final catch. Getting
## tagged in the first few seconds pays nothing; lasting almost the whole
## match before finally going down pays almost the full ceiling; making it to
## the buzzer without ever being caught pays it in full. A flat "survived or
## didn't" bonus rewarded surviving 179 seconds of a 180-second match exactly
## the same as surviving 3 - which made getting caught early feel like it cost
## nothing further to lose the rest of the match hiding.
const POINTS_SURVIVED := 3
const POINTS_PER_RESCUE := 1       # Tubig, per rescue channel completed

signal standings_changed
signal series_finished
signal round_recorded(summary: Dictionary)

## peer_id -> {
##   "name": String, "points": int, "eliminations": int,
##   "rescues": int, "survivals": int, "wipes": int, "sili_rounds": int }
var scores: Dictionary = {}

## Peer ids in the order they take the Sili role. Fixed when the series opens
## so the running order is knowable in advance, the way a bracket is.
var rotation: Array = []
var round_index: int = 0
var is_active: bool = false

## Identifies THIS series, so a listener can tell one set from the next.
##
## series_finished fires on every peer every time the state syncs while the
## table is complete - a late joiner, a disconnect, anything that reboadcasts -
## not once at the end. The career leaderboard folds a finished series into
## permanent records, so it needs to know it is looking at the same set it
## already banked rather than a new one that happens to look similar.
var series_id: int = 0

## Rescues completed in the CURRENT round only, peer_id -> count. Server-side;
## folded into `scores` when the round is recorded and then cleared.
var _round_rescues: Dictionary = {}


func rounds_total() -> int:
	return rotation.size()


func round_number() -> int:
	return round_index + 1


func is_final_round() -> bool:
	return round_index >= rotation.size() - 1


## Who is the Sili this round. Returns 0 before a series has been opened.
func current_sili() -> int:
	if rotation.is_empty():
		return 0
	return rotation[round_index % rotation.size()]


## Host only. Fixes the running order and zeroes the table. The order itself is
## shuffled - rotation guarantees everyone gets a turn, it does not have to
## guarantee whose turn is first.
func begin_series(players: Dictionary) -> void:
	rotation = players.keys()
	rotation.shuffle()
	round_index = 0
	is_active = true
	# Wall clock in milliseconds plus a random tail. Two series can't share an
	# id unless they opened in the same millisecond AND drew the same tail.
	series_id = int(Time.get_unix_time_from_system() * 1000.0) ^ randi()
	_round_rescues.clear()

	scores.clear()
	for peer_id in rotation:
		scores[peer_id] = {
			"name": players[peer_id],
			"points": 0,
			"eliminations": 0,
			"rescues": 0,
			"survivals": 0,
			"wipes": 0,
			"sili_rounds": 0,
		}
	_broadcast_state()


func end_series() -> void:
	is_active = false
	rotation.clear()
	round_index = 0
	series_id = 0
	scores.clear()
	_round_rescues.clear()
	_broadcast_state()


## Called by HeatStatus on the server the moment a rescue channel actually
## completes and passes validation - so the tally counts rescues that landed,
## not rescues that were attempted or claimed.
func credit_rescue(peer_id: int) -> void:
	if not is_active:
		print("[SCORE-DEBUG] credit_rescue(%d) ignored - series not active" % peer_id)
		return
	_round_rescues[peer_id] = int(_round_rescues.get(peer_id, 0)) + 1
	print("[SCORE-DEBUG] credit_rescue(%d) -> round tally %d" % [peer_id, _round_rescues[peer_id]])


## Host only, called once from the arena when the match ends.
## `outcomes` is peer_id -> {"out": bool, "fraction": float}, covering the
## Tubig only. `fraction` is how much of the match that Tubig was free before
## their final catch (1.0 if never caught) - see arena.gd's
## _record_round_result and HeatStatus.survived_fraction().
func record_round(sili_id: int, outcomes: Dictionary) -> void:
	print("[SCORE-DEBUG] record_round called: is_active=%s sili_id=%d outcomes=%s scores_keys=%s" % [
		is_active, sili_id, outcomes, scores.keys()])
	if not is_active:
		print("[SCORE-DEBUG] record_round REFUSED - series not active")
		return

	var eliminated := 0
	for peer_id in outcomes:
		if outcomes[peer_id]["out"]:
			eliminated += 1

	var wipe: bool = eliminated > 0 and eliminated == outcomes.size()

	var summary := {
		"round": round_number(),
		"sili_id": sili_id,
		"eliminated": eliminated,
		"tubig_total": outcomes.size(),
		"wipe": wipe,
		"awards": {},  # peer_id -> points earned THIS round, for the recap
	}

	# --- Sili ---
	var sili_points := eliminated * POINTS_PER_ELIMINATION
	if wipe:
		sili_points += POINTS_FULL_WIPE
	_award(sili_id, sili_points, summary)
	if scores.has(sili_id):
		scores[sili_id]["eliminations"] += eliminated
		scores[sili_id]["sili_rounds"] += 1
		if wipe:
			scores[sili_id]["wipes"] += 1

	# --- Tubig ---
	for peer_id in outcomes:
		var out: bool = outcomes[peer_id]["out"]
		var fraction: float = clampf(float(outcomes[peer_id].get("fraction", 1.0)), 0.0, 1.0)
		var points := roundi(POINTS_SURVIVED * fraction)
		if not out:
			if scores.has(peer_id):
				scores[peer_id]["survivals"] += 1
		var rescues := int(_round_rescues.get(peer_id, 0))
		if rescues > 0:
			points += rescues * POINTS_PER_RESCUE
			if scores.has(peer_id):
				scores[peer_id]["rescues"] += rescues
		_award(peer_id, points, summary)

	_round_rescues.clear()
	round_index += 1

	print("[SCORE-DEBUG] record_round finished: awards=%s scores_after=%s" % [
		summary["awards"], scores])

	_broadcast_round(summary)
	_broadcast_state()


func _award(peer_id: int, points: int, summary: Dictionary) -> void:
	if not scores.has(peer_id):
		print("[SCORE-DEBUG] _award(%d, %d) DROPPED - no such peer in scores (have %s)" % [
			peer_id, points, scores.keys()])
		return
	scores[peer_id]["points"] += points
	summary["awards"][peer_id] = points


## Highest points first. Ties break on eliminations, then survivals, then name,
## so the board has a stable order instead of reshuffling every refresh.
func standings() -> Array:
	var rows: Array = []
	for peer_id in scores:
		var row: Dictionary = scores[peer_id].duplicate()
		row["peer_id"] = peer_id
		rows.append(row)
	rows.sort_custom(func(a, b):
		if a["points"] != b["points"]:
			return a["points"] > b["points"]
		if a["eliminations"] != b["eliminations"]:
			return a["eliminations"] > b["eliminations"]
		if a["survivals"] != b["survivals"]:
			return a["survivals"] > b["survivals"]
		return String(a["name"]) < String(b["name"]))
	return rows


func series_complete() -> bool:
	return is_active and round_index >= rotation.size()


# --- Replication -------------------------------------------------------

func _broadcast_state() -> void:
	if _is_networked():
		_rpc_sync_state.rpc(scores, rotation, round_index, is_active, series_id)
	else:
		_rpc_sync_state(scores, rotation, round_index, is_active, series_id)


func _broadcast_round(summary: Dictionary) -> void:
	if _is_networked():
		_rpc_round_recorded.rpc(summary)
	else:
		_rpc_round_recorded(summary)


@rpc("authority", "call_local", "reliable")
func _rpc_sync_state(new_scores: Dictionary, new_rotation: Array,
		new_round_index: int, active: bool, new_series_id: int) -> void:
	scores = new_scores
	rotation = new_rotation
	round_index = new_round_index
	is_active = active
	series_id = new_series_id
	print("[SCORE-DEBUG] _rpc_sync_state received on peer %d: round=%d active=%s scores=%s" % [
		_local_peer_id_for_debug(), round_index, is_active, scores])
	standings_changed.emit()
	if series_complete():
		print("[SCORE-DEBUG] series_complete on peer %d -> emitting series_finished" % [
			_local_peer_id_for_debug()])
		series_finished.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_round_recorded(summary: Dictionary) -> void:
	round_recorded.emit(summary)


## The null check is not paranoia: an autoload reached before it is inside a
## SceneTree - which is what happens under `godot --script`, and can happen
## during early shutdown - has no multiplayer API at all. Scoring is pure
## logic and should not fall over because of where it was called from.
func _is_networked() -> bool:
	return multiplayer != null and multiplayer.has_multiplayer_peer()


## Same null-safety as _is_networked(), for the [SCORE-DEBUG] prints only.
func _local_peer_id_for_debug() -> int:
	if _is_networked():
		return multiplayer.get_unique_id()
	return 1
