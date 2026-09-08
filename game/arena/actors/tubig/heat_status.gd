extends Node
class_name HeatStatus

## Tracks a Tubig player's heat state.
## Touching the Sili immediately ignites (Burning) and roots the player in
## place. A "Tubig!" rescue channel (or, later, a cold pack) can free them -
## but only within BURN_TIMEOUT seconds. If nobody gets there in time, the
## burn becomes permanent (Dead): rooted for good, no longer a valid rescue
## target. Attach as a child node of a Tubig CharacterBody2D.

enum State { NORMAL, BURNING, DEAD }

## Seconds a player can stay Burning before it's fatal.
##
## The budget is not all travel time: the rescuer has to stand still for
## RESCUE_CHANNEL_TIME (6s) once they arrive, so the old 15s left barely 9s to
## actually get there. At RUN_SPEED that is ~1620px, against a map whose
## painted ground is ~1376x848 - so a rescue only worked if a teammate happened
## to already be sprinting the right way. 30s leaves ~24s of travel, comfortably
## more than the map's diagonal, which makes the run a decision rather than a
## coin flip. Exported so it stays tunable per-playtest.
@export var BURN_TIMEOUT: float = 30.0
## Hearts are LIVES. One is spent per tag and never comes back - a rescue only
## unfreezes you, it does not refund the heart. Counted HERE rather than on the
## Tubig body because this node's authority is the server (see
## multiplayer_arena.gd's _build_player), while the body's authority is the
## player who controls it. A value the owning client can write is a value the
## owning client can forge, and "how many lives do I have left" decides the
## match - so it lives on the server side of the fence with `state`.
@export var MAX_LIVES: int = 3

## --- Rescue immunity ---
## Seconds after a rescue during which a tag simply does not land.
##
## Without this the Sili can stand on top of a burning player, wait out the
## rescuer's 6-second channel, and re-tag the moment they stand up - which
## spends the rescued player's next heart for six seconds of a teammate's time
## and makes attempting a rescue at all strictly worse than ignoring it. 1.5s
## is deliberately short: it is enough to break contact and start running, not
## enough to walk past the Sili for free.
@export var RESCUE_IMMUNITY_TIME: float = 1.5

## --- Struggling ---
## Mashing the struggle key while Burning buys back time on the burn clock.
##
## The numbers below are a BUDGET, not a rate: every tap adds
## STRUGGLE_BONUS_PER_TAP, and the total a single burn can ever gain is
## STRUGGLE_MAX_BONUS. Once that ceiling is hit, further taps do nothing at
## all - so mashing harder, mashing with a macro, or holding an autofire key
## cannot buy a player one extra second beyond what any other player could
## earn by tapping ten times. That is what keeps this inside the "balanced
## mechanics, no unfair advantage" judging line while still giving a tagged
## player something to do with their hands.
@export var STRUGGLE_BONUS_PER_TAP: float = 0.5
@export var STRUGGLE_MAX_BONUS: float = 5.0
## Taps closer together than this are ignored outright. The cap above already
## bounds the total, so this exists only so the ceiling cannot be reached in a
## single frame by a script - it makes the budget take ~2.5s of real mashing.
@export var STRUGGLE_MIN_INTERVAL: float = 0.25

signal state_changed(new_state: State)
signal burned  # fired the instant a tag lands
signal cooled  # fired when a rescue completes
signal died    # fired when the burn timeout expires unrescued
signal lives_changed(lives_left: int)
signal immunity_changed(is_immune: bool)
signal burn_time_changed(seconds_left: int)
signal struggle_bonus_changed(bonus: float)

var _burn_elapsed: float = 0.0
var _immunity_remaining: float = 0.0
var _last_struggle_at: float = -999.0

## Same property-with-setter reasoning as `state` below: HeatSync assigns this
## directly on remote peers, and routing through the setter keeps
## lives_changed firing on every screen rather than only the server's.
var lives_left: int = MAX_LIVES:
	set(value):
		if value == lives_left:
			return
		lives_left = value
		lives_changed.emit(value)

