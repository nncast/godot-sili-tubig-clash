extends CharacterBody2D

## After arriving, E is dead for this long. Without it the arrival mouth
## registers you instantly and the next tap bounces you straight back.
const TUNNEL_COOLDOWN := 1.0

## Tunnel trips per match. The cooldown alone only slows spamming down; a hard
## budget is what makes reaching a mouth a decision rather than a free reset
## button you mash every time the Sili gets close.
## Greyed-out heart. Kept as a constant so the player HUD and the team panel
## can't drift apart.
const HEART_SPENT_COLOR := Color(0.25, 0.25, 0.25, 0.5)

const TUNNEL_USES_MAX := 3

## Hard ceiling on tunnel charges however many fountain rolls land on you. Four
## drinks exist in a round (one per Sili speed stage) and a lucky run of +3s
## would otherwise hand one player twelve free map-crossings, which stops being
## a decision and starts being an exploit - and "balanced mechanics, no unfair
## advantage" is its own judging line.
const TUNNEL_USES_CEILING := 6

## What a fountain STAMINA roll is worth: sprint costs a third less and recovers
## half again as fast, for the duration the fountain hands over.
const STAMINA_BUFF_DRAIN_SCALE := 0.65
const STAMINA_BUFF_REGEN_SCALE := 1.5

const WALK_SPEED = 100.0
const RUN_SPEED = 180.0
const FRICTION = 1200.0

## --- Stamina System ---
@export var MAX_STAMINA: float = 100.0
@export var STAMINA_DRAIN_RATE: float = 25.0
@export var STAMINA_REGEN_RATE: float = 20.0
@export var EXHAUSTION_DURATION: float = 2.0

## --- Rescue System ---
## Hearts are LIVES, not rescue charges. You lose one when the Sili tags you,
## and you never get it back - not by being rescued, and not by anything else.
## Rescuing costs the rescuer nothing; its only job is to unfreeze the person
## who was tagged before their burn times out.
##
## The count itself now lives on HeatStatus, which the server owns - see the
## comment on HeatStatus.lives_left. This script only draws it.
@export var RESCUE_CHANNEL_TIME: float = 6.0  # seconds, per doc's 5-8s range

## --- Rescue burst ---
## The other half of rescue immunity (the tag-proof half lives on HeatStatus).
## Being untaggable is worthless if you stand up inside the Sili's hitbox and
## walk away at the same speed they walk - you are simply re-tagged the frame
## the immunity ends. The burst is what turns those 1.5 seconds into actual
## distance. Runs slightly longer than the immunity so the sprint doesn't die
## at the exact moment you become vulnerable again.
@export var RESCUE_BURST_TIME: float = 2.0
@export var RESCUE_BURST_SPEED_SCALE: float = 1.35

## --- Stealth ---
@export var CONCEAL_SETTLE_TIME: float = 0.35  # how long you must hold still inside a hiding spot
@export var CONCEALED_SPRITE_ALPHA: float = 0.55  # local-only feedback, not real invisibility

## --- Sili spotting ---
@export var SIGHTING_INTERVAL: float = 0.15  # how often we re-check if the Sili is on screen
@export var SIGHTING_MARGIN: float = 0.08    # ignore the outer 8% of the screen edge

signal stamina_changed(current_stamina: float, max_stamina: float)
signal exhausted
signal recovered_from_exhaustion
signal rescue_progress(progress: float)  # 0.0 - 1.0, for a channel bar
signal concealment_changed(is_concealed: bool)

var stamina: float = MAX_STAMINA
var is_exhausted: bool = false
var _exhaustion_timer: float = 0.0
var last_direction: String = "s"

## Replicated (see tubig.tscn's MPSync) because the mini-map has to hide this
## player's dot on EVERY peer's screen, not just their own. Same property-with-
## setter trick as lives_left: MultiplayerSynchronizer assigns it directly on
## remote peers, and routing through the setter keeps concealment_changed firing
## everywhere instead of only where the value was first computed.
var is_concealed: bool = false:
	set(value):
		if value == is_concealed:
			return
		is_concealed = value
		concealment_changed.emit(value)

