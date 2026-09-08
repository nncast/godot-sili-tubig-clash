extends Node
class_name DangerMusic

## Fades the Danger_03 sting in while the Sili is close to the local Tubig, and
## back out once they've gone. Audio-only sibling of threat_vignette.gd: same
## question ("how close is the Sili?"), same deliberate silence about which
## DIRECTION they're in. Hearing that you're being hunted should make you look
## around, not tell you where to look.
##
## Sili players never hear it - they are the thing being warned about - and it
## drops away once the local player is Dead, since there is nothing left to run
## from.
##
## Created by arena.gd rather than placed in arena.tscn, for the same reason as
## SpectatorView: it is per-local-player state, and the arena already knows
## which character that is.

## Fade in once the Sili is closer than this...
@export var NEAR_RANGE: float = 260.0
## ...and back out only once they are further than THIS. The gap between the
## two is the whole point: with a single threshold, a chase circling a hut at
## roughly one distance retriggers the sting over and over. Hysteresis means
## the music commits to a decision and holds it.
@export var FAR_RANGE: float = 340.0

var _tracked_player: Node2D = null
var _enabled := false
var _near := false


func _ready() -> void:
	set_process(false)


## Called by the arena once it knows which character belongs to this peer.
## Passing anything other than a Tubig (or null) just leaves the music off.
## Safe to call repeatedly - the arena re-runs its HUD wiring every time any
## peer finishes spawning.
func track_player(player: Node2D, is_tubig: bool) -> void:
	_tracked_player = player
	_enabled = is_tubig and player != null
	set_process(_enabled)
	if not _enabled:
		_set_near(false)


func _process(_delta: float) -> void:
	if not _enabled or not is_instance_valid(_tracked_player):
		_set_near(false)
		return

	var heat = _tracked_player.get_node_or_null("HeatStatus")
	if heat and heat.is_dead():
		_set_near(false)
		return

	var distance := _sili_distance()
	if distance < 0.0:
		_set_near(false)  # no Sili in the scene yet, or it just left
		return

	# Only the threshold you are not currently sitting behind can fire, which
	# is what stops the sting stuttering at the boundary.
	if _near:
		if distance > FAR_RANGE:
			_set_near(false)
	elif distance < NEAR_RANGE:
		_set_near(true)


## Distance to the Sili, or -1.0 if there isn't one to measure against.
func _sili_distance() -> float:
	var sili := get_tree().get_first_node_in_group("sili") as Node2D
	if sili == null or not is_instance_valid(sili):
		return -1.0
	return _tracked_player.global_position.distance_to(sili.global_position)


func _set_near(value: bool) -> void:
	if value == _near:
		return
	_near = value
	if value:
		AudioManager.start_danger_music()
	else:
		AudioManager.stop_danger_music()


## Leaving the arena with the sting still up would carry it into the results
## screen and the lobby behind it.
func _exit_tree() -> void:
	if _near:
		AudioManager.kill_danger_music()
		_near = false
