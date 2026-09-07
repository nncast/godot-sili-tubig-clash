@tool
extends Node2D
class_name HidingSpot

## A designated patch of the map where a Tubig can conceal themselves.
##
## Standing still inside one for CONCEAL_SETTLE_TIME (see tubig.gd) drops that
## player's blue dot off the mini-map for the whole team until they move again.
## It does NOT make them invisible in-world - the Sili can still walk into them
## and tag them, so hiding trades information for the risk of being cornered.
##
## Deliberately not an Area2D: concealment is a simple point-in-rect test run by
## each Tubig against this group, which avoids a second physics layer and keeps
## the check deterministic across peers instead of depending on collision
## callback ordering.

@export var size: Vector2 = Vector2(48, 48):
	set(value):
		size = value
		queue_redraw()

## Editor-only tint so the designer can see where these sit on the tilemap.
## Never drawn at runtime.
@export var editor_color: Color = Color(0.25, 0.85, 0.45, 0.25)


func _ready() -> void:
	add_to_group("hiding_spot")
	if not Engine.is_editor_hint():
		queue_redraw()


func get_rect() -> Rect2:
	return Rect2(global_position - size * 0.5, size)


func contains_point(point: Vector2) -> bool:
	return get_rect().has_point(point)


func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var local_rect := Rect2(-size * 0.5, size)
	draw_rect(local_rect, editor_color, true)
	draw_rect(local_rect, Color(editor_color.r, editor_color.g, editor_color.b, 0.9), false, 1.0)
