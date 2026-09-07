extends Control

@onready var master_slider: HSlider = $Panel/VBox/MasterRow/MasterSlider
@onready var music_slider: HSlider = $Panel/VBox/MusicRow/MusicSlider
@onready var sfx_slider: HSlider = $Panel/VBox/SFXRow/SFXSlider
@onready var ambience_slider: HSlider = $Panel/VBox/AmbienceRow/AmbienceSlider
@onready var back_button: Button = $BackButton


func _ready() -> void:
	master_slider.value = GameSettings.master_volume
	music_slider.value = GameSettings.music_volume
	sfx_slider.value = GameSettings.sfx_volume
	ambience_slider.value = GameSettings.ambience_volume

	master_slider.value_changed.connect(GameSettings.set_master_volume)
	music_slider.value_changed.connect(GameSettings.set_music_volume)
	sfx_slider.value_changed.connect(GameSettings.set_sfx_volume)
	ambience_slider.value_changed.connect(GameSettings.set_ambience_volume)
	back_button.pressed.connect(_on_back_pressed)

	# So the Ambience slider has audible waves to act on while you're setting it.
	AudioManager.start_ambience_preview()


func _exit_tree() -> void:
	AudioManager.stop_ambience_preview()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://ui/title_screen/title_screen.tscn")