var _rescue_target: Node2D = null
var _rescue_timer: float = 0.0
var _is_channeling: bool = false
var _progress_broadcast_accum: float = 0.0
var _conceal_timer: float = 0.0
var _sighting_accum: float = 0.0
var _last_reported_sighting: bool = false
var _hidden_label: Label = null

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var ui_layer: CanvasLayer = $ui
@onready var stamina_bar: ProgressBar = $ui/StaminaBar
@onready var rescue_bar: ProgressBar = $ui/RescueBar
@onready var hearts: Array = [$ui/HeartsRow/Heart1, $ui/HeartsRow/Heart2, $ui/HeartsRow/Heart3]
@onready var heat_status: HeatStatus = $HeatStatus
@onready var interaction_area: Area2D = $InteractionArea

## Set by whichever Tunnel mouth we're standing in - see tunnel.gd. Null means
## there's nothing to travel through.
var _nearby_tunnel: Tunnel = null
var _tunnel_cooldown: float = 0.0
var _tunnel_prompt: Label = null
var _rescue_prompt: Label = null
## Tracked per Tubig and spent locally, like stamina. Players are rebuilt when
## the arena reloads, so a replay hands everyone a fresh set.
var tunnel_uses_left: int = TUNNEL_USES_MAX
## Set by whichever Fountain we're standing in - see fountain.gd. Exactly the
## same push-from-the-prop pattern as _nearby_tunnel, and for the same reason:
## Sili has no set_nearby_fountain(), so the Sili is never even offered it.
var _nearby_fountain: Fountain = null
var _fountain_prompt: Label = null
var _stamina_buff_remaining: float = 0.0
var _rescue_burst_remaining: float = 0.0
var _struggle_prompt: Label = null
@onready var rescue_indicator: ProgressBar = $RescueIndicator
@onready var rescue_indicator_label: Label = $RescueIndicator/RescueLabel


func _ready() -> void:
	if multiplayer.has_multiplayer_peer() and not is_multiplayer_authority():
		ui_layer.visible = false

	stamina_bar.max_value = MAX_STAMINA
	stamina_bar.value = stamina
	stamina_changed.connect(_on_stamina_changed)

	heat_status.state_changed.connect(_on_heat_state_changed)

	rescue_bar.visible = false
	rescue_progress.connect(_on_rescue_progress)
	heat_status.lives_changed.connect(_on_lives_changed)
	# Fires on every peer, because is_immune is replicated - which is what lets
	# a bystander see the rescued player flash rather than only the person it
	# happened to.
	heat_status.immunity_changed.connect(_on_immunity_changed)

	_update_hearts(heat_status.lives_left)

	rescue_indicator.visible = false

	_build_hidden_label()
	concealment_changed.connect(_on_concealment_changed)

	add_to_group("player")  # keeps compatibility with the canopy fade (over.gd)
	add_to_group("tubig")

	# Footsteps run for every character on screen, not just ours - hearing
	# someone sprint past on gravel is half the game. Only the local player
	# gets the ocean ambience, though.
	var surface_audio := SurfaceAudio.new()
	surface_audio.name = "SurfaceAudio"
	surface_audio.setup(
		self,
		not multiplayer.has_multiplayer_peer() or is_multiplayer_authority(),
		(WALK_SPEED + RUN_SPEED) * 0.5)
	add_child(surface_audio)


func _build_hidden_label() -> void:
	_hidden_label = Label.new()
	_hidden_label.text = "HIDDEN"
	_hidden_label.visible = false
	_hidden_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hidden_label.offset_left = -60.0
	_hidden_label.offset_top = -130.0
	_hidden_label.offset_right = 60.0
	_hidden_label.offset_bottom = -105.0
	_hidden_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hidden_label.add_theme_font_size_override("font_size", 16)
	_hidden_label.add_theme_color_override("font_color", Color(0.55, 0.95, 0.7))
	ui_layer.add_child(_hidden_label)


