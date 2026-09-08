extends Node

## Autoload. Career records that survive the session, keyed by player NAME.
##
## SeriesManager already scores a set, but a set ends and its table is thrown
## away. This is the part that persists: it folds each completed series into
## permanent per-player records saved to disk.
##
## WHY IT RANKS ON POINTS PER ROUND, NOT ON POINTS
##
## This is a 1v4 game, and that breaks every obvious ranking.
##
##   - Total points rewards whoever turned up most. Someone with forty rounds
##     outranks a better player with ten, forever.
##   - Wins are not comparable between the two sides. Four Tubigs can all
##     "win" one round; only one Sili ever can. Counting them together says
##     nothing.
##   - Points per ROLE are not comparable either. A perfect Sili round is 11
##     points, a perfect Tubig round is 7, and you are the Sili in one round
##     out of five.
##
## Points per round survives all three. It is unaffected by how many rounds you
## have played, and because SeriesManager rotates the Sili so every player takes
## it exactly once per series, the role mix is identical for everyone who
## finished the same set - so the denominators are already fair, and get fairer
## the more sets a player completes.
##
## The two role-specific rates are reported ALONGSIDE that rather than folded
## into it, because "good hunter, poor runner" is a real and interesting thing
## to be, and a single number would hide it.
##
## WHY ONLY COMPLETED SERIES COUNT
##
## Practice matches never open a series, so they never reach this - which is the
## same rule SeriesManager already applies to its own standings, for the same
## reason. Half a series is not counted either: the Sili rotation is what makes
## the numbers comparable, and you only get the full rotation at the end.
##
## WHY NAMES AND NOT PEER IDS
##
## Peer ids are assigned per connection and mean nothing between sessions. Names
## are what players actually recognise. The trade-off is honest and worth
## stating: anyone can type any name, so this is a scoreboard for a group who
## know each other, not an anti-cheat ranking.

signal changed

const SAVE_PATH := "user://leaderboard.json"

## Rounds before a player is placed on the board.
##
## One full series. Without a floor, somebody who played a single lucky set
## sits at the top forever on a two-round sample, which makes the whole board
## worth ignoring. Unplaced players are still tracked and still shown - just
## listed below the ranked ones with their progress toward placement.
const PLACEMENT_ROUNDS := 5

## How many recent series ids to remember for the duplicate check. series_id
## exists because series_finished re-fires on every state sync while a table is
## complete; without this a set would be banked again on every late join.
const RECENT_SERIES_MEMORY := 32

var _records: Dictionary = {}      # key (lowercased name) -> record Dictionary
var _recent_series: Array = []     # series ids already folded in


func _ready() -> void:
	_load()
	SeriesManager.series_finished.connect(_on_series_finished)


# --- Reading ---------------------------------------------------------------

## Every record, ranked players first. Each row carries the derived numbers
## alongside the raw ones so callers don't each re-implement the maths.
func standings() -> Array:
	var rows: Array = []
	for key in _records:
		var row: Dictionary = _records[key].duplicate()
		row["rating"] = rating(row)
		row["ranked"] = int(row["rounds"]) >= PLACEMENT_ROUNDS
		row["hunt_rate"] = hunt_rate(row)
		row["escape_rate"] = escape_rate(row)
		rows.append(row)

	rows.sort_custom(func(a, b):
		# Unplaced players always sit below placed ones, however good their
		# handful of rounds looks.
		if a["ranked"] != b["ranked"]:
			return a["ranked"]
		if not is_equal_approx(a["rating"], b["rating"]):
			return a["rating"] > b["rating"]
		if a["points"] != b["points"]:
			return a["points"] > b["points"]
		return String(a["name"]).naturalnocasecmp_to(String(b["name"])) < 0)
	return rows


func record_for(display_name: String) -> Dictionary:
	var key := _key(display_name)
	if not _records.has(key):
		return {}
	return _records[key].duplicate()


func is_empty() -> bool:
	return _records.is_empty()


## Points per round. The ranking number.
func rating(record: Dictionary) -> float:
	var rounds := int(record.get("rounds", 0))
	if rounds <= 0:
		return 0.0
	return float(record.get("points", 0)) / float(rounds)


## Share of your Sili rounds that ended with every Tubig out. A wipe IS the
## Sili's win condition, so this is a win rate for that role.
func hunt_rate(record: Dictionary) -> float:
	var rounds := int(record.get("sili_rounds", 0))
	if rounds <= 0:
		return 0.0
	return float(record.get("wipes", 0)) / float(rounds)


