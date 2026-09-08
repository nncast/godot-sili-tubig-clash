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

## Base colour for a line that carries NAMES. The names supply the colour now -
## Sili red, Tubig blue, from MatchManager - so the sentence around them stays
## plain: "Ana tagged Ben" reads red / plain / blue. Tinting the verb as well
## would fight the names for attention and make the two ends harder to pick out.
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
		# "tag" and "rescue" deliberately fall through to neutral: both name two
		# players, and those names are already coloured by role.
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


## RichTextLabel rather than Label, because a line can now be more than one
## colour: the names inside it are tinted by role while the words between them
## stay neutral. `color` is the colour of everything NOT wrapped in a tag.
func push_entry(message: String, color: Color) -> void:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	# fit_content plus a scrollbar that is off: without both, RichTextLabel
	# claims a default block of height in the VBox and the feed turns into a
	# column of gaps.
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size_flags_horizontal = Control.SIZE_SHRINK_END
	label.add_theme_font_size_override("normal_font_size", ENTRY_FONT_SIZE)
	label.add_theme_color_override("default_color", color)
	# Outline instead of a panel background: the feed sits over the tilemap, and
	# these have to stay readable against both bright sand and dark buildings.
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 5)
	# Right-aligned through BBCode: RichTextLabel has no alignment property,
	# unlike the Label this replaced.
	label.text = "[right]%s[/right]" % message
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
