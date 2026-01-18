# res://scripts/game_modes/race_mode.gd
extends Node

const TOTAL_LAPS := 3

# --- REFERENZEN ---
# Da wir dynamisch sind, suchen wir unsere Geschwister "on ready"
var game_infrastructure: Node
var hud_container: Node
var countdown_label: Label
# Wir ändern den Typ auf 2D oder lassen ihn weg (Duck Typing), um flexibel zu sein
var audio_start: Node

# --- RENNDATEN ---
var players_data: Dictionary = {}
var is_game_over := false 
var countdown_value := 4
var countdown_timer := 0.0

func _ready():
	# 1. Geschwister finden (wir sind Child von Level)
	var level = get_parent()
	game_infrastructure = level.get_node_or_null("Game")
	
	var hud = level.get_node_or_null("HUD")
	if hud:
		hud_container = hud.get_node_or_null("PlayerStatsContainer")
		countdown_label = hud.get_node_or_null("CountdownLabel")
	
	audio_start = level.get_node_or_null("audio_start")

	# 2. Initiale Einstellungen
	set_process(false) 
	_connect_checkpoints()
	_update_hud_visibility()
	
	print("RaceMode initialisiert und bereit.")

# --- RPC START ---
# WICHTIG: Das RPC muss hier definiert sein, damit game.gd es aufrufen kann
@rpc("call_local", "reliable")
func start_match():
	print("RaceMode: Start Signal erhalten!")
	is_game_over = false 
	countdown_value = 4
	countdown_timer = 0.0
	
	if audio_start: audio_start.play()
	set_process(true)

# --- LOOP ---
func _process(delta):
	if is_game_over: return

	# Wir steuern die Variable im Bruder-Node "Game"
	if game_infrastructure and not game_infrastructure.game_started:
		handle_countdown(delta)
		return

	# Zeitmessung
	for id in players_data:
		var p = players_data[id]
		if p and not p.get("finished", false):
			p["stopwatch_time"] += delta

	update_hud()

# --- LOGIK ---
func handle_countdown(delta):
	countdown_timer += delta
	if countdown_timer < 1.0: return
	
	countdown_timer = 0.0
	countdown_value -= 1
	
	if countdown_label:
		if countdown_value > 0: 
			countdown_label.text = str(countdown_value)
		else:
			countdown_label.text = "GO!"
			# INPUT FREIGABE beim Bruder
			if game_infrastructure: 
				game_infrastructure.game_started = true
			
			# Label nach 1 Sekunde leeren
			var timer = get_tree().create_timer(1.0)
			timer.timeout.connect(func(): if countdown_label: countdown_label.text = "")

# --- MAP VERBINDUNGEN ---
func _connect_checkpoints():
	# Wir suchen im Level nach Nodes, die wie Checkpoints aussehen
	var level = get_parent()
	
	# Dynamischer Ansatz: Wir suchen alle Kinder, die "Checkpoint" im Namen haben
	# Das macht es flexibel für Maps mit unterschiedlich vielen Checkpoints
	for child in level.get_children():
		if child.name.begins_with("Checkpoint"):
			if not child.body_entered.is_connected(on_checkpoint_entered):
				# Extrahiere Nummer aus Name (z.B. "Checkpoint2" -> 2)
				var num_str = child.name.replace("Checkpoint", "")
				var num = num_str.to_int()
				child.body_entered.connect(on_checkpoint_entered.bind(num))
		
		elif child.name == "StartFinish":
			if not child.body_entered.is_connected(on_start_finish_entered):
				child.body_entered.connect(on_start_finish_entered)

func on_checkpoint_entered(body, checkpoint_num):
	if not game_infrastructure or not game_infrastructure.game_started: return
	if not body: return
	
	var p = players_data.get(body.name)
	if not p: return 
	if p["next_checkpoint"] == checkpoint_num:
		p["next_checkpoint"] += 1

func on_start_finish_entered(body):
	if not game_infrastructure or not game_infrastructure.game_started: return
	if not body: return
	
	var p = players_data.get(body.name)
	if not p: return
	
	if p["next_checkpoint"] == 4: # Annahme: 3 Checkpoints + Ziel
		var lap_time = p["stopwatch_time"] - p["lap_start_time"]
		p["lap_times"].append(lap_time)
		p["lap_start_time"] = p["stopwatch_time"]
		p["completed_laps"] += 1
		p["next_checkpoint"] = 1
		
		if p["completed_laps"] >= TOTAL_LAPS:
			finish_player(body.name)

# --- SPIELER INTERFACE (wird von game.gd aufgerufen) ---
func on_player_spawned(node):
	if node is CharacterBody2D: 
		var p_idx = 0
		if "player_index" in node: p_idx = node.player_index
		
		players_data[node.name] = {
			"index": p_idx,
			"stopwatch_time": 0.0,
			"lap_start_time": 0.0,
			"completed_laps": 0,
			"lap_times": [],
			"next_checkpoint": 1,
			"finish_time": 0.0,
			"finished": false
		}

