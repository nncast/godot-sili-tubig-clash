@tool
extends Area2D
class_name Tunnel

## One mouth of a two-way tunnel. Pair two of these with `linked_tunnel` and a
## Tubig standing in either one can press E to pop out at the other.
##
## Tubig only. The Sili is never registered by the mouth at all - it isn't that
## the Sili presses E and gets refused, it's that the tunnel doesn't know it
## exists. That keeps the rule in one place instead of scattering "if sili"
## checks through the movement code.
##
## The mouth pushes itself onto the player rather than the player scanning for
## mouths: on body_entered we call set_nearby_tunnel() if the body has it.
## Tubig implements it, Sili doesn't, so role filtering and the "am I close
## enough" test are the same check.
##
## @tool + _draw means the pairing is visible while you're editing: each mouth
## draws a line to its partner, so a tunnel that's linked to nothing (or to
## itself) is obvious in the viewport instead of at runtime.

## The other end. Leave empty and this mouth does nothing.
@export var linked_tunnel: NodePath:
	set(value):
		linked_tunnel = value
		queue_redraw()

## Where the traveller is dropped, relative to the far mouth. Nudge this out of
## the wall the tunnel is cut into, otherwise players arrive inside collision
## and get shoved somewhere unpredictable by the next move_and_slide().
@export var exit_offset: Vector2 = Vector2(0, 20):
	set(value):
		exit_offset = value
		queue_redraw()

## Draw the mouth in a running game too - handy for checking placement.
@export var show_in_game: bool = false

const MOUTH_COLOR := Color(0.55, 0.35, 0.85)


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group("tunnels")
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	if not show_in_game:
		# The CollisionShape2D still works while hidden; visible only governs
		# our _draw output.
		visible = false


func _on_body_entered(body: Node2D) -> void:
	if body.has_method("set_nearby_tunnel"):
		body.set_nearby_tunnel(self)


func _on_body_exited(body: Node2D) -> void:
	if body.has_method("clear_nearby_tunnel"):
		body.clear_nearby_tunnel(self)


func linked() -> Tunnel:
	if linked_tunnel.is_empty():
		return null
	return get_node_or_null(linked_tunnel) as Tunnel


## Global position a traveller should be placed at, or null if this mouth
## isn't wired to a working partner.
func exit_position() -> Variant:
	var other := linked()
	if other == null or other == self:
		return null
	return other.global_position + exit_offset


func _draw() -> void:
	if not Engine.is_editor_hint() and not show_in_game:
		return

	draw_circle(Vector2.ZERO, 14.0, Color(MOUTH_COLOR.r, MOUTH_COLOR.g, MOUTH_COLOR.b, 0.22))
	draw_arc(Vector2.ZERO, 14.0, 0.0, TAU, 24, MOUTH_COLOR, 2.0, true)

	var other := linked()
	if other == null:
		return

	# Line to the partner, plus a marker at the exact arrival spot, so you can
	# see at a glance that the drop point clears the wall.
	var to_other := to_local(other.global_position)
	draw_line(Vector2.ZERO, to_other, Color(MOUTH_COLOR.r, MOUTH_COLOR.g, MOUTH_COLOR.b, 0.5), 1.5)
	var arrival := to_local(other.global_position + exit_offset)
	draw_line(arrival + Vector2(-5, -5), arrival + Vector2(5, 5), MOUTH_COLOR, 1.5)
	draw_line(arrival + Vector2(5, -5), arrival + Vector2(-5, 5), MOUTH_COLOR, 1.5)
