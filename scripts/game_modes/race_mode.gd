extends Node

const TOTAL_LAPS := 3

# Referenzen
var game_node: Node
var hud_container: Node
var players_data: Dictionary = {}

func _ready():
	game_node = get_parent()
	
	# HUD finden
	var level = game_node.get_parent() 
	if level:
		var hud = level.get_node_or_null("HUD")
		if hud:
			hud_container = hud.get_node_or_null("PlayerStatsContainer")

		_connect_checkpoints(level)
	
	_update_hud_visibility()
	set_process(true)

func reset_match():
	players_data.clear()
	for child in game_node.players_container.get_children():
		on_player_spawned(child)

func _process(delta):
	if not game_node or not game_node.game_started: return
	
	for id in players_data:
		var p = players_data[id]
		if p and not p.get("finished", false):
			p["stopwatch_time"] += delta
			
	update_hud()

# --- MAP LOGIK ---
func _connect_checkpoints(level_node):
	for child in level_node.get_children():
		if child.name.begins_with("Checkpoint"):
			if not child.body_entered.is_connected(on_checkpoint_entered):
				var num = child.name.replace("Checkpoint", "").to_int()
				child.body_entered.connect(on_checkpoint_entered.bind(num))
		elif child.name == "StartFinish":
			if not child.body_entered.is_connected(on_start_finish_entered):
				child.body_entered.connect(on_start_finish_entered)

func on_checkpoint_entered(body, checkpoint_num):
	if not game_node.game_started: return
	var p = players_data.get(body.name)
	if p and p["next_checkpoint"] == checkpoint_num:
		p["next_checkpoint"] += 1

func on_start_finish_entered(body):
	if not game_node.game_started: return
	var p = players_data.get(body.name)
	if p and p["next_checkpoint"] == 4:
		var lap_time = p["stopwatch_time"] - p["lap_start_time"]
		p["lap_times"].append(lap_time)
		p["lap_start_time"] = p["stopwatch_time"]
		p["completed_laps"] += 1
		p["next_checkpoint"] = 1
		if p["completed_laps"] >= TOTAL_LAPS:
			finish_player(body.name)

# --- DATEN MANAGEMENT ---
func on_player_spawned(node):
	if not node is CharacterBody2D: return
	var p_idx = node.player_index if "player_index" in node else 0
	players_data[node.name] = {
		"index": p_idx,
		"stopwatch_time": 0.0, "lap_start_time": 0.0,
		"completed_laps": 0, "lap_times": [],
		"next_checkpoint": 1, "finished": false, "finish_time": 0.0
	}

func on_player_despawned(node):
	if players_data.has(node.name): 
		players_data.erase(node.name)
		check_game_over()

func finish_player(id):
	if players_data.has(id):
		players_data[id]["finished"] = true
		players_data[id]["finish_time"] = players_data[id]["stopwatch_time"]
		check_game_over()

func check_game_over():
	if players_data.is_empty(): return
	for id in players_data:
		if not players_data[id].get("finished", false): return
	show_game_over_screen()

func show_game_over_screen():
	game_node.game_started = false
	
	var results = []
	for id in players_data:
		var p_name = _get_player_name(id)
		results.append({ "name": p_name, "time": players_data[id]["finish_time"] })
	
	results.sort_custom(func(a, b): return a["time"] < b["time"])
	
	var text = "RACE OVER\n\n"
	if results.size() > 0: text += "WINNER: " + results[0]["name"] + "!\n"
	for i in range(results.size()):
		text += "%d. %s  -  %.2fs\n" % [i+1, results[i]["name"], results[i]["time"]]
	
	if game_node.countdown_label:
		game_node.countdown_label.text = text

	if multiplayer.is_server():
		_spawn_lobby_button()

func _spawn_lobby_button():
	var level = game_node.get_parent()
	var hud_layer = level.get_node_or_null("HUD")
	if hud_layer:
		var btn = Button.new()
		btn.text = "Zurück zur Lobby"
		btn.custom_minimum_size = Vector2(300, 60)
		btn.size = Vector2(300, 60)
		var viewport_size = get_viewport().get_visible_rect().size
		btn.position = Vector2((viewport_size.x / 2) - 150, (viewport_size.y / 2) + 150)
		btn.pressed.connect(func(): NetworkManager.return_to_lobby.rpc())
		hud_layer.add_child(btn)

func _update_hud_visibility():
	if not hud_container: return
	for child in hud_container.get_children(): child.visible = false

# --- HUD UPDATE (MIT NAMEN!) ---
func update_hud():
	if not hud_container: return
	for i in range(4): 
		var panel = hud_container.get_node_or_null("PanelP" + str(i + 1))
		if not panel: continue
		
		var active_id = null
		for id in players_data:
			if players_data[id]["index"] == i:
				active_id = id
				break
		
		if active_id:
			panel.visible = true
			var p = players_data[active_id]
			var t_lbl = panel.get_node_or_null("TimerPlayer" + str(i+1))
			var l_lbl = panel.get_node_or_null("RundenPlayer" + str(i+1))
			
			if t_lbl:
				var t = p["stopwatch_time"] - p["lap_start_time"]
				
				# --- WIEDERHERGESTELLT: NAMENSANZEIGE ---
				var display_name = _get_player_name(active_id)
				# Kürzen, falls zu lang
				if display_name.length() > 10: 
					display_name = display_name.substr(0, 10) + "."
				
				# Anzeigeformat: Name oben, Zeit unten
				t_lbl.text = "%s:\n%.2f s" % [display_name, t]
				# ----------------------------------------
			
			if l_lbl: 
				l_lbl.text = "Laps: %d/%d" % [p["completed_laps"], TOTAL_LAPS]
		else:
			panel.visible = false

# Kleiner Helfer, um Namen sicher zu holen
func _get_player_name(id_str):
	var id_int = int(str(id_str))
	if NetworkManager.players.has(id_int):
		return NetworkManager.players[id_int]["name"]
	else:
		# Fallback falls Name noch nicht gesynct
		var p_idx = 0
		if players_data.has(id_str): p_idx = players_data[id_str]["index"]
		return "Player " + str(p_idx + 1)
