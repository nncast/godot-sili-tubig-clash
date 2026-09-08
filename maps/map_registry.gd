class_name MapRegistry
extends RefCounted

## The single list of playable maps. The lobby, the arena and anything else
## that needs to know what levels exist all read from here, so adding a map is
## one entry plus one folder - nothing else in the project has to be told.
##
## THE MAP CONTRACT
##
## A scene listed here must satisfy all of the following, because the arena
## shell and the audio/mini-map systems assume it:
##
##   1. Root is a Node2D. The arena renames the instance to "Map" on load -
##      surface_audio.gd walks up the tree looking for that exact name, so it
##      is load-bearing.
##   2. Ground layers are named exactly: road, stairs, grass, sand, sandfade,
##      sea. These are the keys in SurfaceAudio.SURFACE_LAYERS; a typo means
##      silent footsteps on that surface, with no error to tell you why.
##   3. Overhead layers are named "over" (in a map) or "top" (in a prop scene
##      under game/props, where it is paired with a "bottom"), at z_index 21,
##      with canopy_fade.gd attached. The half of a prop that the player walks
##      IN FRONT of goes in "bottom" at the default z_index, and must not be
##      duplicated into "top" - a cell painted in both layers draws twice.
##
##      fade_mode follows from who OWNS the layer, not from how it is painted.
##      A prop owns its "top" outright, so WHOLE (fade the layer) is both
##      correct and free. Only a map-wide "over" holding several unrelated
##      canopies in one CanvasItem needs a masked mode, because there fading the
##      layer would lift every tree on the map at once.
##   4. A SpawnPoints child holding at least one "sili" marker and at least
##      four "tubig" markers.
##   5. NO player containers. Those belong to the shell - see the comment on
##      arena.tscn's SiliContainer.
##
## tools/test_maps.gd checks 1-4 against every entry below.

const MAPS := {
	"boracay": {
		"name": "Boracay",
		"scene": "res://maps/boracay/boracay.tscn",
	},
}

const DEFAULT_MAP := "boracay"


static func ids() -> Array:
	return MAPS.keys()


static func exists(id: String) -> bool:
	return MAPS.has(id)


## Falls back rather than failing. A client that somehow asks for a map it does
## not have should land in a playable level, not a blank screen.
static func scene_path(id: String) -> String:
	var entry: Dictionary = MAPS.get(id, MAPS[DEFAULT_MAP])
	return entry["scene"]


static func display_name(id: String) -> String:
	var entry: Dictionary = MAPS.get(id, MAPS[DEFAULT_MAP])
	return entry["name"]
