@tool
extends Node2D
class_name SpawnPoint

## A draggable, visible spawn marker. Drop these under Map/SpawnPoints, set the
## role, and drag them around the level - multiplayer_arena.gd reads their
## positions at spawn time, so wherever you leave them in the editor is where
## players actually appear. No coordinates to retype in code.
##
## They're drawn with _draw() rather than a sprite so there's no placeholder
## art to ship, and @tool means the drawing shows up in the editor viewport
## while you're dragging. Tubig markers are blue circles, Sili markers are red
## diamonds - different colour AND different shape, so they stay tellable apart
## on a busy tilemap or for anyone who reads red and blue the same way.
##
## Hidden at runtime by default; flip show_in_game on to debug placement in a
## running build.

enum Role { TUBIG, SILI }

const TUBIG_COLOR := Color(0.24, 0.55, 0.95)
const SILI_COLOR := Color(0.90, 0.28, 0.20)

@export var role: Role = Role.TUBIG:
	set(value):
		role = value
		queue_redraw()

@export var radius: float = 12.0:
	set(value):
		radius = maxf(2.0, value)
		queue_redraw()

## Leave off for normal play. On, the marker keeps drawing in a running game,
## which is the quickest way to check a spawn really sits where you meant.
@export var show_in_game: bool = false


func _ready() -> void:
	add_to_group("spawn_points")
	if not Engine.is_editor_hint():
		visible = show_in_game


## The string form the arena and NetworkManager use for roles.
func role_name() -> String:
	return "sili" if role == Role.SILI else "tubig"


func _draw() -> void:
	var color := SILI_COLOR if role == Role.SILI else TUBIG_COLOR
	var fill := Color(color.r, color.g, color.b, 0.22)

	if role == Role.SILI:
		var diamond := PackedVector2Array([
			Vector2(0, -radius), Vector2(radius, 0),
			Vector2(0, radius), Vector2(-radius, 0),
		])
		draw_colored_polygon(diamond, fill)
		draw_polyline(diamond + PackedVector2Array([diamond[0]]), color, 2.0, true)
	else:
		draw_circle(Vector2.ZERO, radius, fill)
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 32, color, 2.0, true)

	# Crosshair marks the exact spawn pixel - the outline alone is ambiguous
	# once you've scaled the marker up.
	var tick := radius * 0.55
	draw_line(Vector2(-tick, 0), Vector2(tick, 0), color, 1.0)
	draw_line(Vector2(0, -tick), Vector2(0, tick), color, 1.0)

	# A stem above the marker so it's still findable when you're zoomed out
	# far enough that the head is only a few pixels across.
	draw_line(Vector2.ZERO, Vector2(0, -radius * 2.2), color, 2.0)
