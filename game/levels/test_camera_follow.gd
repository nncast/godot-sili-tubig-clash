extends Camera2D

## Small helper used only by test_local.gd. A character's OWN Camera2D can't be
## reparented into a popup window's SubViewport without breaking its onready
## paths (things like $Camera2D lookups elsewhere), so instead we drop a plain,
## un-owned Camera2D into each popup window and have it copy the target's
## position every frame. Cheap and good enough for a local test rig.

var target: Node2D = null


func _process(_delta: float) -> void:
	if target and is_instance_valid(target):
		global_position = target.global_position
	else:
		set_process(false)
