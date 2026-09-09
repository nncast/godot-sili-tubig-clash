extends Node2D
class_name RevealSpot

## A zone that gives the Tubig team a brief, involuntary look at the Sili's
## position - a tactical glimpse, not permanent vision. Walking a Tubig into
## the radius forces THAT player's sighting report to true for
## REVEAL_DURATION seconds, which feeds the exact same team-wide "does anyone
## see the Sili" flag a real camera sighting would (see SightingTracker and
## tubig.gd's _update_sili_sighting) - so the whole team's minimap dot appears
## and clears exactly like an ordinary sighting, just without needing the Sili
## on anyone's actual screen.
##
## TUBIG ONLY, by the same construction as the tunnel and the fountain: the
## zone pushes itself onto whatever body walks in via trigger_sili_reveal(),
## Tubig implements that method and Sili does not, so the Sili is never even
## told the zone exists.
##
## Detection runs locally on every peer (same as Tunnel/Fountain), and is
## harmless to fire on a remote copy of a Tubig - trigger_sili_reveal() only
## does anything on the copy that peer actually drives, everyone else's copy
## just sets a var nothing reads.

const AREA_RADIUS: float = 60.0
const REVEAL_DURATION: float = 4.0


func _ready() -> void:
	add_to_group("reveal_spot")

	var area := Area2D.new()
	area.name = "InteractionArea"
	area.monitoring = true
	# Players are on physics layer 2, not the default 1 - see sili.tscn/
	# tubig.tscn's collision_layer and the comment on fountain.gd's own area.
	area.collision_mask = 2
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = AREA_RADIUS
	shape.shape = circle
	area.add_child(shape)
	add_child(area)

	area.body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node2D) -> void:
	if body.has_method("trigger_sili_reveal"):
		body.trigger_sili_reveal(REVEAL_DURATION)
