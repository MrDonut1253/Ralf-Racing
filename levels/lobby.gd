extends Control

# --- NODES REFERENZEN (Basierend auf deinem Bild) ---
@onready var code_label = $CenterContainer/VBoxContainer/CodeLabel 

# Pfad angepasst an deinen Screenshot: MapPreview -> MapImage
@onready var map_image_rect = $CenterContainer/VBoxContainer/MapSelector/MapInfoBox/MapPreview/MapImage
@onready var map_label = $CenterContainer/VBoxContainer/MapSelector/MapInfoBox/MapNameLabel

@onready var player_list_label = $CenterContainer/VBoxContainer/PlayerListLabel

# --- BUTTONS ---
@onready var start_button = %StartButton 
@onready var exit_button = $ExitButton 

@onready var prev_btn = $CenterContainer/VBoxContainer/MapSelector/PrevButton
@onready var next_btn = $CenterContainer/VBoxContainer/MapSelector/NextButton

func _ready():
	_update_ui()
	
	# Signale verbinden
	if not NetworkManager.lobby_state_changed.is_connected(_update_ui):
		NetworkManager.lobby_state_changed.connect(_update_ui)
		
	if not NetworkManager.lobby_updated.is_connected(_on_lobby_updated):
		NetworkManager.lobby_updated.connect(_on_lobby_updated)
	
	if exit_button:
		if not exit_button.pressed.is_connected(on_exit_button_pressed):
			exit_button.pressed.connect(on_exit_button_pressed)
			
	# Buttons verbinden (falls noch nicht im Editor geschehen)
	if prev_btn and not prev_btn.pressed.is_connected(_on_prev_button_pressed):
		prev_btn.pressed.connect(_on_prev_button_pressed)
	if next_btn and not next_btn.pressed.is_connected(_on_next_button_pressed):
		next_btn.pressed.connect(_on_next_button_pressed)
	if start_button and not start_button.pressed.is_connected(_on_start_button_pressed):
		start_button.pressed.connect(_on_start_button_pressed)
	
	# Code anzeigen
	if code_label:
		if NetworkManager.current_lobby_code != "":
			code_label.text = "LOBBY CODE: " + NetworkManager.current_lobby_code
		else:
			code_label.text = "Warte auf Code..."

func _process(_delta):
	var is_host = multiplayer.is_server()
	if start_button: start_button.visible = is_host
	if prev_btn: prev_btn.visible = is_host
	if next_btn: next_btn.visible = is_host

# --- LOGIK ---

func _on_lobby_updated():
	_update_player_list()

func _on_prev_button_pressed():
	if not multiplayer.is_server(): return
	var map_count = NetworkManager.maps.size()
	if map_count == 0: return
	var new_index = (NetworkManager.current_map_index - 1 + map_count) % map_count
	NetworkManager.sync_lobby_state.rpc(new_index)

func _on_next_button_pressed():
	if not multiplayer.is_server(): return
	var map_count = NetworkManager.maps.size()
	if map_count == 0: return
	var new_index = (NetworkManager.current_map_index + 1) % map_count
	NetworkManager.sync_lobby_state.rpc(new_index)

func _on_start_button_pressed():
	if not multiplayer.is_server(): return
	NetworkManager.start_game.rpc()

func on_exit_button_pressed() -> void:
	if multiplayer.is_server():
		NetworkManager.kicked_by_host.rpc()
		await get_tree().create_timer(0.1).timeout
	NetworkManager.reset_network()
	get_tree().change_scene_to_file("res://levels/menu.tscn")

# --- UI UPDATES ---

func _update_ui():
	if NetworkManager.maps.size() == 0:
		if map_label: map_label.text = "Keine Maps!"
		return

	var current_map = NetworkManager.maps[NetworkManager.current_map_index]
	
	# Name setzen
	if map_label:
		map_label.text = "Map: " + current_map["name"]
	
	# BILD LADEN (Hier wird jetzt das TextureRect angesprochen)
	if map_image_rect:
		var path = current_map.get("preview_path", "")
		if path != "" and ResourceLoader.exists(path):
			map_image_rect.texture = load(path)
		else:
			map_image_rect.texture = null

	_update_player_list()

func _update_player_list():
	var text = "SPIELER:\n"
	for id in NetworkManager.players:
		var p = NetworkManager.players[id]
		var p_name = p.get("name", "Unbekannt")
		text += "- " + p_name 
		if id == 1: text += " (HOST)"
		text += "\n"
	
	if player_list_label:
		player_list_label.text = text