func on_player_despawned(node):
	if players_data.has(node.name): 
		players_data.erase(node.name)

# --- FINISH & HUD ---
func finish_player(id):
	if players_data.has(id):
		players_data[id]["finished"] = true
		players_data[id]["finish_time"] = players_data[id]["stopwatch_time"]
		check_game_over()

func check_game_over():
	for id in players_data:
		if not players_data[id].get("finished", false): return 
	show_game_over_screen()

func show_game_over_screen():
	if game_infrastructure: 
		game_infrastructure.game_started = false
	is_game_over = true 
	
	var results = []
	for id in players_data:
		var p_name = "Unknown"
		var id_int = int(str(id))
		if NetworkManager.players.has(id_int):
			p_name = NetworkManager.players[id_int]["name"]
		else:
			p_name = "Player " + str(players_data[id]["index"] + 1)
		results.append({ "name": p_name, "time": players_data[id]["finish_time"] })
	
	results.sort_custom(func(a, b): return a["time"] < b["time"])
	
	var text = "RACE OVER\n\n"
	if results.size() > 0: text += "WINNER: " + results[0]["name"] + "!\n"
	for i in range(results.size()):
		var entry = results[i]
		text += "%d. %s  -  %.2fs\n" % [i+1, entry["name"], entry["time"]]
	
	if countdown_label: countdown_label.text = text

	if multiplayer.is_server():
		var hud_layer = get_parent().get_node_or_null("HUD")
		if hud_layer:
			var btn = Button.new()
			btn.text = "Zurück zur Lobby"
			
			# --- SCHRIFTART & GRÖSSE ---
			# 1. Schrift laden
			if ResourceLoader.exists("res://assets/font.ttf"):
				var custom_font = load("res://assets/font.ttf")
				btn.add_theme_font_override("font", custom_font)
			
			# 2. Schriftgröße auf 50
			btn.add_theme_font_size_override("font_size", 50)
			
			# --- STYLES (Deine Farben) ---
			var style_normal = StyleBoxFlat.new()
			style_normal.bg_color = Color(0.351148, 0.434675, 0.920568, 1)
			style_normal.set_corner_radius_all(15)
			style_normal.shadow_size = 6
			style_normal.shadow_offset = Vector2(2, 2)
			
			var style_pressed = StyleBoxFlat.new()
			style_pressed.bg_color = Color(0.283102, 0.348043, 0.857779, 1)
			style_pressed.set_corner_radius_all(15)
			style_pressed.shadow_size = 2
			
			btn.add_theme_stylebox_override("normal", style_normal)
			btn.add_theme_stylebox_override("hover", style_normal)
			btn.add_theme_stylebox_override("pressed", style_pressed)
			btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new()) 
			
			# --- POSITIONIERUNG ---
			
			# Button muss jetzt größer sein, damit Schriftgröße 50 reinpasst
			btn.custom_minimum_size = Vector2(400, 80) # Breite 400, Höhe 80
			btn.size = Vector2(400, 80) 
			
			var screen_size = get_viewport().get_visible_rect().size
			
			# X: Mittig
			var pos_x = (screen_size.x / 2) - (btn.size.x / 2)
			
			# Y: Mittig + Versatz nach unten (damit er unter dem Text steht)
			var pos_y = (screen_size.y / 2) + 120 
			
			btn.position = Vector2(pos_x, pos_y)
			
			btn.pressed.connect(func(): NetworkManager.return_to_lobby.rpc())
			hud_layer.add_child(btn)

func _update_hud_visibility():
	if not hud_container: return
	for child in hud_container.get_children():
		if child is Control: child.visible = false

func update_hud():
	if not hud_container: return
	for i in range(4): 
		var panel_name = "PanelP" + str(i + 1)
		var panel = hud_container.get_node_or_null(panel_name)
		if not panel: continue

		var active_player_id = null
		for id in players_data:
			if players_data[id]["index"] == i:
				active_player_id = id
				break
		
		if active_player_id:
			panel.visible = true
			var p = players_data[active_player_id]
			var timer_lbl = panel.get_node_or_null("TimerPlayer" + str(i + 1))
			var laps_lbl = panel.get_node_or_null("RundenPlayer" + str(i + 1))
			
			if timer_lbl:
				var t = p["stopwatch_time"] - p["lap_start_time"]
				timer_lbl.text = "%.2f s" % t
			
			if laps_lbl:
				laps_lbl.text = "Laps: %d/%d" % [p["completed_laps"], TOTAL_LAPS]
		else:
			panel.visible = false