## Replicated for the same reason `state` is, plus one of its own: the Sili's
## hit detection runs on the Sili's OWN client (see sili.gd's _try_tag), so if
## immunity only existed on the server the Sili would hear the tag sound, see
## the feed line, and then watch the target keep running - feedback for a hit
## that never happened. Publishing the flag lets the Sili's client decline to
## claim the tag in the first place, while the server still enforces it in
## ignite() for any client that ignores the flag.
var is_immune: bool = false:
	set(value):
		if value == is_immune:
			return
		is_immune = value
		immunity_changed.emit(value)

## Whole seconds left before this burn turns permanent, or 0 when not Burning.
##
## Deliberately an int rather than the raw float: the team panel shows it as a
## countdown, so sub-second precision would be replicated many times a second
## to draw a number that only changes once a second. Computed on the server -
## the only machine running the burn clock - and read by every peer's HUD.
var burn_seconds_left: int = 0:
	set(value):
		if value == burn_seconds_left:
			return
		burn_seconds_left = value
		burn_time_changed.emit(value)

## Seconds of burn time this player has bought back by struggling, this burn.
## Replicated so the burning player's own HUD can show how much of the budget
## is left rather than making them guess when the taps stopped counting.
var struggle_bonus: float = 0.0:
	set(value):
		if is_equal_approx(value, struggle_bonus):
			return
		struggle_bonus = value
		struggle_bonus_changed.emit(value)

## A property (not a plain var) on purpose: MultiplayerSynchronizer sets this
## directly via Object.set() on remote peers, bypassing ignite()/cool_fully().
## Routing through this setter means state_changed/burned/cooled/died fire
## consistently everywhere - locally on the server AND on every client
## receiving the replicated value - instead of only on the server's screen.
var state: State = State.NORMAL:
	set(value):
		var previous := state
		state = value
		if value == previous:
			return
		state_changed.emit(value)
		if value == State.BURNING:
			burned.emit()
		elif value == State.NORMAL:
			cooled.emit()
		elif value == State.DEAD:
			died.emit()


func _process(delta: float) -> void:
	# The countdown itself is server-only logic, same rule as ignite()/
	# cool_fully() - everyone else just receives the resulting `state` via
	# replication, they never run this clock themselves.
	if _is_networked() and not is_multiplayer_authority():
		return

	# Immunity runs down regardless of state - it is granted by a rescue, which
	# by definition leaves the player NORMAL, so gating it on BURNING would mean
	# it never ticked at all.
	if _immunity_remaining > 0.0:
		_immunity_remaining = maxf(0.0, _immunity_remaining - delta)
		if _immunity_remaining <= 0.0:
			is_immune = false

	if state != State.BURNING:
		_burn_elapsed = 0.0
		burn_seconds_left = 0
		return

	_burn_elapsed += delta

	# Struggling extends the deadline rather than rewinding the clock, so the
	# amount of help it gave stays readable in one number (struggle_bonus)
	# instead of being smeared into elapsed time.
	var deadline := BURN_TIMEOUT + struggle_bonus
	burn_seconds_left = maxi(0, int(ceil(deadline - _burn_elapsed)))

	if _burn_elapsed >= deadline:
		die()


## Called by the Sili's tag hit. In multiplayer this only takes effect on the
## server; call request_ignite() from client code instead so it gets routed
## there correctly.
## A tag spends a heart. Spending the last one skips the burn window entirely -
## there would be nothing left to save, and a rescue there would put somebody
## back in the match on zero lives.
##
## Both halves happen in the same place on the same machine, so the count and
## the state can never disagree: the old version deducted the heart on the
## tagged player's client in response to the replicated state change, which
## meant two different peers owned two halves of one rule.
func ignite() -> void:
	if state != State.NORMAL:
		return  # already Burning or Dead, a fresh tag does nothing
	if is_immune:
		return  # just rescued - the tag lands on nothing and costs no heart

	lives_left = max(0, lives_left - 1)

	if lives_left <= 0:
		_burn_elapsed = 0.0
		burn_seconds_left = 0
		state = State.DEAD
		return

	_burn_elapsed = 0.0
	# The struggle budget is per BURN, not per match: it resets here so a
	# player on their third heart has the same thing to fight with as they did
	# on their first. Resetting on rescue instead would let a rescued player
	# bank an unspent budget, which is the wrong incentive - it would reward
	# standing still while burning.
	struggle_bonus = 0.0
	_last_struggle_at = -999.0
	state = State.BURNING


