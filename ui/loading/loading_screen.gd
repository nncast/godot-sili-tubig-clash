extends CanvasLayer

## Autoload. The curtain that covers a heavy scene swap.
##
## Entering the arena is the most expensive thing this game does: it loads
## arena.tscn, loads the map (boracay.tscn is a few megabytes of tilemap data),
## instances forty-odd palms that each build their own shader material, then
## bakes the mini-map by walking every painted layer. All of that used to run
## inside a single change_scene_to_file() call, on the main thread, with the
## lobby still on screen - so the game simply stopped responding for a second
## or two and looked like it had hung.
##
## Two things fix that, and both are needed:
##
##   1. THE CURTAIN. Something has to be on screen during the freeze, or the
##      freeze is all the player sees. This node lives under the tree root
##      rather than inside any scene, which is what lets it survive the very
##      scene change it is covering.
##   2. THREADED LOADING. Reading the scene files off disk is the half of the
##      cost that does not have to block, so it doesn't - the load runs on a
##      worker thread while this layer keeps drawing. Instancing and _ready()
##      still block, which is exactly why (1) is not optional.
##
## The curtain is deliberately NOT opaque. At 50% black the lobby (and then the
## arena) stays visible underneath, so the transition reads as a moment in the
## same session rather than a cut to a different program.

## Frames of the characters' "run_e" animation, as top-left corners in their
## sprite sheets. Both sheets share a layout, so one list drives both.
## Duplicated from sili.tscn/tubig.tscn rather than instanced from them: those
## scenes are CharacterBody2Ds carrying a camera, a HUD, network synchronisers
## and scripts that expect to be in a live match. Putting one on a menu would
## start a second Camera2D fighting the real one.
const RUN_FRAME_ORIGINS: Array[Vector2] = [
	Vector2(288, 72), Vector2(312, 72), Vector2(336, 72),
	Vector2(360, 72), Vector2(384, 72), Vector2(408, 72),
]
const FRAME_SIZE := Vector2(24, 24)
const RUN_FPS := 10.0

const SILI_SHEET := "res://game/assets/art/characters/16x16 Sili.png"
const TUBIG_SHEET := "res://game/assets/art/characters/16x16 Tubig.png"

## Pixel art at 24px would be a smudge on a 1080p screen; 4x keeps it crisp
## because the project renders with nearest-neighbour filtering.
const SPRITE_SCALE := 4.0

## The strip the runners cross. Wider than it needs to look so they can start
## and finish off the ends instead of popping into existence mid-air.
const RUNWAY := Vector2(420, 120)
const RUN_SPEED_PX := 190.0
## How far ahead of the Sili the Tubig runs. The gap is the joke: it never
## closes, no matter how long the level takes to load.
const TUBIG_LEAD := 104.0

## Held for at least this long even if the load finishes sooner. A curtain that
## flashes up for three frames on a fast machine is worse than no curtain - it
## reads as a glitch.
const MIN_VISIBLE_TIME := 0.6
const FADE_OUT_TIME := 0.25

## Cycles "Loading" through its trailing dots. Purely so the screen is visibly
## alive during the part of the load that genuinely blocks.
const DOT_INTERVAL := 0.35

const TEXT_COLOR := Color(1.0, 0.94, 0.85)

var _root: Control = null
var _label: Label = null
var _sili: AnimatedSprite2D = null
var _tubig: AnimatedSprite2D = null

var _busy: bool = false
var _run_offset: float = 0.0
var _dot_timer: float = 0.0
var _dot_count: int = 0
var _base_text: String = "Loading"


func _ready() -> void:
	# Above every in-game CanvasLayer, including the arena HUD and the match
	# result overlay, so nothing can draw on top of the curtain.
	layer = 128
	# The tree is not paused during a scene change, but the pause menu could be
	# open when a round ends and the next one loads. ALWAYS means the curtain
	# animates either way.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_set_visible(false)


## Swaps to `scene_path` behind the curtain.
##
## `preload_paths` are pulled into the resource cache first. They are not
## strictly required - the new scene would load them itself - but doing it here
## means they load on the worker thread with the curtain already up, instead of
## inside the new scene's _ready() where they would block. The arena passes its
## map for exactly this reason.
##
## Safe to call without awaiting; it drives itself off process frames.
func change_scene(scene_path: String, preload_paths: Array = [], label: String = "Loading") -> void:
	if _busy:
		return
	_busy = true

	_base_text = label
	_set_visible(true)

	var shown_at := Time.get_ticks_msec()

	# Two frames, not one. The first only gets the curtain drawn into the
	# frame that is already being assembled; the second is the one that
	# actually reaches the screen. Blocking on the load before that happens
	# would hide the curtain behind the very freeze it exists to cover.
	await get_tree().process_frame
	await get_tree().process_frame

	for path in preload_paths:
		await _load_threaded(String(path))

	var packed := await _load_threaded(scene_path)

	if packed is PackedScene:
		get_tree().change_scene_to_packed(packed)
	else:
		# Threaded loading failed for some reason. Falling back to the blocking
		# path is worse, but a stutter beats never leaving the lobby.
		push_warning("LoadingScreen: threaded load of '%s' failed; loading it the slow way." % scene_path)
		get_tree().change_scene_to_file(scene_path)

	# change_scene_to_* frees the old scene at the end of the frame and builds
	# the new one on the next, so the expensive _ready() work has not happened
	# yet at this point. Hold on until it has run and drawn once, or the
	# curtain lifts onto the exact stutter it was covering.
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	var elapsed := (Time.get_ticks_msec() - shown_at) / 1000.0
	if elapsed < MIN_VISIBLE_TIME:
		await get_tree().create_timer(
			MIN_VISIBLE_TIME - elapsed, true, false, true).timeout

	await _fade_out()
	_busy = false


