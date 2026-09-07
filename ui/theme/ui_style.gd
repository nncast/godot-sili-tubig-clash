class_name UIStyle
extends RefCounted

## One definition of what a panel in this game looks like.
##
## The look is taken from the "How to Play" panel on the title screen, which
## was the only dialog that had a deliberate style: dark warm brown, a 3px sand
## border, and a 3px corner radius that stays crisp next to 16px pixel art
## instead of going soft like a rounded web card.
##
## Everything here is applied FROM CODE rather than by pasting a StyleBoxFlat
## into each .tscn. Five scenes were each carrying their own idea of a popup -
## the join prompt had no panel at all, the lobby was bare labels on the
## background, and the in-match settings popup used the engine default grey.
## Duplicating a stylebox five times means the sixth dialog gets it wrong, and
## changing the palette means finding all six. One file, one look.

# --- Palette ---------------------------------------------------------------

const BG          := Color(0.10196079, 0.08627451, 0.08235294, 0.9647059)
const BORDER      := Color(0.57254905, 0.44313726, 0.3764706, 1)
const BORDER_DARK := Color(0.28235295, 0.14509805, 0.12941177, 1)
const DIM         := Color(0, 0, 0, 0.6)

## Nested surfaces - a row or list inside a panel. Slightly lighter than BG so
## it reads as raised without needing a second border.
const SURFACE     := Color(0.16, 0.13, 0.12, 0.85)

const TEXT        := Color(0.93, 0.91, 0.88)
const TEXT_MUTED  := Color(0.62, 0.58, 0.55)
const GOLD        := Color(1.0, 0.824, 0.498)   # section headings, #ffd27f
const SILI        := Color(1.0, 0.353, 0.333)   # #ff5a55
const TUBIG       := Color(0.353, 0.651, 1.0)   # #5aa6ff
const DANGER      := Color(0.85, 0.35, 0.32)

const FONT_PATH := "res://game/assets/fonts/BoldPixels.ttf"

const TITLE_SIZE := 28
const BODY_SIZE  := 18
const SMALL_SIZE := 15


static func font() -> Font:
	return load(FONT_PATH)


# --- Style boxes -----------------------------------------------------------

## The dialog shell. Border radius stays at 3 on purpose; anything larger
## fights the pixel art.
static func panel_box() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = BG
	s.set_border_width_all(3)
	s.border_color = BORDER
	s.set_corner_radius_all(3)
	s.set_content_margin_all(0)
	return s


## For lists, rows and other surfaces sitting inside a panel.
static func surface_box(margin: int = 8) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = SURFACE
	s.set_corner_radius_all(3)
	s.set_content_margin_all(margin)
	return s


static func button_box(fill: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.set_border_width_all(3)
	s.border_color = border
	s.set_corner_radius_all(3)
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 7
	s.content_margin_bottom = 7
	return s


# --- Appliers --------------------------------------------------------------

## Turns any PanelContainer into a dialog shell.
static func apply_panel(panel: PanelContainer) -> void:
	if panel == null:
		return
	panel.add_theme_stylebox_override("panel", panel_box())


## Buttons get all four states, not just "normal". Leaving hover and pressed on
## the engine default is what makes a restyled button look broken the moment
## the mouse touches it.
static func apply_button(button: Button, danger: bool = false) -> void:
	if button == null:
		return
	var base: Color = BORDER_DARK if not danger else Color(0.35, 0.13, 0.12)
	var edge: Color = BORDER if not danger else DANGER

	button.add_theme_stylebox_override("normal", button_box(base, edge))
	button.add_theme_stylebox_override("hover",
		button_box(base.lightened(0.18), edge.lightened(0.25)))
	button.add_theme_stylebox_override("pressed",
		button_box(base.darkened(0.25), edge))
	button.add_theme_stylebox_override("focus", button_box(base, edge.lightened(0.4)))

	var off := button_box(base.darkened(0.35), edge.darkened(0.45))
	off.bg_color.a = 0.7
	button.add_theme_stylebox_override("disabled", off)

	button.add_theme_font_override("font", font())
	button.add_theme_font_size_override("font_size", BODY_SIZE)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_disabled_color", TEXT_MUTED)


static func apply_title(label: Label, size: int = TITLE_SIZE) -> void:
	if label == null:
		return
	label.add_theme_font_override("font", font())
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", TEXT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


static func apply_body(label: Label, size: int = BODY_SIZE, muted: bool = false) -> void:
	if label == null:
		return
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", TEXT_MUTED if muted else TEXT)


## Dark plate behind a dialog. Also swallows clicks, so a button underneath the
## dialog can't be pressed through it - the old join prompt had no dim and no
## blocker, so the title-screen buttons stayed live behind it.
static func make_dim() -> ColorRect:
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	return dim
