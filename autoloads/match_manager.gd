extends Node

## Autoload singleton. Tracks the 2-minute match timer and the
## rescue-lock phase (rescues disabled in the final 25% of the match).
## In multiplayer, only the server (peer id 1) runs the countdown; it
## pushes updates out to everyone else via RPC. In single-player/local
## testing (no multiplayer peer set up) it just runs locally.

## Raised from 120s after looking at the speed curve. Both roles share the same
## base speed (100 walk / 180 run), so until the Sili's multiplier is high
## enough it cannot close on a Tubig who keeps running - the ramp is what makes
## the match end, not the Sili's skill. The crossover where the Sili out-walks a
## Tubig's walk arrives at 1.26x, which under the old 120s clock landed at the
## 60s mark: half the match was spent unable to convert. 180s gives roughly
## twice the effective hunting window without changing the top speed.
@export var MATCH_DURATION: float = 180.0
@export var RESCUE_LOCK_FRACTION: float = 0.75  # rescues disabled after this fraction of time elapses
@export var SYNC_INTERVAL: float = 0.25  # how often the server broadcasts the timer, in seconds
@export var PREGAME_DURATION: float = 5.0  # role reveal + countdown before the clock starts

signal time_updated(time_remaining: float, match_duration: float)
signal rescues_locked
signal match_started
signal match_ended(sili_won: bool)
signal pregame_started(duration: float)
signal pregame_tick(seconds_left: int)
signal pregame_finished
signal sili_speed_changed(multiplier: float, stage: int)
## Match feed lines. Routed through here rather than emitted by the players so
## every peer sees the same events: a tag is detected on the Sili's client and a
## rescue on the rescuer's, but both have to show up on everyone's screen.
signal event_logged(message: String, kind: String)

var time_remaining: float = 0.0
var is_running: bool = false
## True from the final whistle until the next round loads. Kept separate from
## is_running because "the match stopped" and "the match is over" want different
## answers: plenty of code checks is_running to decide whether to tick, but only
## this one should keep hands off the controls while the result is on screen.
var is_over: bool = false
var is_pregame: bool = false
var are_rescues_locked: bool = false
var _sync_accumulator: float = 0.0
var _pregame_remaining: float = 0.0
var _sili_speed_stage: int = 0


## The Sili gets faster as the clock runs down, so a Tubig who found a good
## corner early can't simply sit there for two minutes. Each entry is
## [seconds elapsed, speed multiplier]; they're checked in order and the last
## one whose threshold has passed wins.
##
## Derived from time_remaining rather than broadcast separately: that value is
## already synced to every peer, so all clients arrive at the same multiplier
## on the same tick without another RPC to keep in step.
## Retuned upward once the tunnel went in: a Tubig who reaches a mouth crosses
## the map for free and resets a chase completely, so the Sili needs a harder
## late game to keep the pressure curve. Starts sooner and tops out higher than
## before (was 1.35x at 100s, in a 120s match).
const SILI_SPEED_STAGES: Array = [
	[0.0, 1.0],
	[30.0, 1.12],
	[65.0, 1.26],
	[100.0, 1.42],
	[135.0, 1.60],
]


## A fountain SLOW roll trims the Sili's speed for a few seconds (see
## fountain.gd). It lives here rather than on the Sili's own script because
## every peer reads this function each frame to draw the Sili at the right
## speed, and they all have to arrive at the same number - so the trim has to
## sit on the same synced clock the stage ramp already rides on.
var _slow_factor: float = 1.0
var _slow_remaining: float = 0.0


func sili_speed_multiplier() -> float:
	return float(SILI_SPEED_STAGES[_sili_speed_stage][1]) * _slow_factor


## Called on EVERY peer from Fountain._rpc_apply_buff, which is already an
## RPC - so this deliberately does not broadcast again. A second slow landing
## while one is running refreshes the timer rather than stacking the factor,
## which keeps the worst case bounded no matter how the rolls fall.
func apply_sili_slow(factor: float, duration: float) -> void:
	_slow_factor = clampf(factor, 0.1, 1.0)
	_slow_remaining = maxf(_slow_remaining, duration)