## Called on rescue completion. Same server-only rule as ignite(). Rescuing a
## Dead player isn't possible (see is_burning(), which rescue targeting uses),
## so this only ever runs against someone still Burning.
func cool_fully() -> void:
	if state != State.BURNING:
		return
	# Granted BEFORE the state flip so that any listener reacting to `cooled`
	# on this machine already sees is_immune true, rather than reading a window
	# that opens a frame later.
	_immunity_remaining = RESCUE_IMMUNITY_TIME
	is_immune = true
	burn_seconds_left = 0
	state = State.NORMAL


## The burn timed out with nobody saving them - permanent, no more rescues.
func die() -> void:
	if state != State.BURNING:
		return
	state = State.DEAD


func is_burning() -> bool:
	return state == State.BURNING


func is_dead() -> bool:
	return state == State.DEAD


## True for either Burning or Dead - both root the player in place.
func is_incapacitated() -> bool:
	return state == State.BURNING or state == State.DEAD


## --- Network entry points ---
## Any peer may CALL these, but the server decides whether they happen.
##
## Hit detection still runs on the acting player's own client (that's what
## keeps a tag feeling immediate on the machine that made it), so the server
## has to re-check the claim before applying it. Every request below is
## verified for three things:
##
##   1. WHO - the caller's peer id comes from multiplayer.get_remote_sender_id(),
##      never from an argument, so it cannot be forged.
##   2. WHAT ROLE - only the Sili may ignite, only a Tubig may rescue.
##   3. WHERE - the two bodies must actually be close enough on the SERVER's
##      copy of the world, with a tolerance for latency.
##
## Without these checks a modified client could burn any player from anywhere
## on the map, or hand itself free rescues, which is fatal for a competitive
## game. Rejections are warnings rather than errors: a legitimate client can
## fail the distance test occasionally under lag, and that is not cheating.

## Tag hitbox is a 12px radius circle (see sili.tscn). Doubled here so a tag
## the Sili genuinely saw land isn't thrown away because the server's copy of
## the Tubig is a few frames behind.
const TAG_RANGE: float = 26.0
## InteractionArea is a 13px radius circle on each body; same tolerance reasoning.
const RESCUE_RANGE: float = 40.0


@rpc("any_peer", "call_local", "reliable")
func request_ignite() -> void:
	if not _is_networked():
		ignite()
		return
	if not multiplayer.is_server():
		return

	var sender := _sender_id()
	if NetworkManager.roles.get(sender, "") != "sili":
		push_warning("HeatStatus: ignite from peer %d, who is not the Sili - rejected." % sender)
		return
	if not _sender_in_range(sender, TAG_RANGE):
		push_warning("HeatStatus: ignite from peer %d out of tag range - rejected." % sender)
		return

	ignite()


@rpc("any_peer", "call_local", "reliable")
func request_cool_fully() -> void:
	if not _is_networked():
		cool_fully()
		return
	if not multiplayer.is_server():
		return

	var sender := _sender_id()
	if NetworkManager.roles.get(sender, "") != "tubig":
		push_warning("HeatStatus: rescue from peer %d, who is not a Tubig - rejected." % sender)
		return
	if sender == get_parent().get_multiplayer_authority():
		push_warning("HeatStatus: peer %d tried to rescue itself - rejected." % sender)
		return
	# The rescue lock in the final quarter of the match is a rule, not a hint;
	# a client that ignores it locally still gets stopped here.
	if not MatchManager.rescues_available():
		push_warning("HeatStatus: rescue from peer %d while rescues are locked - rejected." % sender)
		return
	# A rescuer who is themselves burning or dead cannot be channelling.
	var rescuer_heat := _heat_of_peer(sender)
	if rescuer_heat != null and rescuer_heat.is_incapacitated():
		push_warning("HeatStatus: incapacitated peer %d tried to rescue - rejected." % sender)
		return
	if not _sender_in_range(sender, RESCUE_RANGE):
		push_warning("HeatStatus: rescue from peer %d out of range - rejected." % sender)
		return

	cool_fully()
	# Credited only after every check above has passed, so the scoreboard
	# counts rescues that actually landed rather than rescues that were
	# claimed. This is the only place a rescue point can be earned.
	SeriesManager.credit_rescue(sender)