func _on_concealment_changed(concealed: bool) -> void:
	if not multiplayer.has_multiplayer_peer() or is_multiplayer_authority():
		animated_sprite.modulate.a = CONCEALED_SPRITE_ALPHA if concealed else 1.0
		if _hidden_label:
			_hidden_label.visible = concealed


func _physics_process(delta: float) -> void:
	if multiplayer.has_multiplayer_peer() and not is_multiplayer_authority():
		return

	if MatchManager.inputs_locked():
		velocity = Vector2.ZERO
		animated_sprite.play("idle_" + last_direction)
		move_and_slide()
		return

	_update_sili_sighting(delta)

	if heat_status.is_incapacitated():
		velocity = velocity.move_toward(Vector2.ZERO, FRICTION * delta)
		_play_heat_animation()
		move_and_slide()
		_cancel_rescue_channel()
		is_concealed = false
		_conceal_timer = 0.0
		# Being tagged used to mean fifteen to thirty seconds of holding no
		# keys and watching. This is the one thing a rooted player can still
		# do, so it is handled here rather than above the incapacitated guard.
		_handle_struggle_input()
		_update_struggle_prompt()
		return

	_hide_struggle_prompt()

	var input_vector := Input.get_vector("left", "right", "up", "down")
	var wants_to_run := Input.is_action_pressed("run") or Input.is_key_pressed(KEY_SHIFT)
	var wants_to_rescue := Input.is_action_pressed("rescue")

	_tunnel_cooldown = maxf(0.0, _tunnel_cooldown - delta)
	_stamina_buff_remaining = maxf(0.0, _stamina_buff_remaining - delta)
	_rescue_burst_remaining = maxf(0.0, _rescue_burst_remaining - delta)
	if Input.is_action_just_pressed("rescue"):
		_try_interact()
	_update_tunnel_prompt()
	_update_fountain_prompt()
	_update_rescue_prompt()

	var is_moving := input_vector != Vector2.ZERO

	_update_concealment(delta, is_moving)

	if wants_to_rescue and not is_moving:
		_handle_rescue_channel(delta)
	else:
		_cancel_rescue_channel()

	var is_running := wants_to_run and is_moving and not is_exhausted and stamina > 0.0 and not _is_channeling

	_update_stamina(delta, is_running)

	if _is_channeling:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var current_speed := RUN_SPEED if is_running else WALK_SPEED
	# Multiplies whichever speed you were already at, so the burst helps a
	# player with no stamina left too - which is the usual state of someone who
	# just got caught after a long chase.
	if _rescue_burst_remaining > 0.0:
		current_speed *= RESCUE_BURST_SPEED_SCALE

	if is_moving:
		velocity = input_vector * current_speed
		var suffix = get_direction_suffix(input_vector)
		last_direction = suffix
		animated_sprite.flip_h = (input_vector.x < 0)
		var anim_prefix := "run_" if is_running else "walk_"
		animated_sprite.play(anim_prefix + suffix)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, FRICTION * delta)
		animated_sprite.play("idle_" + last_direction)

	move_and_slide()


# --- Rescue ("Tubig!") ---

