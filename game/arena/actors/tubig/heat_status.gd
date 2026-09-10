extends Node
class_name HeatStatus

## Tracks a Tubig player's heat state.
## Touching the Sili immediately ignites (Burning) and roots the player in
## place. A "Tubig!" rescue channel (or, later, a cold pack) can free them -
## but only within BURN_TIMEOUT seconds. If nobody gets there in time, the
## burn becomes permanent (Dead): rooted for good, no longer a valid rescue
## target. Attach as a child node of a Tubig CharacterBody2D.

enum State { NORMAL, BURNING, DEAD }

@export var BURN_TIMEOUT: float = 30.0  # seconds a player can stay Burning before it's fatal
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
## rescuer's channel, and re-tag the moment they stand up - a burning player is
## rooted to the exact spot they were tagged, so the Sili is very often still
## standing right there. That turned "rescued" and "tagged again" into the same
## frame, over and over: the same heart lost repeatedly for one rescue attempt.
## 1.5s is deliberately short: enough to break contact and start running, not
## enough to walk past the Sili for free.
@export var RESCUE_IMMUNITY_TIME: float = 1.5

signal state_changed(new_state: State)
signal burned  # fired the instant a tag lands
signal cooled  # fired when a rescue completes
signal died    # fired when the burn timeout expires unrescued
signal lives_changed(lives_left: int)
signal immunity_changed(is_immune: bool)
signal burn_time_changed(seconds_left: int)

var _burn_elapsed: float = 0.0
var _immunity_remaining: float = 0.0

## Elapsed match time (seconds since the round's clock started) the last time
## this Tubig left NORMAL - tagged into Burning, or straight into Dead on a
## last heart. Scoring reads this for anyone who ends the round caught, so
## someone who lasted well into the match before finally going down scores
## more than someone caught in the first few seconds, instead of both flatly
## getting nothing. -1 until it happens once (never tagged this round).
var elapsed_at_last_tag: float = -1.0

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

## Whole seconds left on the burn, or 0 when not burning.
##
## Replicated (see tubig.tscn's HeatSync) because teammates have to be able to
## decide whether the run across the map is worth making. A red dot says
## somebody is down; it does not say whether there are twelve seconds to reach
## them or two, which is the only thing that determines the answer.
##
## Deliberately an INT and replicated on-change rather than always: the float
## underneath ticks every frame, and pushing that would put a needless packet
## per player per network tick on a Wi-Fi link that is already the weak point
## (see the interval throttling on the same scene). Rounded to seconds, the
## value changes thirty times per burn and no more.
##
## Same property-with-setter reasoning as `state` and `lives_left`: the
## synchronizer assigns it directly on remote peers, so routing through a setter
## is what makes burn_time_changed fire on every screen rather than only the
## server's.
var burn_seconds_left: int = 0:
	set(value):
		if value == burn_seconds_left:
			return
		burn_seconds_left = value
		burn_time_changed.emit(value)

## Same property-with-setter reasoning as `state` below: HeatSync assigns this
## directly on remote peers, and routing through the setter keeps
## lives_changed firing on every screen rather than only the server's.
var lives_left: int = MAX_LIVES:
	set(value):
		if value == lives_left:
			return
		lives_left = value
		lives_changed.emit(value)

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
		# Only a fresh catch (leaving NORMAL) counts as "the last tag" - the
		# later Burning -> Dead timeout is the same catch running out the
		# clock, not a new one, so it must not overwrite the moment scoring
		# actually cares about.
		if previous == State.NORMAL and value != State.NORMAL:
			elapsed_at_last_tag = MatchManager.MATCH_DURATION - MatchManager.time_remaining
		state_changed.emit(value)
		if value == State.BURNING:
			burned.emit()
		elif value == State.NORMAL:
			cooled.emit()
		elif value == State.DEAD:
			died.emit()


