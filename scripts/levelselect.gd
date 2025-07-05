extends Node
@onready var audio_ralf: AudioStreamPlayer2D = $audio_ralf

func _ready() -> void:
	audio_ralf.play()

func _process(_delta: float) -> void:
	if Input.is_action_pressed("exit"):
		get_tree().change_scene_to_file("res://levels/menu.tscn")

func on_level_01_button_down() -> void:
	get_tree().change_scene_to_file("res://levels/level01.tscn")

func on_level_02_button_down() -> void:
	get_tree().change_scene_to_file("res://levels/level02.tscn")

func on_level_03_button_down() -> void:
	get_tree().change_scene_to_file("res://levels/level03.tscn")

func on_level_04_button_down() -> void:
	get_tree().change_scene_to_file("res://levels/level04.tscn")
