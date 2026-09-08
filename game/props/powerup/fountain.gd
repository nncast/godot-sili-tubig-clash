extends Node2D
class_name Fountain

## A Tubig-only relief valve, tied to the Sili's speed ramp.
##
## The fountain is empty at the start of a round and refills every time
## MatchManager crosses a SILI_SPEED_STAGES threshold - so a drink becomes
## available at exactly the moment the chase got harder, and never before. That
## pairing is the whole point: the Sili's advantage grows on a fixed schedule
## (see match_manager.gd) and this is the only thing on the map that answers it.
## Four stages fire above stage 0, so a round offers four drinks total, shared
## across the entire Tubig team on a first-come basis.
##
## TUBIG ONLY, by the same construction as the tunnel: the mouth pushes itself
## onto whatever body walks in via set_nearby_fountain(), Tubig implements that
## method and Sili does not. The Sili is never told the fountain exists rather
## than being told "no" - one rule, one place, no `if sili` checks scattered
## through the movement code.
##
## AUTHORITY. Everything that decides an outcome runs on the server:
##
##   - `is_charged` is server state, pushed out by _rpc_set_charged.
##   - The buff roll happens ONCE, on the server, in _roll_buff(). It is not
##     rolled per-peer from a shared seed - that would mean five machines each
##     trusting their own RNG to stay in step for a whole match, and one dropped
##     packet desyncs the outcome permanently.
##   - Range, role and match state are re-checked server-side in
##     request_drink(), the same three-part validation HeatStatus uses for tags
##     and rescues. The sender id comes from get_remote_sender_id(), never from
##     an argument, so it cannot be forged.

enum Buff {
	TUNNEL,   ## extra escape trips
	SLOW,     ## the Sili loses speed for a while
	STAMINA,  ## cheaper sprinting for a while
}

## Interaction radius, and where it sits. The fountain art is painted at cells
## (5..6, 1..3) of a 16px tileset, so its middle is well away from this node's
## origin - centring the area on Vector2.ZERO would put the trigger in empty
## sand a couple of tiles up and to the left of the thing you can see.
const AREA_CENTER := Vector2(96, 40)
const AREA_RADIUS := 34.0

## Server-side range check, generous against the client's own overlap test for
## the same latency reason as HeatStatus.TAG_RANGE.
const DRINK_RANGE := 70.0

## Weights, not a flat 1-in-3. Tunnel charges are the safest pick and the
## easiest to understand at a glance, so they come up most; the Sili slow is
## the strongest single effect in the game and stays the rarest.
const BUFF_TABLE: Array = [
	[Buff.TUNNEL, 45],
	[Buff.STAMINA, 35],
	[Buff.SLOW, 20],
]

## How many extra trips a TUNNEL roll grants. Weighted the same way - +3 is the
## jackpot, not the average.
const TUNNEL_GRANT_TABLE: Array = [
	[1, 50],
	[2, 33],
	[3, 17],
]

const SLOW_FACTOR := 0.75      ## Sili keeps 75% of its current speed
const SLOW_DURATION := 8.0
const STAMINA_DURATION := 10.0

## Editor + in-game tint for the basin, so "ready" is readable in-world and not
## only in the feed. A player looking at the fountain should be able to tell.
##
## SPENT IS NOT A TINT. It used to be a 0.55 grey multiply, which is a heavy
## darkening - and since the fountain starts every round uncharged and only
## fills on the first speed stage at 30s, the first half-minute of every match
## showed a fountain that looked like unlit or broken art rather than like a
## prop that was merely empty. Spent is now the sprite exactly as drawn, and
## READY is a brightening on top of it, so the state that needs to catch your
## eye is the one that stands out instead of the resting state being punished.
const READY_TINT := Color(0.80, 1.25, 1.45)
const SPENT_TINT := Color(1.0, 1.0, 1.0)

signal charged_changed(is_charged: bool)

var is_charged: bool = false:
	set(value):
		if value == is_charged:
			return
		is_charged = value
		charged_changed.emit(value)
		_apply_tint()