func _tick_sili_slow(delta: float) -> void:
	if _slow_remaining <= 0.0:
		return
	_slow_remaining = maxf(0.0, _slow_remaining - delta)
	if _slow_remaining == 0.0:
		_slow_factor = 1.0


## --- Feed names -----------------------------------------------------------
##
## Feed lines name the player rather than the role ("Ana tagged Ben"), which
## only helps if you can tell at a glance which side each name is on - with the
## Sili rotating every round, "Ana" alone doesn't say whether Ana is the one
## doing the catching this time. So each name carries its own side's colour and
## the words between them stay in the line's kind colour, which is the half that
## already says whether this was a tag or a rescue.
##
## Stored without the leading "#" so callers can build "[color=#%s]" directly.
const FEED_SILI_COLOR := "ff8a72"
const FEED_TUBIG_COLOR := "6fd8ff"


## Names are typed by players and the feed renders BBCode, so a player calling
## themselves "[color=red]" would be writing markup straight into everybody
## else's HUD. "[lb]" is the engine's own escape for a left bracket, so an
## escaped name still shows the bracket on screen rather than swallowing it.
##
## Only "[" needs escaping - a "]" with nothing open in front of it is already
## inert - and this must run BEFORE any colour tag is wrapped around the name,
## or it would escape the tag the game itself just added.
func escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")


func sili_name(player_name: String) -> String:
	return "[color=#%s]%s[/color]" % [FEED_SILI_COLOR, escape_bbcode(player_name)]


func tubig_name(player_name: String) -> String:
	return "[color=#%s]%s[/color]" % [FEED_TUBIG_COLOR, escape_bbcode(player_name)]


## For the places that log about a player without already knowing which helper
## to reach for - somebody leaving, say, where the only thing to hand is the
## role table. Anything that isn't the Sili is a Tubig, which is four of the five.
func name_for_role(role: String, player_name: String) -> String:
	return sili_name(player_name) if role == "sili" else tubig_name(player_name)


## Any peer may report an event; it's a cosmetic feed, so there's nothing worth
## validating on the server and no reason to make clients round-trip for it.
@rpc("any_peer", "call_local", "reliable")
func _rpc_log_event(message: String, kind: String) -> void:
	event_logged.emit(message, kind)


func broadcast_event(message: String, kind: String = "info") -> void:
	if _is_networked():
		_rpc_log_event.rpc(message, kind)
	else:
		_rpc_log_event(message, kind)


func _update_sili_speed_stage() -> void:
	var elapsed := MATCH_DURATION - time_remaining
	var stage := 0
	for i in SILI_SPEED_STAGES.size():
		if elapsed >= float(SILI_SPEED_STAGES[i][0]):
			stage = i
	if stage == _sili_speed_stage:
		return
	_sili_speed_stage = stage
	sili_speed_changed.emit(sili_speed_multiplier(), stage)


func _is_networked() -> bool:
	return multiplayer.has_multiplayer_peer()


func _is_authority() -> bool:
	return not _is_networked() or multiplayer.is_server()


## Kicks off the pre-match reveal first; the real clock only starts once that
## countdown expires (see _tick_pregame -> _begin_running). Set PREGAME_DURATION
## to 0 to skip straight to gameplay.
func start_match() -> void:
	if not _is_authority():
		return

	if PREGAME_DURATION <= 0.0:
		_begin_running()
		return

	if _is_networked():
		_rpc_start_pregame.rpc(PREGAME_DURATION)
	else:
		_rpc_start_pregame(PREGAME_DURATION)


## True while the reveal is on screen, and again once the match is decided. Both
## player scripts check this, so covering the end state here is all it takes to
## stop everyone where they stand under the result overlay - no separate freeze
## logic in the movement code.
func inputs_locked() -> bool:
	return is_pregame or is_over