## Rebuilds the scene that is currently on screen, behind the curtain.
##
## The end-of-match overlay's "Play Again" used to call
## get_tree().reload_current_scene() directly, which tears down and rebuilds the
## arena - forty-odd props, the map, and the mini-map bake - on the main thread
## with nothing covering it. Same freeze as entering the arena the first time,
## for the same reason, so it gets the same curtain.
func reload_scene(label: String = "Loading") -> void:
	var scene := get_tree().current_scene
	if scene == null or scene.scene_file_path.is_empty():
		# Nothing on disk to reload from (a scene built in code, or a test
		# harness). Fall back rather than silently doing nothing.
		get_tree().reload_current_scene()
		return
	change_scene(scene.scene_file_path, [], label)


## Loads one resource on a worker thread, yielding a frame at a time so the
## runners keep animating. Returns null if the load failed.
func _load_threaded(path: String) -> Resource:
	if path.is_empty():
		return null
	if ResourceLoader.has_cached(path):
		return ResourceLoader.load(path)

	if ResourceLoader.load_threaded_request(path) != OK:
		return null

	while true:
		var progress: Array = []
		var status := ResourceLoader.load_threaded_get_status(path, progress)
		match status:
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				await get_tree().process_frame
			ResourceLoader.THREAD_LOAD_LOADED:
				return ResourceLoader.load_threaded_get(path)
			_:
				return null
	return null


func _fade_out() -> void:
	var tween := create_tween()
	# The result overlay drops Engine.time_scale to 0.25 for its slow-motion
	# finish. It restores it before advancing, but a dropped frame or an early
	# exit path can leave the slowdown in place for a moment - and a fade that
	# inherits it takes a second to clear instead of a quarter of one.
	tween.set_ignore_time_scale(true)
	tween.tween_property(_root, "modulate:a", 0.0, FADE_OUT_TIME)
	await tween.finished
	_set_visible(false)
	_root.modulate.a = 1.0


func _set_visible(shown: bool) -> void:
	_root.visible = shown
	if shown:
		_run_offset = 0.0
		_dot_timer = 0.0
		_dot_count = 0
		_label.text = _base_text
		_sili.play(&"run")
		_tubig.play(&"run")
	else:
		_sili.stop()
		_tubig.stop()


func _process(delta: float) -> void:
	if _root == null or not _root.visible:
		return

	# One offset drives both runners; the Tubig is just the same position plus
	# a constant lead, which is what keeps the gap between them fixed.
	var loop_width := RUNWAY.x + FRAME_SIZE.x * SPRITE_SCALE * 2.0
	_run_offset = fmod(_run_offset + RUN_SPEED_PX * delta, loop_width)
	var margin := FRAME_SIZE.x * SPRITE_SCALE
	_sili.position.x = -margin + _run_offset
	_tubig.position.x = -margin + fmod(_run_offset + TUBIG_LEAD, loop_width)

	_dot_timer += delta
	if _dot_timer >= DOT_INTERVAL:
		_dot_timer = 0.0
		_dot_count = (_dot_count + 1) % 4
		_label.text = _base_text + ".".repeat(_dot_count)


# --- Construction ---------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Swallows clicks. Without this a stray press can still reach the lobby's
	# Start button underneath and fire a second round load mid-transition.
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.0, 0.0, 0.0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	var centre := CenterContainer.new()
	centre.name = "Centre"
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(centre)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 4)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(column)

	# A plain Control, sized but empty: it exists to reserve the strip the two
	# Node2D runners move across. Node2Ds are not laid out by containers, so
	# without something holding the space the label would sit where they are.
	var runway := Control.new()
	runway.name = "Runway"
	runway.custom_minimum_size = RUNWAY
	runway.clip_contents = true
	runway.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(runway)

	_sili = _make_runner(SILI_SHEET)
	_sili.name = "SiliRunner"
	runway.add_child(_sili)

	_tubig = _make_runner(TUBIG_SHEET)
	_tubig.name = "TubigRunner"
	runway.add_child(_tubig)

	_label = Label.new()
	_label.name = "LoadingLabel"
	_label.text = _base_text
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Fixed width so the growing dots don't shove the word left and right.
	_label.custom_minimum_size = Vector2(RUNWAY.x, 0)
	_label.add_theme_font_size_override("font_size", 28)
	_label.add_theme_color_override("font_color", TEXT_COLOR)
	column.add_child(_label)


func _make_runner(sheet_path: String) -> AnimatedSprite2D:
	var sprite := AnimatedSprite2D.new()
	sprite.sprite_frames = _build_run_frames(sheet_path)
	sprite.animation = &"run"
	sprite.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE)
	sprite.position = Vector2(0.0, RUNWAY.y * 0.5)
	return sprite


## Builds a one-animation SpriteFrames out of the character sheet, slicing the
## same regions sili.tscn and tubig.tscn use for "run_e".
func _build_run_frames(sheet_path: String) -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.add_animation(&"run")
	frames.set_animation_speed(&"run", RUN_FPS)
	frames.set_animation_loop(&"run", true)

	var sheet := load(sheet_path) as Texture2D
	if sheet == null:
		push_warning("LoadingScreen: could not load '%s'." % sheet_path)
		return frames

	for origin in RUN_FRAME_ORIGINS:
		var region := AtlasTexture.new()
		region.atlas = sheet
		region.region = Rect2(origin, FRAME_SIZE)
		frames.add_frame(&"run", region)

	return frames
