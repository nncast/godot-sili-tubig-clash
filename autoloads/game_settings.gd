extends Node

## Autoload. Owns the persisted audio settings so they apply at boot
## (not just while the settings screen happens to be open).

const SETTINGS_PATH := "user://settings.cfg"
const MIN_DB := -80.0

## Defaults for a first launch. These are a deliberate mix, not four sliders
## parked at 100%: this is a hide-and-seek game where the footsteps ARE the
## information, so the gameplay layer sits loudest and everything else is
## trimmed to stay out of its way.
##
##   Master   100%  the baseline the player pulls down if they need to
##   Music     50%  atmosphere present, never competing with a footstep
##   SFX       80%  tags, rescues, tunnels, footsteps - the cues that matter
##   Ambience  40%  sells the beach without masking anything above it
const DEFAULT_MASTER := 1.0
const DEFAULT_MUSIC := 0.5
const DEFAULT_SFX := 0.8
const DEFAULT_AMBIENCE := 0.4

var master_volume: float = DEFAULT_MASTER
var music_volume: float = DEFAULT_MUSIC
var sfx_volume: float = DEFAULT_SFX
## Ambience (the ocean loop) rides on its own bus under SFX, so this trims the
## waves without touching footsteps or UI blips.
var ambience_volume: float = DEFAULT_AMBIENCE


func _ready() -> void:
	load_settings()


func load_settings() -> void:
	var config := ConfigFile.new()
	var err := config.load(SETTINGS_PATH)
	if err == OK:
		master_volume = config.get_value("audio", "master", DEFAULT_MASTER)
		music_volume = config.get_value("audio", "music", DEFAULT_MUSIC)
		sfx_volume = config.get_value("audio", "sfx", DEFAULT_SFX)
		# Ambience was written by save_settings() but never read back, so the
		# slider reset to full every launch while the file quietly held the
		# player's real choice.
		ambience_volume = config.get_value("audio", "ambience", DEFAULT_AMBIENCE)
	_apply_bus("Master", master_volume)
	_apply_bus("Music", music_volume)
	_apply_bus("SFX", sfx_volume)
	_apply_bus("Ambience", ambience_volume)


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("audio", "master", master_volume)
	config.set_value("audio", "music", music_volume)
	config.set_value("audio", "sfx", sfx_volume)
	config.set_value("audio", "ambience", ambience_volume)
	config.save(SETTINGS_PATH)


func set_master_volume(value: float) -> void:
	master_volume = value
	_apply_bus("Master", value)
	save_settings()


func set_music_volume(value: float) -> void:
	music_volume = value
	_apply_bus("Music", value)
	save_settings()


func set_sfx_volume(value: float) -> void:
	sfx_volume = value
	_apply_bus("SFX", value)
	save_settings()


func set_ambience_volume(value: float) -> void:
	ambience_volume = value
	_apply_bus("Ambience", value)
	save_settings()


func _apply_bus(bus_name: String, linear_value: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	var db: float = linear_to_db(linear_value) if linear_value > 0.0 else MIN_DB
	AudioServer.set_bus_volume_db(idx, db)