func _process(delta: float) -> void:
	if is_pregame:
		_tick_pregame(delta)
		return

	if not is_running:
		return

	# Before the authority gate on purpose: clients never run the countdown
	# themselves, but they do receive time_remaining, so they can work out the
	# current speed stage locally instead of waiting on another broadcast. The
	# fountain slow is ticked here for the same reason - it was handed to every
	# peer at once, so every peer has to count it down.
	_update_sili_speed_stage()
	_tick_sili_slow(delta)

	if not _is_authority():
		return

	time_remaining = max(0.0, time_remaining - delta)

	if _is_networked():
		_sync_accumulator += delta
		if _sync_accumulator >= SYNC_INTERVAL:
			_sync_accumulator = 0.0
			_rpc_time_update.rpc(time_remaining)
	else:
		time_updated.emit(time_remaining, MATCH_DURATION)

	if not are_rescues_locked and time_remaining <= MATCH_DURATION * (1.0 - RESCUE_LOCK_FRACTION):
		are_rescues_locked = true
		if _is_networked():
			_rpc_rescues_locked.rpc()
		else:
			rescues_locked.emit()

	if time_remaining <= 0.0:
		end_match(false)  # Tubig survives to the buzzer


func end_match(sili_won: bool) -> void:
	if not is_running or not _is_authority():
		return
	is_running = false

	is_over = true

	if _is_networked():
		_rpc_match_ended.rpc(sili_won)
	else:
		match_ended.emit(sili_won)


func rescues_available() -> bool:
	return is_running and not are_rescues_locked


## Every peer counts its own reveal down so the on-screen number is smooth
## without a stream of sync packets - but only the server's copy is allowed to
## decide the countdown is over and start the match, so a client with a slow
## clock can never jump the gun.
func _tick_pregame(delta: float) -> void:
	var previous_second := int(ceil(_pregame_remaining))
	_pregame_remaining = max(0.0, _pregame_remaining - delta)
	var current_second := int(ceil(_pregame_remaining))

	if current_second != previous_second:
		pregame_tick.emit(current_second)

	if _pregame_remaining <= 0.0 and _is_authority():
		_begin_running()


func _begin_running() -> void:
	if _is_networked():
		_rpc_start_match.rpc(MATCH_DURATION)
	else:
		_rpc_start_match(MATCH_DURATION)


# --- Network broadcast handlers (run on every peer, including the server via call_local) ---

@rpc("authority", "call_local", "reliable")
func _rpc_start_pregame(duration: float) -> void:
	is_pregame = true
	is_running = false
	is_over = false
	are_rescues_locked = false
	_sili_speed_stage = 0
	_slow_factor = 1.0
	_slow_remaining = 0.0
	_pregame_remaining = duration
	time_remaining = MATCH_DURATION
	pregame_started.emit(duration)
	pregame_tick.emit(int(ceil(duration)))
	time_updated.emit(time_remaining, MATCH_DURATION)


@rpc("authority", "call_local", "reliable")
func _rpc_start_match(duration: float) -> void:
	var was_pregame := is_pregame
	is_pregame = false
	_pregame_remaining = 0.0
	is_running = true
	is_over = false
	are_rescues_locked = false
	_sili_speed_stage = 0
	_slow_factor = 1.0
	_slow_remaining = 0.0
	time_remaining = duration
	if was_pregame:
		pregame_finished.emit()
	match_started.emit()
	time_updated.emit(time_remaining, duration)


@rpc("authority", "call_local", "unreliable")
func _rpc_time_update(remaining: float) -> void:
	time_remaining = remaining
	time_updated.emit(time_remaining, MATCH_DURATION)


@rpc("authority", "call_local", "reliable")
func _rpc_rescues_locked() -> void:
	are_rescues_locked = true
	rescues_locked.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_match_ended(sili_won: bool) -> void:
	is_running = false
	is_over = true
	match_ended.emit(sili_won)
