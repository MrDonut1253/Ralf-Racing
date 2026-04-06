extends Node

@onready var code_input: LineEdit = $Buttons.get_node_or_null("IPAddress")
@onready var status_label: Label = $Buttons.get_node_or_null("StatusLabel")
@onready var name_input: LineEdit = $Buttons.get_node_or_null("NameInput")

func _ready():
	if not NetworkManager.status_update.is_connected(_on_status_update):
		NetworkManager.status_update.connect(_on_status_update)

	if name_input: name_input.text = NetworkManager.my_local_name
	if code_input: code_input.text = ""

func _on_status_update(message):
	if status_label: status_label.text = message

func _save_name():
	if name_input and name_input.text.strip_edges() != "":
		NetworkManager.my_local_name = name_input.text.strip_edges()
	else:
		NetworkManager.my_local_name = "Racer " + str(randi() % 1000)

func _set_ui_disabled(val: bool):
	var buttons_node = $Buttons
	if not buttons_node: return
	for child in buttons_node.get_children():
		if child is Button: child.disabled = val
		if child is LineEdit: child.editable = not val
		if child.get_child_count() > 0:
			for sub in child.get_children():
				if sub is Button: sub.disabled = val
				if sub is LineEdit: sub.editable = not val

func on_host_pressed() -> void:
	_set_ui_disabled(true)
	_save_name()
	var code = await NetworkManager.host_game()
	if code:
		if code_input: code_input.text = code
		get_tree().change_scene_to_file("res://levels/lobby.tscn")
	else:
		_set_ui_disabled(false)
		# Status wurde schon vom NetworkManager gesetzt

func on_join_pressed() -> void:
	var code = ""
	if code_input: code = code_input.text.strip_edges()
	if code == "":
		if status_label: status_label.text = "Code fehlt!"
		return

	_set_ui_disabled(true)
	_save_name()

	var success = await NetworkManager.join_game(code)
	if not success:
		# Timeout/Fehler wurde schon vom NetworkManager behandelt
		_set_ui_disabled(false)

func on_exit_button_pressed() -> void:
	NetworkManager.reset_network()
	get_tree().quit()
