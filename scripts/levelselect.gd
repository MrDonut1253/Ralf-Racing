#levelselect.gd
extends Node
@onready var audio_ralf: AudioStreamPlayer2D = $audio_ralf

func _ready() -> void:
	audio_ralf.play()

func _process(_delta: float) -> void:
	if Input.is_action_pressed("exit"):
		get_tree().change_scene_to_file("res://levels/menu.tscn")

func _load_level(level_number: int) -> void:
	get_tree().change_scene_to_file("res://levels/level%02d.tscn" % level_number)

func on_level_01_button_down() -> void:
	_load_level(1)

func on_level_02_button_down() -> void:
	_load_level(2)

func on_level_03_button_down() -> void:
	_load_level(3)

func on_level_04_button_down() -> void:
	_load_level(4)