## How much of the match this Tubig was free before being finally caught, as a
## 0..1 fraction - what scoring scales survival points by. 1.0 (full credit)
## if this round never actually caught them, which covers both "never tagged"
## and the caller not bothering to check is_incapacitated() first.
func survived_fraction() -> float:
	if elapsed_at_last_tag < 0.0 or MatchManager.MATCH_DURATION <= 0.0:
		return 1.0
	return clampf(elapsed_at_last_tag / MatchManager.MATCH_DURATION, 0.0, 1.0)


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
	# ceil, so the display reads "15" the instant the tag lands and only shows
	# "0" when the time really is gone - a floor would skip 15 entirely and
	# sit on 0 for a full second while the player was still savable.
	burn_seconds_left = maxi(0, int(ceil(BURN_TIMEOUT - _burn_elapsed)))
	if _burn_elapsed >= BURN_TIMEOUT:
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
## Returns whether the tag actually landed. Callers use that to decide whether
## anything should be ANNOUNCED - see request_ignite(). A tag that hits someone
## already burning, already dead, or still inside their rescue immunity is a
## real miss, and the feed must not claim otherwise.
func ignite() -> bool:
	if state != State.NORMAL:
		return false  # already Burning or Dead, a fresh tag does nothing
	if is_immune:
		return false  # just rescued - the tag lands on nothing and costs no heart

	lives_left = max(0, lives_left - 1)

	if lives_left <= 0:
		_burn_elapsed = 0.0
		state = State.DEAD
		return true

	_burn_elapsed = 0.0
	state = State.BURNING
	return true


## Called on rescue completion. Same server-only rule as ignite(). Rescuing a
## Dead player isn't possible (see is_burning(), which rescue targeting uses),
## so this only ever runs against someone still Burning.
## Returns whether the rescue actually freed anybody, for the same reason
## ignite() does: two Tubig finishing a channel on the same target a frame apart
## is normal under lag, and only the first of them rescued anyone.
func cool_fully() -> bool:
	if state != State.BURNING:
		return false
	# Granted BEFORE the state flip so that any listener reacting to `cooled`
	# on this machine already sees is_immune true, rather than reading a window
	# that opens a frame later.
	_immunity_remaining = RESCUE_IMMUNITY_TIME
	is_immune = true
	state = State.NORMAL
	return true


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
		if ignite():
			_announce_tag(_local_peer_id())
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

	if ignite():
		_announce_tag(sender)


@rpc("any_peer", "call_local", "reliable")
func request_cool_fully() -> void:
	if not _is_networked():
		if cool_fully():
			_announce_rescue(_local_peer_id())
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

	# Credited only after every check above has passed AND only if the channel
	# actually freed somebody, so the scoreboard counts rescues that landed
	# rather than rescues that were claimed. This is the only place a rescue
	# point can be earned. Two rescuers finishing on the same target a frame
	# apart used to score twice for one save.
	if cool_fully():
		_announce_rescue(sender)
		SeriesManager.credit_rescue(sender)


## There is deliberately no request_die() RPC any more. Elimination used to be
## something a client asked for when its own heart count hit zero, which meant
## any peer could ask for it against anyone. Now ignite() handles the last
## heart itself, on the server, and the burn timeout in _process() handles the
## rest - so the network surface for "put a player out of the match" is gone
## rather than merely guarded.


## --- Feed lines -----------------------------------------------------------
##
## Both live here, on the server, next to the validation - NOT on the acting
## player's client where they used to be.
##
## The old placement (sili.gd's _try_tag, tubig.gd's _complete_rescue) wrote the
## line the instant the local client THOUGHT it had connected, one frame before
## the request even left the machine. On a good connection the server agreed and
## nobody noticed. On a hotspot it produced exactly the reported bug: the Sili's
## screen shows a tag, the Tubig's screen shows them getting away, the server
## sides with the Tubig - and the feed still announced a tag that never
## happened. Once per second per target, for as long as the chase lasts, which
## is what buried the feed.
##
## Announcing from here means a line is written once, by the one machine that
## decides the outcome, and only when the outcome actually changed. A rejected
## claim now costs a push_warning and nothing else.
func _announce_tag(tagger_id: int) -> void:
	MatchManager.broadcast_event("%s tagged %s" % [
		MatchManager.sili_name(_peer_name(tagger_id, "Sili")),
		MatchManager.tubig_name(_victim_name()),
	], "tag")


## Both names are Tubig here - a rescue is one runner reaching another, so the
## line is blue on both ends and only the verb changes colour with the kind.
func _announce_rescue(rescuer_id: int) -> void:
	MatchManager.broadcast_event("%s rescued %s" % [
		MatchManager.tubig_name(_peer_name(rescuer_id, "Tubig")),
		MatchManager.tubig_name(_victim_name()),
	], "rescue")


func _peer_name(peer_id: int, fallback: String) -> String:
	return NetworkManager.players.get(peer_id, fallback)


## This node hangs off the Tubig it belongs to, so the owner of the body is the
## player every line here is about.
func _victim_name() -> String:
	var body := get_parent()
	if body == null:
		return "Tubig"
	return _peer_name(body.get_multiplayer_authority(), "Tubig")


## Offline (the tools/ harnesses, and a single-machine practice run) has no
## sender to read - the only player there is this one.
func _local_peer_id() -> int:
	return multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1


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