## rpc() on a node aborts with an error when there's no connected peer, and this
## fires every 0.1s for the whole channel - so an offline or single-instance test
## used to error out the moment you held E next to a burning ally. Same guard
## _complete_rescue already used, just applied everywhere the RPC is sent.
func _send_rescue_progress(target: Node, progress: float, seconds_left: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().size() > 0:
		target.rpc("show_rescue_progress", progress, seconds_left)
	else:
		target.show_rescue_progress(progress, seconds_left)


func _handle_rescue_channel(delta: float) -> void:
	# No cost and no charge count: a rescue only unfreezes the target, so the
	# rescuer's own hearts are irrelevant to whether they can attempt one.
	if not MatchManager.rescues_available():
		_cancel_rescue_channel()
		return

	var target := _find_burning_ally()
	if target == null:
		_cancel_rescue_channel()
		return

	if target != _rescue_target:
		_rescue_target = target
		_rescue_timer = 0.0
		_progress_broadcast_accum = 0.0
		AudioManager.play_sfx_at("rescue_start", global_position)

	_is_channeling = true
	_rescue_timer += delta
	var progress: float = _rescue_timer / RESCUE_CHANNEL_TIME
	rescue_progress.emit(progress)

	_progress_broadcast_accum += delta
	if _progress_broadcast_accum >= 0.1 or progress >= 1.0:
		_progress_broadcast_accum = 0.0
		_send_rescue_progress(target, progress, RESCUE_CHANNEL_TIME - _rescue_timer)

	if _rescue_timer >= RESCUE_CHANNEL_TIME:
		_complete_rescue()


func _complete_rescue() -> void:
	if _rescue_target and is_instance_valid(_rescue_target):
		var target_heat: HeatStatus = _rescue_target.get_node_or_null("HeatStatus")
		if target_heat:
			if multiplayer.has_multiplayer_peer():
				target_heat.rpc_id(1, "request_cool_fully")
			else:
				target_heat.cool_fully()
		_send_rescue_progress(_rescue_target, 0.0, 0.0)

	MatchManager.broadcast_event(
		"%s rescued %s" % [_own_name(), _name_of(_rescue_target)], "rescue")

	_cancel_rescue_channel()


func _cancel_rescue_channel() -> void:
	var was_channeling := _is_channeling
	_is_channeling = false
	if was_channeling and _rescue_target and is_instance_valid(_rescue_target):
		_send_rescue_progress(_rescue_target, 0.0, 0.0)
	_rescue_target = null
	_rescue_timer = 0.0
	_progress_broadcast_accum = 0.0
	rescue_progress.emit(0.0)


# --- Struggling out of a burn ---

## Sends the tap; the server decides whether it counts. Deliberately does NOT
## rate-limit locally beyond "just pressed" - the interval and the ceiling are
## both enforced in HeatStatus._apply_struggle, and duplicating them here would
## create two places to disagree about the same rule.
##
## DEAD players are excluded: the burn already timed out, so there is nothing
## left to buy back and letting them keep tapping would read as the mechanic
## being broken rather than as being out of the round.
func _handle_struggle_input() -> void:
	if not heat_status.is_burning():
		return
	if not Input.is_action_just_pressed("struggle"):
		return
	if multiplayer.has_multiplayer_peer():
		heat_status.rpc_id(1, "request_struggle")
	else:
		heat_status.request_struggle()


## States the budget on screen, because a cap nobody can see reads as a bug.
## Shows seconds bought against seconds available, so the moment the taps stop
## working is a number the player watched fill up rather than a surprise.
func _update_struggle_prompt() -> void:
	if _struggle_prompt == null:
		_struggle_prompt = Label.new()
		_struggle_prompt.name = "StrugglePrompt"
		_struggle_prompt.anchor_left = 0.5
		_struggle_prompt.anchor_right = 0.5
		_struggle_prompt.anchor_top = 1.0
		_struggle_prompt.anchor_bottom = 1.0
		_struggle_prompt.offset_left = -160.0
		_struggle_prompt.offset_right = 160.0
		_struggle_prompt.offset_top = -158.0
		_struggle_prompt.offset_bottom = -132.0
		_struggle_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_struggle_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		_struggle_prompt.add_theme_constant_override("outline_size", 5)
		ui_layer.add_child(_struggle_prompt)

	if heat_status.is_dead():
		_struggle_prompt.text = "Burned out - wait for the next round"
		_struggle_prompt.modulate = Color(0.6, 0.6, 0.62)
		_struggle_prompt.visible = true
		return

	if heat_status.struggle_exhausted():
		_struggle_prompt.text = "Can't hold on any longer (+%.1fs used)" % heat_status.STRUGGLE_MAX_BONUS
		_struggle_prompt.modulate = Color(0.85, 0.55, 0.35)
	else:
		_struggle_prompt.text = "Mash [SPACE] to hold on  (+%.1fs / %.1fs max)" % [
			heat_status.struggle_bonus, heat_status.STRUGGLE_MAX_BONUS]
		_struggle_prompt.modulate = Color(1.0, 0.82, 0.35)
	_struggle_prompt.visible = true


func _hide_struggle_prompt() -> void:
	if _struggle_prompt:
		_struggle_prompt.visible = false


## Runs on every peer. The local player gets the speed burst (they are the only
## one simulating their own movement); everyone gets the flash, so the Sili can
## see why their tag did nothing instead of concluding the hitbox is broken.
func _on_immunity_changed(immune: bool) -> void:
	# self_modulate, not modulate: concealment already owns `modulate.a` (see
	# _on_concealment_changed), and the two multiply, so writing the flash into
	# a separate channel means neither can stamp on the other's value.
	if not immune:
		animated_sprite.self_modulate = Color.WHITE
		return

	if not multiplayer.has_multiplayer_peer() or is_multiplayer_authority():
		_rescue_burst_remaining = RESCUE_BURST_TIME

	animated_sprite.self_modulate = Color(1.4, 1.4, 1.8)
	var tween := create_tween()
	tween.tween_property(animated_sprite, "self_modulate", Color.WHITE,
		heat_status.RESCUE_IMMUNITY_TIME)


# --- Stealth / hiding places ---

func _update_concealment(delta: float, is_moving: bool) -> void:
	if is_moving or _current_hiding_spot() == null:
		_conceal_timer = 0.0
		is_concealed = false
		return

	_conceal_timer = min(_conceal_timer + delta, CONCEAL_SETTLE_TIME)
	is_concealed = _conceal_timer >= CONCEAL_SETTLE_TIME


func _current_hiding_spot() -> Node2D:
	for spot in get_tree().get_nodes_in_group("hiding_spot"):
		if is_instance_valid(spot) and spot.contains_point(global_position):
			return spot
	return null


# --- Spotting the Sili ---

func _update_sili_sighting(delta: float) -> void:
	_sighting_accum += delta
	if _sighting_accum < SIGHTING_INTERVAL:
		return
	_sighting_accum = 0.0

	var seen := _can_see_sili()
	if seen == _last_reported_sighting:
		return
	_last_reported_sighting = seen
	SightingTracker.report_sighting(seen)


func _can_see_sili() -> bool:
	var sili := get_tree().get_first_node_in_group("sili")
	if sili == null or not is_instance_valid(sili):
		return false

	var camera: Camera2D = get_node_or_null("Camera2D")
	if camera == null or not camera.enabled:
		return false

	var view_size: Vector2 = get_viewport_rect().size / camera.zoom
	var margin: Vector2 = view_size * SIGHTING_MARGIN
	var view_rect := Rect2(
		camera.get_screen_center_position() - view_size * 0.5 + margin * 0.5,
		view_size - margin
	)
	return view_rect.has_point(sili.global_position)


func _exit_tree() -> void:
	if not _last_reported_sighting:
		return
	_last_reported_sighting = false
	if is_instance_valid(SightingTracker):
		SightingTracker.report_sighting(false)


## Called by Tunnel.body_entered/body_exited. The Sili has no equivalent, which
## is exactly how the tunnel stays Tubig-only.
func set_nearby_tunnel(tunnel: Tunnel) -> void:
	_nearby_tunnel = tunnel


func clear_nearby_tunnel(tunnel: Tunnel) -> void:
	if _nearby_tunnel == tunnel:
		_nearby_tunnel = null


## Called by Fountain.body_entered/body_exited. The Sili has no equivalent,
## which is exactly how the fountain stays Tubig-only - same construction as
## set_nearby_tunnel above.
func set_nearby_fountain(fountain: Fountain) -> void:
	_nearby_fountain = fountain


func clear_nearby_fountain(fountain: Fountain) -> void:
	if _nearby_fountain == fountain:
		_nearby_fountain = null


## E now does three different things, so the order it resolves in is a design
## decision rather than an implementation detail. Highest priority first:
##
##   1. RESCUE a burning ally. A tap next to someone who needs pulling out must
##      never quietly do something else and leave them behind.
##   2. DRINK from a charged fountain. Deliberately above the tunnel: you had to
##      walk to the fountain on purpose, and a charge is a shared team resource
##      that expires when the next speed stage lands. Being teleported away
##      instead - by a tunnel mouth that happened to overlap - would cost the
##      whole team the drink, not just you.
##   3. TAKE THE TUNNEL, the fallback when nothing above applies.
##
## Each prompt says which of the three is currently armed, so the priority is
## visible on screen instead of being something players have to learn by
## losing a rescue to it.
func _try_interact() -> void:
	if _find_burning_ally() != null:
		return  # rescue is a hold, handled by _handle_rescue_channel
	if _try_use_fountain():
		return
	_try_use_tunnel()


## Returns whether the tap was consumed. The answer arrives asynchronously (the
## server rolls the buff and RPCs it back), but the tap itself is spent either
## way - otherwise a mistimed press would fall through and burn a tunnel charge
## on a player who was reaching for a drink.
func _try_use_fountain() -> bool:
	if _nearby_fountain == null or not is_instance_valid(_nearby_fountain):
		return false
	if not _nearby_fountain.is_charged:
		return false
	if multiplayer.has_multiplayer_peer():
		_nearby_fountain.rpc_id(1, "request_drink")
	else:
		_nearby_fountain.request_drink()
	return true


## Applied by Fountain._rpc_apply_buff on the drinker's own machine.
func grant_tunnel_uses(amount: int) -> void:
	tunnel_uses_left = mini(TUNNEL_USES_CEILING, tunnel_uses_left + amount)


func grant_stamina_buff(duration: float) -> void:
	_stamina_buff_remaining = maxf(_stamina_buff_remaining, duration)


func _try_use_tunnel() -> void:
	if _tunnel_cooldown > 0.0 or _is_channeling or tunnel_uses_left <= 0:
		return
	if _nearby_tunnel == null or not is_instance_valid(_nearby_tunnel):
		return

	var destination = _nearby_tunnel.exit_position()
	if destination == null:
		return

	# Done on our own authority and carried out by MPSync: the tunnel is a fixed
	# pair of points baked into the level, so there is nothing here for the
	# server to arbitrate.
	# Both ends, deliberately: the whole risk of a tunnel is that the Sili can
	# hear where you went as well as where you left from.
	AudioManager.play_sfx_at("tunnel", global_position)
	AudioManager.play_sfx_at("tunnel", destination, -4.0)

	global_position = destination
	velocity = Vector2.ZERO
	_tunnel_cooldown = TUNNEL_COOLDOWN
	tunnel_uses_left -= 1
	# Concealment means having stayed still and unseen; surfacing somewhere else
	# across the map is neither.
	is_concealed = false
	_conceal_timer = 0.0


## Shows the remaining budget rather than just the key, so the choice to spend
## a trip is made with the count in view. Stays visible when the budget is gone,
## reading as spent instead of silently disappearing - otherwise a player who
## walked into a mouth would think the tunnel itself was broken.
func _update_tunnel_prompt() -> void:
	var should_show := _nearby_tunnel != null and _tunnel_cooldown <= 0.0
	if _tunnel_prompt == null:
		if not should_show:
			return
		_tunnel_prompt = Label.new()
		_tunnel_prompt.name = "TunnelPrompt"
		_tunnel_prompt.anchor_left = 0.5
		_tunnel_prompt.anchor_right = 0.5
		_tunnel_prompt.anchor_top = 1.0
		_tunnel_prompt.anchor_bottom = 1.0
		_tunnel_prompt.offset_left = -80.0
		_tunnel_prompt.offset_right = 80.0
		_tunnel_prompt.offset_top = -130.0
		_tunnel_prompt.offset_bottom = -104.0
		_tunnel_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ui_layer.add_child(_tunnel_prompt)
	_tunnel_prompt.visible = should_show
	if not should_show:
		return
	if tunnel_uses_left > 0:
		_tunnel_prompt.text = "[E] Tunnel  (%dx)" % tunnel_uses_left
		_tunnel_prompt.modulate = Color.WHITE
	else:
		_tunnel_prompt.text = "Tunnel used up"
		_tunnel_prompt.modulate = Color(0.65, 0.65, 0.68)


## Sits between the tunnel prompt and the rescue prompt, so all three can be on
## screen at once without overlapping and the stack reads top-to-bottom in the
## same order E resolves them (see _try_interact).
##
## Stays visible when the fountain is empty rather than disappearing, for the
## same reason the tunnel prompt does: a player standing at a fountain that
## silently shows nothing concludes the fountain is broken, where "Fountain is
## empty" tells them to come back after the next speed-up.
func _update_fountain_prompt() -> void:
	var near := _nearby_fountain != null and is_instance_valid(_nearby_fountain)

	if _fountain_prompt == null:
		if not near:
			return
		_fountain_prompt = Label.new()
		_fountain_prompt.name = "FountainPrompt"
		_fountain_prompt.anchor_left = 0.5
		_fountain_prompt.anchor_right = 0.5
		_fountain_prompt.anchor_top = 1.0
		_fountain_prompt.anchor_bottom = 1.0
		_fountain_prompt.offset_left = -110.0
		_fountain_prompt.offset_right = 110.0
		_fountain_prompt.offset_top = -186.0
		_fountain_prompt.offset_bottom = -160.0
		_fountain_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_fountain_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		_fountain_prompt.add_theme_constant_override("outline_size", 5)
		ui_layer.add_child(_fountain_prompt)

	_fountain_prompt.visible = near
	if not near:
		return
	if _nearby_fountain.is_charged:
		_fountain_prompt.text = "[E] Drink"
		_fountain_prompt.modulate = Color(0.45, 0.85, 0.95)
	else:
		_fountain_prompt.text = "Fountain is empty"
		_fountain_prompt.modulate = Color(0.65, 0.65, 0.68)


## Mirrors the tunnel prompt, above the fountain line so the three never overlap
## when a burning ally happens to be standing in a tunnel mouth. Says "hold" because
## rescuing is a channel, not a tap - without that, players tap E once, see
## nothing happen and assume the rescue is broken.
func _update_rescue_prompt() -> void:
	var target := _find_burning_ally()
	var can_rescue := target != null and MatchManager.rescues_available()

	if _rescue_prompt == null:
		if not can_rescue:
			return
		_rescue_prompt = Label.new()
		_rescue_prompt.name = "RescuePrompt"
		_rescue_prompt.anchor_left = 0.5
		_rescue_prompt.anchor_right = 0.5
		_rescue_prompt.anchor_top = 1.0
		_rescue_prompt.anchor_bottom = 1.0
		_rescue_prompt.offset_left = -110.0
		_rescue_prompt.offset_right = 110.0
		_rescue_prompt.offset_top = -214.0
		_rescue_prompt.offset_bottom = -188.0
		_rescue_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_rescue_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		_rescue_prompt.add_theme_constant_override("outline_size", 5)
		ui_layer.add_child(_rescue_prompt)

	_rescue_prompt.visible = can_rescue
	if not can_rescue:
		return
	if _is_channeling:
		_rescue_prompt.text = "Rescuing... keep holding [E]"
		_rescue_prompt.modulate = Color(0.52, 0.88, 0.62)
	else:
		_rescue_prompt.text = "Hold [E] to rescue"
		_rescue_prompt.modulate = Color.WHITE


func _own_name() -> String:
	return _name_of(self)


func _name_of(character: Node) -> String:
	if character == null:
		return "a Tubig"
	var peer_id := character.get_multiplayer_authority()
	return NetworkManager.players.get(peer_id, "Tubig")


func _find_burning_ally() -> Node2D:
	var closest: Node2D = null
	var closest_dist := INF
	for body in interaction_area.get_overlapping_bodies():
		if body == self or not body.is_in_group("tubig"):
			continue
		var body_heat: HeatStatus = body.get_node_or_null("HeatStatus")
		if body_heat and body_heat.is_burning():
			var dist := global_position.distance_squared_to(body.global_position)
			if dist < closest_dist:
				closest_dist = dist
				closest = body
	return closest


# --- Stamina ---

func _update_stamina(delta: float, is_running: bool) -> void:
	var previous_stamina := stamina

	var buffed := _stamina_buff_remaining > 0.0
	var drain := STAMINA_DRAIN_RATE * (STAMINA_BUFF_DRAIN_SCALE if buffed else 1.0)
	var regen := STAMINA_REGEN_RATE * (STAMINA_BUFF_REGEN_SCALE if buffed else 1.0)

	if is_running:
		stamina = max(0.0, stamina - drain * delta)
		if stamina == 0.0 and not is_exhausted:
			_enter_exhaustion()
	else:
		stamina = min(MAX_STAMINA, stamina + regen * delta)

	if is_exhausted:
		_exhaustion_timer -= delta
		if _exhaustion_timer <= 0.0:
			_exit_exhaustion()

	if stamina != previous_stamina:
		stamina_changed.emit(stamina, MAX_STAMINA)


func _enter_exhaustion() -> void:
	is_exhausted = true
	_exhaustion_timer = EXHAUSTION_DURATION
	exhausted.emit()


func _exit_exhaustion() -> void:
	is_exhausted = false
	_exhaustion_timer = 0.0
	recovered_from_exhaustion.emit()


func _on_stamina_changed(current_stamina: float, max_stamina: float) -> void:
	stamina_bar.value = current_stamina


func _on_rescue_progress(progress: float) -> void:
	rescue_bar.visible = progress > 0.0
	rescue_bar.value = progress * 100.0


func _on_lives_changed(new_lives_left: int) -> void:
	_update_hearts(new_lives_left)


## One heart per life remaining. No separate "tagged" shading any more - the
## tag now actually removes a heart, so showing both would double-count it.
func _update_hearts(lives_remaining: int) -> void:
	for i in hearts.size():
		hearts[i].modulate = Color.WHITE if i < lives_remaining else HEART_SPENT_COLOR


## Runs on EVERY peer, because HeatStatus.state is replicated - which is what
## makes these audible to bystanders and not just to the person it happened to.
func _on_heat_state_changed(new_state: HeatStatus.State) -> void:
	if new_state == HeatStatus.State.BURNING:
		animated_sprite.play("heat_" + last_direction)
	elif new_state == HeatStatus.State.DEAD:
		AudioManager.play_sfx_at("eliminated", global_position)
	elif new_state == HeatStatus.State.NORMAL:
		AudioManager.play_sfx_at("rescue_complete", global_position)
		# "Save!" - runs on every peer for the same reason the sfx does, so the
		# Sili hears that the body they were circling just got up.
		AudioManager.play_callout("save", global_position)


func _play_heat_animation() -> void:
	var anim := "heat_" + last_direction
	if heat_status.is_dead():
		if animated_sprite.animation != anim:
			animated_sprite.play(anim)
		animated_sprite.pause()
	elif animated_sprite.animation != anim or not animated_sprite.is_playing():
		animated_sprite.play(anim)


@rpc("any_peer", "call_local", "unreliable")
func show_rescue_progress(progress: float, seconds_left: float) -> void:
	rescue_indicator.visible = progress > 0.0
	rescue_indicator.value = progress * 100.0
	rescue_indicator_label.text = str(int(ceil(seconds_left)))


func get_direction_suffix(dir: Vector2) -> String:
	var angle = dir.angle()

	if angle >= 3*PI/8 and angle < 5*PI/8:
		return "s"
	elif angle >= -5*PI/8 and angle < -3*PI/8:
		return "n"
	elif (angle >= PI/8 and angle < 3*PI/8) or (angle >= 5*PI/8 and angle < 7*PI/8):
		return "se"
	elif (angle >= -3*PI/8 and angle < -PI/8) or (angle >= -7*PI/8 and angle < -5*PI/8):
		return "ne"
	else:
		return "e"