var _area: Area2D = null


func _ready() -> void:
	add_to_group("fountain")
	_build_interaction_area()
	_apply_tint()

	# Every peer connects, but only the server acts on it - see _on_speed_changed.
	# Clients still need the signal for nothing at all, so the guard lives in the
	# handler rather than here, keeping the connection unconditional and the
	# authority rule in one readable place.
	MatchManager.sili_speed_changed.connect(_on_speed_changed)
	MatchManager.match_started.connect(_on_match_started)


## Built in code rather than in the .tscn so the radius and the offset above
## stay next to the comment explaining them, instead of being two numbers in a
## scene file that nobody can trace back to the tileset coordinates.
func _build_interaction_area() -> void:
	_area = Area2D.new()
	_area.name = "InteractionArea"
	_area.position = AREA_CENTER
	_area.monitoring = true
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = AREA_RADIUS
	shape.shape = circle
	_area.add_child(shape)
	add_child(_area)

	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)


func _on_body_entered(body: Node2D) -> void:
	if body.has_method("set_nearby_fountain"):
		body.set_nearby_fountain(self)


func _on_body_exited(body: Node2D) -> void:
	if body.has_method("clear_nearby_fountain"):
		body.clear_nearby_fountain(self)


## Rounds are replayed into the same scene tree, so a fountain left charged (or
## left spent) by the previous round would carry over into the next one.
func _on_match_started() -> void:
	if not _is_authority():
		return
	_set_charged_everywhere(false)


## Stage 0 is the match's opening speed - nothing has increased yet, so there is
## nothing to compensate for and no announcement to make.
func _on_speed_changed(_multiplier: float, stage: int) -> void:
	if stage <= 0 or not _is_authority():
		return
	if is_charged:
		return  # still holding an undrunk charge; a stage tick doesn't stack them
	_set_charged_everywhere(true)
	MatchManager.broadcast_event("The fountain has refilled  [E]", "buff")


func _set_charged_everywhere(value: bool) -> void:
	if _is_networked():
		_rpc_set_charged.rpc(value)
	else:
		_rpc_set_charged(value)


@rpc("authority", "call_local", "reliable")
func _rpc_set_charged(value: bool) -> void:
	is_charged = value


## Any peer may ask; the server decides. Called by tubig.gd when E is pressed
## with nothing more urgent in reach.
@rpc("any_peer", "call_local", "reliable")
func request_drink() -> void:
	if not _is_networked():
		if is_charged:
			_grant(_local_peer_id(), _roll_buff())
		return
	if not multiplayer.is_server():
		return

	var sender := _sender_id()
	if not is_charged:
		return  # not an error: two players can tap E on the same frame
	if NetworkManager.roles.get(sender, "") != "tubig":
		push_warning("Fountain: drink from peer %d, who is not a Tubig - rejected." % sender)
		return
	if not MatchManager.is_running:
		return
	var body := _body_for_peer(sender)
	if body == null:
		push_warning("Fountain: drink from peer %d with no body on the server - rejected." % sender)
		return
	# A rooted player cannot walk to a fountain, so they cannot drink from one.
	var heat: HeatStatus = body.get_node_or_null("HeatStatus")
	if heat != null and heat.is_incapacitated():
		return
	if body.global_position.distance_to(_area.global_position) > DRINK_RANGE:
		push_warning("Fountain: drink from peer %d out of range - rejected." % sender)
		return

	_set_charged_everywhere(false)
	_grant(sender, _roll_buff())


## The roll, and only the roll, happens here - on the server, once. The result
## travels as data so every screen shows the same buff and the same feed line.
func _roll_buff() -> Array:
	var kind: int = int(_weighted_pick(BUFF_TABLE))
	var amount: int = 0
	if kind == Buff.TUNNEL:
		amount = int(_weighted_pick(TUNNEL_GRANT_TABLE))
	return [kind, amount]


func _weighted_pick(table: Array):
	var total := 0
	for entry in table:
		total += int(entry[1])
	var roll := randi() % maxi(1, total)
	for entry in table:
		roll -= int(entry[1])
		if roll < 0:
			return entry[0]
	return table[0][0]


