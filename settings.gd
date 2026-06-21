extends Node
## Global game settings (autoloaded as `Settings`), persisted to user://.

const PATH := "user://settings.cfg"

var master_volume := 0.85       # 0..1
var mouse_sensitivity := 0.0025
var difficulty := 1             # 0 easy, 1 normal, 2 hard
var quality := 2                # 0 low, 1 medium, 2 high (forest fog/grass/trees)

func _ready() -> void:
	load_settings()
	apply_audio()

func apply_audio() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(clampf(master_volume, 0.0001, 1.0)))

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("input", "mouse_sensitivity", mouse_sensitivity)
	cfg.set_value("game", "difficulty", difficulty)
	cfg.set_value("game", "quality", quality)
	cfg.save(PATH)

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	master_volume = cfg.get_value("audio", "master_volume", master_volume)
	mouse_sensitivity = cfg.get_value("input", "mouse_sensitivity", mouse_sensitivity)
	difficulty = cfg.get_value("game", "difficulty", difficulty)
	quality = cfg.get_value("game", "quality", quality)
