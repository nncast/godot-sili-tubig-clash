extends Node
class_name SpectatorView

## Follow-camera for players who are out of the round.
##
## Before this existed, a Tubig eliminated at 0:30 spent the next two and a
## half minutes looking at their own frozen sprite. That is a long time to ask
## somebody to sit still, and it also throws away the thing that makes a 4v1
## hunt worth watching - the four other people still playing it. Being out
## should change what you are doing, not stop you doing anything.
##
## Everything here is local. No RPCs, no replication: the spectator only reads
## positions that are already on this machine, so a dead player cannot leak
## information to their team or affect the match in any way. They also cannot
## see anything a live player couldn't - the mini-map stays hidden and there
## are no name tags, same as during play.
##
## Built entirely in code and parented by the arena, matching how
## pregame_reveal and match_result assemble themselves.

const CAMERA_ZOOM := Vector2(3, 3)
## How fast the camera slides when you switch subject. Instant cuts are
## disorienting when both the old and new subject are running.
const FOLLOW_LERP := 12.0

var _camera: Camera2D
var _layer: CanvasLayer
var _banner: Label
var _hint: Label
var _target: Node2D = null
var _own_body: Node2D = null
var _active: bool = false


func _ready() -> void:
	set_process(false)
	_build()
	MatchManager.match_ended.connect(_on_match_ended)


func _build() -> void:
	_camera = Camera2D.new()
	_camera.name = "SpectatorCamera"
	_camera.zoom = CAMERA_ZOOM
	_camera.enabled = false
	add_child(_camera)

	_layer = CanvasLayer.new()
	_layer.name = "SpectatorHUD"
	_layer.visible = false
	add_child(_layer)

	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_CENTER_TOP)
	column.offset_left = -260.0
	column.offset_right = 260.0
	# Below arena.gd's MatchLabel/AnnouncementLabel, which the same center-top
	# strip is also anchored to and which now runs down to y=108 (the clock
	# was enlarged and gained an announcement line under it). 24 put this
	# banner squarely on top of both.
	column.offset_top = 116.0
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(column)

	_banner = Label.new()
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_font_size_override("font_size", 24)
	_banner.add_theme_color_override("font_color", Color(0.95, 0.72, 0.35))
	_banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_banner.add_theme_constant_override("outline_size", 6)
	column.add_child(_banner)

	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.text = "[A] / [D]  change who you're watching"
	_hint.add_theme_font_size_override("font_size", 15)
	_hint.add_theme_color_override("font_color", Color(0.78, 0.80, 0.86))
	_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_hint.add_theme_constant_override("outline_size", 5)
	column.add_child(_hint)


## Called by the arena once it knows which character belongs to this screen.
## The Sili is never eliminated, so only a Tubig is ever wired up here.
func watch_local_player(body: Node2D) -> void:
	# Idempotent. The arena re-runs its HUD wiring on every spawn AND now on
	# every DEPARTURE too, so this is called repeatedly with the same body -
	# and connecting an already-connected signal is an error, not a no-op.
	if body == _own_body and body != null:
		return

	# Changing bodies (a rotation handing this peer a different character)
	# has to release the old one, or a stale HeatStatus keeps a live handle on
	# this node and can still trigger spectator mode from a past round.
	if _own_body != null and is_instance_valid(_own_body):
		var old_heat: HeatStatus = _own_body.get_node_or_null("HeatStatus")
		if old_heat != null and old_heat.died.is_connected(_on_local_death):
			old_heat.died.disconnect(_on_local_death)

	_own_body = body
	if body == null:
		return
	var heat: HeatStatus = body.get_node_or_null("HeatStatus")
	if heat == null:
		return
	if not heat.died.is_connected(_on_local_death):
		heat.died.connect(_on_local_death)
	# Late spawns and rejoins: if they are already out by the time this runs,
	# don't wait for a signal that has been and gone.
	if heat.is_dead():
		_on_local_death()


func _on_local_death() -> void:
	if _active:
		return
	_active = true

	# The dead player's own camera is a child of their body and is still
	# enabled; two active Camera2Ds in one viewport means the last one wins,
	# so this has to be turned off explicitly rather than just outranked.
	if _own_body:
		var own_cam := _own_body.get_node_or_null("Camera2D") as Camera2D
		if own_cam:
			own_cam.enabled = false

	_camera.global_position = _own_body.global_position if _own_body else Vector2.ZERO
	_camera.enabled = true
	_camera.make_current()
	_layer.visible = true
	set_process(true)

	_target = _next_target(0)
	_update_banner()


func _process(delta: float) -> void:
	if not _active:
		return

	# Whoever you were watching may have been caught since the last frame.
	if _target == null or not is_instance_valid(_target) or _is_out(_target):
		_target = _next_target(0)
		_update_banner()

	if _target and is_instance_valid(_target):
		_camera.global_position = _camera.global_position.lerp(
			_target.global_position, clampf(FOLLOW_LERP * delta, 0.0, 1.0))

	if MatchManager.is_over:
		return

	if Input.is_action_just_pressed("right"):
		_target = _next_target(1)
		_update_banner()
	elif Input.is_action_just_pressed("left"):
		_target = _next_target(-1)
		_update_banner()


## Everyone still in the round, in a stable order: the Sili first, then the
## Tubig sorted by peer id. Stable ordering matters - a list that reshuffles
## means pressing D twice can land you back where you started.
func _watchable() -> Array:
	var out: Array = []
	for body in get_tree().get_nodes_in_group("sili"):
		if is_instance_valid(body):
			out.append(body)

	var tubig: Array = []
	for body in get_tree().get_nodes_in_group("tubig"):
		if is_instance_valid(body) and not _is_out(body):
			tubig.append(body)
	tubig.sort_custom(func(a, b): return a.get_multiplayer_authority() < b.get_multiplayer_authority())

	out.append_array(tubig)
	return out


func _is_out(body: Node) -> bool:
	var heat: HeatStatus = body.get_node_or_null("HeatStatus")
	return heat != null and heat.is_dead()


## step of 0 means "give me a valid target", +1/-1 move along the list.
func _next_target(step: int) -> Node2D:
	var list := _watchable()
	if list.is_empty():
		return null
	var index := list.find(_target)
	if index == -1:
		return list[0]
	return list[(index + step + list.size()) % list.size()]


func _update_banner() -> void:
	if _target == null or not is_instance_valid(_target):
		_banner.text = "SPECTATING"
		return
	var peer_id := _target.get_multiplayer_authority()
	var who: String = NetworkManager.players.get(peer_id, "Player %d" % peer_id)
	var role := "Sili" if _target.is_in_group("sili") else "Tubig"
	_banner.text = "SPECTATING  -  %s (%s)" % [who, role]


## The result overlay takes the screen at the final whistle; leaving the
## spectator banner on top of it would just be clutter. The camera keeps
## following so the last few seconds still play out underneath.
func _on_match_ended(_sili_won: bool) -> void:
	_layer.visible = false