## Share of your Tubig rounds you finished still standing.
func escape_rate(record: Dictionary) -> float:
	var rounds := int(record.get("tubig_rounds", 0))
	if rounds <= 0:
		return 0.0
	return float(record.get("survivals", 0)) / float(rounds)


# --- Recording -------------------------------------------------------------

## Fires on EVERY peer, because SeriesManager syncs its table to all of them
## with call_local. That is deliberate: each machine banks the same set from
## the same replicated numbers, so everyone's board agrees without this needing
## a network path of its own.
func _on_series_finished() -> void:
	bank_series(SeriesManager.series_id, SeriesManager.scores,
		SeriesManager.rotation.size(), SeriesManager.standings())


## Split out from the signal so it can be driven directly by a test, and so the
## duplicate check has one obvious home.
func bank_series(series_id: int, scores: Dictionary, rounds_played: int,
		final_standings: Array) -> bool:
	if series_id == 0 or scores.is_empty() or rounds_played <= 0:
		return false
	if _recent_series.has(series_id):
		return false

	_recent_series.append(series_id)
	while _recent_series.size() > RECENT_SERIES_MEMORY:
		_recent_series.pop_front()

	var winner_key := ""
	if not final_standings.is_empty():
		winner_key = _key(String(final_standings[0].get("name", "")))

	for peer_id in scores:
		var entry: Dictionary = scores[peer_id]
		var display_name := String(entry.get("name", "")).strip_edges()
		if display_name.is_empty():
			continue

		var record := _record_for_key(_key(display_name), display_name)
		# Keep the most recent spelling. Someone fixing their capitalisation
		# should not fork their own history.
		record["name"] = display_name

		var sili_rounds := int(entry.get("sili_rounds", 0))
		record["series"] += 1
		record["rounds"] += rounds_played
		record["sili_rounds"] += sili_rounds
		# Everyone plays every round; the ones you were not the Sili in are the
		# ones you spent running.
		record["tubig_rounds"] += maxi(0, rounds_played - sili_rounds)
		record["points"] += int(entry.get("points", 0))
		record["eliminations"] += int(entry.get("eliminations", 0))
		record["rescues"] += int(entry.get("rescues", 0))
		record["survivals"] += int(entry.get("survivals", 0))
		record["wipes"] += int(entry.get("wipes", 0))
		if _key(display_name) == winner_key:
			record["series_won"] += 1

	_save()
	changed.emit()
	return true


## Wipes the board. Offered because this is a shared-device scoreboard for a
## group, and groups change.
func reset() -> void:
	_records.clear()
	_recent_series.clear()
	_save()
	changed.emit()


func _record_for_key(key: String, display_name: String) -> Dictionary:
	if not _records.has(key):
		_records[key] = {
			"name": display_name,
			"series": 0,
			"series_won": 0,
			"rounds": 0,
			"sili_rounds": 0,
			"tubig_rounds": 0,
			"points": 0,
			"eliminations": 0,
			"rescues": 0,
			"survivals": 0,
			"wipes": 0,
		}
	return _records[key]


## Case-insensitive, whitespace-trimmed. "ana", "Ana" and " Ana " are one
## player, because they are.
func _key(display_name: String) -> String:
	return display_name.strip_edges().to_lower()


# --- Persistence -----------------------------------------------------------

func _save() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Leaderboard: could not write '%s' (error %d)." % [
			SAVE_PATH, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify({
		"version": 1,
		"records": _records,
		"recent_series": _recent_series,
	}, "\t"))
	file.close()


## A corrupt or half-written save must not stop the game booting, so every
## failure here ends in an empty board rather than an exception. Losing a
## scoreboard is a nuisance; refusing to start is not survivable.
func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_warning("Leaderboard: could not read '%s'." % SAVE_PATH)
		return
	var raw := file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Leaderboard: '%s' is not valid JSON; starting empty." % SAVE_PATH)
		return

	var records = parsed.get("records", {})
	if typeof(records) != TYPE_DICTIONARY:
		return

	# Rebuilt field by field rather than trusted wholesale. JSON has one number
	# type, so every integer comes back as a float, and a hand-edited file can
	# contain anything at all.
	for key in records:
		var row = records[key]
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var record := _record_for_key(String(key), String(row.get("name", key)))
		record["name"] = String(row.get("name", key))
		for field in ["series", "series_won", "rounds", "sili_rounds",
				"tubig_rounds", "points", "eliminations", "rescues",
				"survivals", "wipes"]:
			record[field] = int(row.get(field, 0))

	var recent = parsed.get("recent_series", [])
	if typeof(recent) == TYPE_ARRAY:
		for id in recent:
			_recent_series.append(int(id))