## Buys back a little burn time. Verified like every other request here, with
## one extra check the others don't need: WHO OWNS THIS BODY. Struggling is the
## one action a player performs on themselves, so the only legitimate caller is
## the peer that controls this Tubig - anyone else asking is either a bug or a
## client trying to keep a stranger alive.
##
## The three limits, in the order they bite:
##   1. You must be Burning. Nothing to struggle out of otherwise.
##   2. STRUGGLE_MIN_INTERVAL - taps faster than a human are dropped, so an
##      autofire key or a held-down macro converts to the same rate as a
##      person tapping.
##   3. STRUGGLE_MAX_BONUS - the hard ceiling. Once the budget is spent, every
##      further tap is a no-op for the rest of this burn, whoever sent it.
##
## Both (2) and (3) are enforced here, on the server, rather than in the input
## handler - a client can skip its own rate limit, it cannot skip this one.
@rpc("any_peer", "call_local", "reliable")
func request_struggle() -> void:
	if not _is_networked():
		_apply_struggle()
		return
	if not multiplayer.is_server():
		return

	var sender := _sender_id()
	if sender != get_parent().get_multiplayer_authority():
		push_warning("HeatStatus: struggle from peer %d, who does not own this Tubig - rejected." % sender)
		return

	_apply_struggle()


func _apply_struggle() -> void:
	if state != State.BURNING:
		return
	if struggle_bonus >= STRUGGLE_MAX_BONUS:
		return  # budget spent for this burn

	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_struggle_at < STRUGGLE_MIN_INTERVAL:
		return
	_last_struggle_at = now

	struggle_bonus = minf(STRUGGLE_MAX_BONUS, struggle_bonus + STRUGGLE_BONUS_PER_TAP)


## True once this burn's struggle budget is used up. Read by the HUD so the
## prompt can say so instead of silently ignoring taps.
func struggle_exhausted() -> bool:
	return struggle_bonus >= STRUGGLE_MAX_BONUS


## There is deliberately no request_die() RPC any more. Elimination used to be
## something a client asked for when its own heart count hit zero, which meant
## any peer could ask for it against anyone. Now ignite() handles the last
## heart itself, on the server, and the burn timeout in _process() handles the
## rest - so the network surface for "put a player out of the match" is gone
## rather than merely guarded.


## The sender as the multiplayer layer reports it. call_local means the server
## can reach these functions without an actual packet, in which case the
## reported id is 0 and the caller really is the server.
func _sender_id() -> int:
	var id := multiplayer.get_remote_sender_id()
	return 1 if id == 0 else id


func _body_for_peer(peer_id: int) -> Node2D:
	for group in ["sili", "tubig"]:
		for body in get_tree().get_nodes_in_group(group):
			if is_instance_valid(body) and body.get_multiplayer_authority() == peer_id:
				return body
	return null


func _heat_of_peer(peer_id: int) -> HeatStatus:
	var body := _body_for_peer(peer_id)
	if body == null:
		return null
	return body.get_node_or_null("HeatStatus") as HeatStatus


## Distance is measured against the server's own copy of both bodies. If the
## acting player can't be found at all the request is refused rather than
## waved through - an unknown actor is not a trusted one.
func _sender_in_range(peer_id: int, allowed: float) -> bool:
	var actor := _body_for_peer(peer_id)
	var target := get_parent() as Node2D
	if actor == null or target == null:
		return false
	return actor.global_position.distance_to(target.global_position) <= allowed


func _is_networked() -> bool:
	return multiplayer.has_multiplayer_peer() and multiplayer.get_peers().size() > 0
