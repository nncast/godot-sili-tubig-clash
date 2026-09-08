extends Control

## The four sliders are all authored at value = 1.0 and GameSettings now
## defaults all four to DEFAULT_VOLUME, so a fresh install shows four identical
## rows at 100%. Keeping the scene and the autoload agreeing matters more than
## it looks: _ready() overwrites the scene values from GameSettings, so any
## disagreement between the two is invisible in the editor and only shows up as
## sliders jumping the moment the screen opens.
##
## The percentage readout beside each slider exists so that "they all read the
## same" is something a player (or a judge at a demo booth) can confirm at a
## glance instead of eyeballing four handle positions.

@onready var master_slider: HSlider = $Panel/VBox/MasterRow/MasterSlider
@onready var music_slider: HSlider = $Panel/VBox/MusicRow/MusicSlider
@onready var sfx_slider: HSlider = $Panel/VBox/SFXRow/SFXSlider
@onready var ambience_slider: HSlider = $Panel/VBox/AmbienceRow/AmbienceSlider
@onready var master_value: Label = $Panel/VBox/MasterRow/MasterValue
@onready var music_value: Label = $Panel/VBox/MusicRow/MusicValue
@onready var sfx_value: Label = $Panel/VBox/SFXRow/SFXValue
@onready var ambience_value: Label = $Panel/VBox/AmbienceRow/AmbienceValue
@onready var back_button: Button = $BackButton


func _ready() -> void:
	_bind(master_slider, master_value, GameSettings.master_volume, GameSettings.set_master_volume)
	_bind(music_slider, music_value, GameSettings.music_volume, GameSettings.set_music_volume)
	_bind(sfx_slider, sfx_value, GameSettings.sfx_volume, GameSettings.set_sfx_volume)
	_bind(ambience_slider, ambience_value, GameSettings.ambience_volume, GameSettings.set_ambience_volume)

	back_button.pressed.connect(_on_back_pressed)

	# So the Ambience slider has audible waves to act on while you're setting it.
	AudioManager.start_ambience_preview()


## One helper for all four rows rather than four near-identical blocks - the
## bug this file used to have was one row (ambience) drifting out of step with
## the others, and the cheapest way to stop that recurring is to make it
## impossible to configure a row differently by accident.
func _bind(slider: HSlider, readout: Label, initial: float, apply: Callable) -> void:
	slider.value = initial
	readout.text = "%d%%" % roundi(initial * 100.0)
	slider.value_changed.connect(apply)
	slider.value_changed.connect(func(value: float):
		readout.text = "%d%%" % roundi(value * 100.0))


func _exit_tree() -> void:
	AudioManager.stop_ambience_preview()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://ui/title_screen/title_screen.tscn")
