extends CharacterBody2D

const WALK_SPEED = 100.0
const RUN_SPEED = 180.0  # same as Tubig - both roles move identically
const FRICTION = 1200.0

## --- Stamina System (reused so Sili also has a sprint/exhaustion loop) ---
@export var MAX_STAMINA: float = 100.0
@export var STAMINA_DRAIN_RATE: float = 25.0
@export var STAMINA_REGEN_RATE: float = 20.0
@export var EXHAUSTION_DURATION: float = 2.0

## --- Tag ability ---
@export var TAG_RETRY_COOLDOWN: float = 1.0  # local-only, just to avoid spamming the RPC every frame

signal stamina_changed(current_stamina: float, max_stamina: float)
signal exhausted
signal recovered_from_exhaustion
signal tagged_target(target: Node2D)

var stamina: float = MAX_STAMINA
var is_exhausted: bool = false
var _exhaustion_timer: float = 0.0
var last_direction: String = "s"

# Local-only throttle so a lingering overlap doesn't spam the ignite RPC every frame.
var _tag_cooldowns: Dictionary = {}

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var ui_layer: CanvasLayer = $ui
@onready var stamina_bar: ProgressBar = $ui/StaminaBar
@onready var tag_hitbox: Area2D = $TagHitbox


func _ready() -> void:
	if multiplayer.has_multiplayer_peer() and not is_multiplayer_authority():
		ui_layer.visible = false

	stamina_bar.max_value = MAX_STAMINA
	stamina_bar.value = stamina
	stamina_changed.connect(_on_stamina_changed)
	tag_hitbox.body_entered.connect(_on_tag_hitbox_body_entered)
	# "player" is the group canopy_fade.gd scans to find whoever this client
	# controls. The Tubig has always joined it; the Sili never did, so for the
	# one player being chased ON the Sili the canopies never lifted - they ran
	# the whole match under solid palm fronds while every Tubig got the fade.
	# It also meant every canopy layer on the map re-scanned an empty group
	# once per physics frame looking for a local player it could never find.
	add_to_group("player")
	add_to_group("sili")

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


func _physics_process(delta: float) -> void:
	if multiplayer.has_multiplayer_peer() and not is_multiplayer_authority():
		return

	# Frozen (and unable to tag) during the role reveal - returning before the
	# hitbox sweep below means a Tubig standing in the spawn ring can't be
	# caught the instant the arena loads.
	if MatchManager.inputs_locked():
		velocity = Vector2.ZERO
		animated_sprite.play("idle_" + last_direction)
		move_and_slide()
		return

	var input_vector := Input.get_vector("left", "right", "up", "down")
	var wants_to_run := Input.is_action_pressed("run") or Input.is_key_pressed(KEY_SHIFT)
	var is_moving := input_vector != Vector2.ZERO
	var is_running := wants_to_run and is_moving and not is_exhausted and stamina > 0.0

	_update_stamina(delta, is_running)
	_update_tag_cooldowns(delta)

	# MatchManager ramps this up at fixed points in the match - see
	# SILI_SPEED_STAGES. Every peer derives it from the synced clock, so the
	# Sili moves at the same speed on everyone's screen.
	var current_speed := (RUN_SPEED if is_running else WALK_SPEED) * MatchManager.sili_speed_multiplier()

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

	# Catch any Tubig that walked into the hitbox while it was already overlapping
	# (body_entered only fires once on first contact).
	for body in tag_hitbox.get_overlapping_bodies():
		_try_tag(body)


# --- Tagging ---

func _on_tag_hitbox_body_entered(body: Node2D) -> void:
	_try_tag(body)


func _try_tag(body: Node2D) -> void:
	if not body.is_in_group("tubig"):
		return
	if _tag_cooldowns.has(body) and _tag_cooldowns[body] > 0.0:
		return

	var target_heat: HeatStatus = body.get_node_or_null("HeatStatus")
	if target_heat == null or target_heat.is_incapacitated():
		return
	# Just rescued. The server would refuse this anyway (see HeatStatus.ignite),
	# so bailing here keeps the tag sound and the feed line from firing for a
	# hit that is never going to land. is_immune is replicated for exactly this.
	if target_heat.is_immune:
		return

	if multiplayer.has_multiplayer_peer():
		target_heat.rpc_id(1, "request_ignite")
	else:
		target_heat.ignite()

	_tag_cooldowns[body] = TAG_RETRY_COOLDOWN
	tagged_target.emit(body)
	# Positional, and played on the tagged player's position rather than the
	# Sili's: a nearby Tubig hearing this needs to know where their teammate
	# just went down, which is the information worth having.
	AudioManager.play_sfx_at("tag", body.global_position)
	# "Ang anghang!!" layered on top of the mechanical tag sfx, at the same
	# place. The synth hit carries the timing; the voice carries the identity.
	# AudioManager gates it, so four tags in one scramble give one shout.
	AudioManager.play_callout("anghang", body.global_position)
	MatchManager.broadcast_event("Sili tagged %s" % _name_of(body), "tag")


func _update_tag_cooldowns(delta: float) -> void:
	for body in _tag_cooldowns.keys():
		if not is_instance_valid(body):
			_tag_cooldowns.erase(body)
			continue
		_tag_cooldowns[body] = max(0.0, _tag_cooldowns[body] - delta)


# --- Stamina (identical loop to Tubig, kept separate to avoid coupling the two roles) ---

func _update_stamina(delta: float, is_running: bool) -> void:
	var previous_stamina := stamina

	if is_running:
		stamina = max(0.0, stamina - STAMINA_DRAIN_RATE * delta)
		if stamina == 0.0 and not is_exhausted:
			_enter_exhaustion()
	else:
		stamina = min(MAX_STAMINA, stamina + STAMINA_REGEN_RATE * delta)

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


## Feed lines use the lobby name so the readout matches the team panel. Falls
## back to the role when a peer id can't be resolved (offline test sessions).
func _name_of(character: Node) -> String:
	if character == null:
		return "a Tubig"
	var peer_id := character.get_multiplayer_authority()
	return NetworkManager.players.get(peer_id, "Tubig")
