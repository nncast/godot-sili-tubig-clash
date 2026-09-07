extends Node
class_name HeatStatus

## Tracks a Tubig player's heat state.
## Touching the Sili immediately ignites (Burning) and roots the player in
## place. A "Tubig!" rescue channel (or, later, a cold pack) can free them -
## but only within BURN_TIMEOUT seconds. If nobody gets there in time, the
## burn becomes permanent (Dead): rooted for good, no longer a valid rescue
## target. Attach as a child node of a Tubig CharacterBody2D.

enum State { NORMAL, BURNING, DEAD }

@export var BURN_TIMEOUT: float = 15.0  # seconds a player can stay Burning before it's fatal
## Hearts are LIVES. One is spent per tag and never comes back - a rescue only
## unfreezes you, it does not refund the heart. Counted HERE rather than on the
## Tubig body because this node's authority is the server (see
## multiplayer_arena.gd's _build_player), while the body's authority is the
## player who controls it. A value the owning client can write is a value the
## owning client can forge, and "how many lives do I have left" decides the
## match - so it lives on the server side of the fence with `state`.
@export var MAX_LIVES: int = 3

signal state_changed(new_state: State)
signal burned  # fired the instant a tag lands
signal cooled  # fired when a rescue completes
signal died    # fired when the burn timeout expires unrescued
signal lives_changed(lives_left: int)

var _burn_elapsed: float = 0.0

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

	if state != State.BURNING:
		_burn_elapsed = 0.0
		return

	_burn_elapsed += delta
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
func ignite() -> void:
	if state != State.NORMAL:
		return  # already Burning or Dead, a fresh tag does nothing

	lives_left = max(0, lives_left - 1)

	if lives_left <= 0:
		_burn_elapsed = 0.0
		state = State.DEAD
		return

	_burn_elapsed = 0.0
	state = State.BURNING


## Called on rescue completion. Same server-only rule as ignite(). Rescuing a
## Dead player isn't possible (see is_burning(), which rescue targeting uses),
## so this only ever runs against someone still Burning.
func cool_fully() -> void:
	if state != State.BURNING:
		return
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