func _grant(peer_id: int, rolled: Array) -> void:
	var kind: int = rolled[0]
	var amount: int = rolled[1]
	if _is_networked():
		_rpc_apply_buff.rpc(peer_id, kind, amount)
	else:
		_rpc_apply_buff(peer_id, kind, amount)


## Runs on EVERY peer. Two different jobs, split by who you are:
##   - the drinker applies the effect to their own character
##   - everyone else just reads the feed line
## The Sili slow is the exception - it lands on MatchManager, which every peer
## needs to agree on, so it is applied everywhere rather than only on the
## drinker's machine.
@rpc("authority", "call_local", "reliable")
func _rpc_apply_buff(peer_id: int, kind_index: int, amount: int) -> void:
	var drinker := _body_for_peer(peer_id)

	match kind_index:
		Buff.TUNNEL:
			if drinker != null and drinker.has_method("grant_tunnel_uses"):
				drinker.grant_tunnel_uses(amount)
		Buff.STAMINA:
			if drinker != null and drinker.has_method("grant_stamina_buff"):
				drinker.grant_stamina_buff(STAMINA_DURATION)
		Buff.SLOW:
			MatchManager.apply_sili_slow(SLOW_FACTOR, SLOW_DURATION)

	AudioManager.play_sfx_at("rescue_complete", _area.global_position, -3.0)

	# Broadcast locally rather than through MatchManager.broadcast_event: this
	# function already runs on every peer, so routing the line through another
	# RPC would print it once per peer on every screen.
	MatchManager.event_logged.emit(
		"%s drank: %s" % [
			MatchManager.tubig_name(_name_of(peer_id)),
			_describe(kind_index, amount)], "buff")


func _describe(kind: int, amount: int) -> String:
	match kind:
		Buff.TUNNEL:
			return "+%d tunnel use%s" % [amount, "" if amount == 1 else "s"]
		Buff.STAMINA:
			return "stamina surge (%ds)" % int(STAMINA_DURATION)
		Buff.SLOW:
			return "Sili slowed -%d%% (%ds)" % [
				roundi((1.0 - SLOW_FACTOR) * 100.0), int(SLOW_DURATION)]
	return "a blessing"


## Tints BOTH halves of the prop.
##
## Only "bottom" used to be tinted, so the basin lit up when a drink was ready
## while the top of the fountain stayed flat - one object visibly rendered in
## two different states. Tinting both makes the whole prop change together.
##
## The alpha of the top layer is NOT ours to set. canopy_fade.gd owns it, and
## writes modulate.a every physics tick to lift the canopy off a player standing
## underneath. So this writes RGB only and keeps whatever alpha the fade has
## reached - stamping a full Color here would flatten the fade to opaque on
## every state change, which is a flicker exactly when someone is stood under it.
func _apply_tint() -> void:
	var tint := READY_TINT if is_charged else SPENT_TINT
	_tint_layer("bottom", tint)
	_tint_layer("top", tint)


func _tint_layer(layer_name: String, tint: Color) -> void:
	var layer := get_node_or_null(layer_name) as CanvasItem
	if layer == null:
		return
	layer.modulate = Color(tint.r, tint.g, tint.b, layer.modulate.a)


func _name_of(peer_id: int) -> String:
	return NetworkManager.players.get(peer_id, "A Tubig")


func _body_for_peer(peer_id: int) -> Node2D:
	for body in get_tree().get_nodes_in_group("tubig"):
		if is_instance_valid(body) and body.get_multiplayer_authority() == peer_id:
			return body
	return null


func _local_peer_id() -> int:
	return multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1


func _sender_id() -> int:
	var id := multiplayer.get_remote_sender_id()
	return 1 if id == 0 else id


func _is_networked() -> bool:
	return multiplayer.has_multiplayer_peer() and multiplayer.get_peers().size() > 0


func _is_authority() -> bool:
	return not _is_networked() or multiplayer.is_server()
