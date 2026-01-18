#start.gd
extends Node

# UI REFERENZEN
@onready var code_input: LineEdit = $Buttons.get_node_or_null("IPAddress") 
@onready var status_label: Label = $Buttons.get_node_or_null("StatusLabel")
@onready var name_input: LineEdit = $Buttons.get_node_or_null("NameInput")

func _ready():
	if not NetworkManager.status_update.is_connected(_on_status_update):
		NetworkManager.status_update.connect(_on_status_update)
	
	if name_input:
		name_input.text = ""
		name_input.placeholder_text = "Name eingeben"
	
	if code_input:
		code_input.placeholder_text = "Code eingeben..."
		code_input.text = ""

func _on_status_update(message):
	if status_label:
		status_label.text = message

func _save_name():
	if name_input and name_input.text.strip_edges() != "":
		NetworkManager.my_local_name = name_input.text.strip_edges()
	else:
		NetworkManager.my_local_name = "Ralf Racer"

func _set_ui_disabled(val: bool):
	var buttons_node = $Buttons
	if not buttons_node: return
	
	for child in buttons_node.get_children():
		if child is Button: child.disabled = val
		if child is LineEdit: child.editable = not val
		# Unter-Container
		if child.get_child_count() > 0:
			for sub in child.get_children():
				if sub is Button: sub.disabled = val
				if sub is LineEdit: sub.editable = not val

# --- BUTTON ACTIONS ---

func on_host_pressed() -> void:
	_set_ui_disabled(true)
	_save_name()
	
	var code = await NetworkManager.host_game()
	
	if not is_inside_tree(): return 

	if code:
		if code_input: code_input.text = code
		get_tree().change_scene_to_file("res://levels/lobby.tscn")
	else:
		_set_ui_disabled(false)
		if status_label: status_label.text = "Hosting fehlgeschlagen (Timeout)."

func on_join_pressed() -> void:
	var code = ""
	if code_input: code = code_input.text.strip_edges()
	
	if code == "":
		if status_label: status_label.text = "Bitte Code eingeben!"
		return
	
	_set_ui_disabled(true)
	_save_name()
	
	await NetworkManager.join_game(code)
	
	if not is_inside_tree(): return 

	_set_ui_disabled(false)

func on_exit_button_pressed() -> void:
	NetworkManager.reset_network()
	get_tree().quit()
