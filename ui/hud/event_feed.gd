extends VBoxContainer

## Bottom-right match feed: "Sili tagged Ana", "Ben rescued Ana", speed-up
## warnings. Replaces the notices that used to be glued onto the timer label,
## which had to fight the clock for space and could only ever show a status,
## never an event.
##
## Entries fade on a timer and the oldest is pushed out once there are more than
## MAX_ENTRIES, so a busy moment can't grow the list off the top of the screen.
##
## Listens to MatchManager rather than to players directly: characters spawn and
## despawn constantly, and a tag has to appear on every screen, not just on the
## screen of whoever's client detected it.

const MAX_ENTRIES := 5
const HOLD_TIME := 5.0
const FADE_TIME := 1.5
const ENTRY_FONT_SIZE := 15

const COLOR_TAG := Color(1.0, 0.48, 0.42)
const COLOR_RESCUE := Color(0.52, 0.88, 0.62)
const COLOR_WARNING := Color(1.0, 0.82, 0.36)
const COLOR_NEUTRAL := Color(0.86, 0.88, 0.92)
## Fountain lines - refills and the buff each drink rolled. Its own colour
## because a buff is neither a warning nor a rescue, and the whole point of the
## feed is that you can tell what happened from the colour before you read it.
const COLOR_BUFF := Color(0.45, 0.85, 0.95)


func _ready() -> void:
	alignment = BoxContainer.ALIGNMENT_END
	add_theme_constant_override("separation", 4)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	MatchManager.event_logged.connect(_on_event_logged)
	MatchManager.sili_speed_changed.connect(_on_sili_speed_changed)
	MatchManager.rescues_locked.connect(_on_rescues_locked)


func _on_event_logged(message: String, kind: String) -> void:
	var color := COLOR_NEUTRAL
	match kind:
		"tag":
			color = COLOR_TAG
		"rescue":
			color = COLOR_RESCUE
		"warning":
			color = COLOR_WARNING
		"buff":
			color = COLOR_BUFF
	push_entry(message, color)


## Stage 0 is the match's starting speed, so there's nothing to announce.
func _on_sili_speed_changed(multiplier: float, stage: int) -> void:
	if stage <= 0:
		return
	push_entry("Sili is faster  (+%d%%)" % roundi((multiplier - 1.0) * 100.0), COLOR_WARNING)


func _on_rescues_locked() -> void:
	push_entry("Rescues are locked", COLOR_WARNING)


func push_entry(message: String, color: Color) -> void:
	var label := Label.new()
	label.text = message
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.add_theme_font_size_override("font_size", ENTRY_FONT_SIZE)
	label.add_theme_color_override("font_color", color)
	# Outline instead of a panel background: the feed sits over the tilemap, and
	# these have to stay readable against both bright sand and dark buildings.
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 5)
	add_child(label)

	# Newest at the bottom, nearest the corner, so your eye lands on the most
	# recent line first.
	_trim_to_limit()

	var tween := create_tween()
	tween.tween_interval(HOLD_TIME)
	tween.tween_property(label, "modulate:a", 0.0, FADE_TIME)
	tween.tween_callback(label.queue_free)


## Drops the oldest lines immediately when the feed overflows, rather than
## waiting for them to finish fading - during a scramble the fades would
## otherwise queue up and the list would keep growing.
func _trim_to_limit() -> void:
	while get_child_count() > MAX_ENTRIES:
		var oldest := get_child(0)
		remove_child(oldest)
		oldest.queue_free()
