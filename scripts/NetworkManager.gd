extends Node

const TubeClientClass = preload("res://addons/tube/tube_client.gd")
const TubeContextClass = preload("res://addons/tube/tube_context.gd")

# --- SIGNALE (Wie 0.4) ---
signal status_update(message)
signal ping_updated(value_ms)
signal lobby_updated        
signal lobby_state_changed  

# --- DATEN ---
var players = {}
var current_tube_session = null
var ping_timer := 0.0
const PING_INTERVAL := 1.0

var my_local_name: String = "Player"
var current_lobby_code: String = ""
var current_map_index = 0

# Deine Maps aus 0.5 (behalten wir, das sind nur Daten)
var maps = [
	{ "name": "Rapid Raceway", "scene_path": "res://levels/level01.tscn", "preview_path": "res://assets/PNG/level01.png" },
	{ "name": "Crazy Circuit", "scene_path": "res://levels/level02.tscn", "preview_path": "res://assets/PNG/level02.png" },
	{ "name": "Speedy Strip", "scene_path": "res://levels/level03.tscn", "preview_path": "res://assets/PNG/level03.png" },
	{ "name": "Turbo Track", "scene_path": "res://levels/level04.tscn", "preview_path": "res://assets/PNG/level04.png" }
]

const MY_APP_ID = "ralf_racing_fix" # Neue ID für frischen Start

func _ready():
	set_process(true)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _process(delta):
	if not multiplayer.has_multiplayer_peer(): return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED: return
	if multiplayer.is_server(): return

	ping_timer += delta
	if ping_timer >= PING_INTERVAL:
		ping_timer = 0.0
		request_ping()

# --- DISCONNECT LOGIK (0.4) ---
func _on_server_disconnected():
	reset_network()
	status_update.emit("Verbindung verloren.")
	get_tree().change_scene_to_file.call_deferred("res://levels/menu.tscn")

@rpc("authority", "call_remote", "reliable")
func kicked_by_host():
	reset_network()
	status_update.emit("Host hat Lobby geschlossen.")
	get_tree().change_scene_to_file("res://levels/menu.tscn")

func reset_network():
	_reset_session()
	status_update.emit("Netzwerk zurückgesetzt.")

# --- HOSTING (Logik 0.4) ---
func host_game():
	_reset_session()
	status_update.emit("Starte Host...")
	
	var tube = _create_tube()
	if not tube: return null 

	tube.create_session()
	_fix_signals()
	
	# Warten wie in 0.4 (stabil)
	await tube.session_created
	
	var key = tube.session_id
	if key:
		current_lobby_code = key
		add_player(1)
		players[1]["name"] = my_local_name
		return key
	return null

# --- JOINING (Logik 0.4) ---
func join_game(code):
	_reset_session()
	status_update.emit("Verbinde...")
	
	var tube = _create_tube()
	if not tube: return
	
	code = code.strip_edges().to_upper()
	current_lobby_code = code
	
	tube.join_session(code)
	_fix_signals()
	
	await tube.session_joined
	
	status_update.emit("Verbunden! Gehe zur Lobby...")
	send_player_info.rpc(my_local_name)
	get_tree().change_scene_to_file("res://levels/lobby.tscn")

# --- HELFER ---
func _fix_signals():
	var mp = get_tree().get_multiplayer()
	if mp.peer_connected.is_connected(_on_player_connected): mp.peer_connected.disconnect(_on_player_connected)
	if mp.peer_disconnected.is_connected(_on_player_disconnected): mp.peer_disconnected.disconnect(_on_player_disconnected)
	mp.peer_connected.connect(_on_player_connected)
	mp.peer_disconnected.connect(_on_player_disconnected)

func _create_tube():
	var tube = TubeClientClass.new()
	var context = TubeContextClass.new() 
	
	context.app_id = MY_APP_ID
	context.session_id_characters_set = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	
	# LISTE UPDATE (Wichtig für Connectivity, aber Struktur 0.4)
	var my_stun: Array[String] = [
		"stun:stun.l.google.com:19302",
		"stun:stun1.l.google.com:19302",
        "stun:global.stun.twilio.com:3478?transport=udp"
	]
	context.stun_servers_urls = my_stun
	
	var my_trackers: Array[String] = [
		"wss://tracker.webtorrent.dev",
		"wss://tracker.openwebtorrent.com",
		"wss://tracker.files.fm:7073/announce",
		"wss://tracker.btorrent.xyz",
        "wss://tracker.sloppyta.co:443/"
	]
	context.trackers_urls = my_trackers
	
	if not context.is_valid():
		return null

	tube.context = context
	add_child(tube)
	current_tube_session = tube
	return tube

func _reset_session():
	if current_tube_session: 
		current_tube_session.queue_free()
		current_tube_session = null
	if get_tree().get_multiplayer().has_multiplayer_peer():
		get_tree().get_multiplayer().multiplayer_peer = null
	players.clear()
	current_lobby_code = ""

# --- EVENT HANDLER ---
func _on_player_connected(id):
	add_player(id)
	send_player_info.rpc_id(id, my_local_name)
	if multiplayer.is_server():
		sync_lobby_state.rpc_id(id, current_map_index)
	lobby_updated.emit()

func _on_player_disconnected(id):
	if players.has(id): players.erase(id)
	lobby_updated.emit()

func add_player(id):
	if not players.has(id): 
		players[id] = { "name": "Racer " + str(id) }
		lobby_updated.emit()

# --- RPCs (Standard 0.4) ---
func request_ping():
	_server_receive_ping.rpc_id(1, Time.get_ticks_msec())

@rpc("any_peer", "call_remote", "unreliable")
func _server_receive_ping(client_time):
	var sender_id = multiplayer.get_remote_sender_id()
	_client_receive_pong.rpc_id(sender_id, client_time)

@rpc("authority", "call_remote", "unreliable")
func _client_receive_pong(client_time):
	ping_updated.emit(Time.get_ticks_msec() - client_time)

@rpc("any_peer", "call_local", "reliable")
func send_player_info(name_str):
	var sender_id = multiplayer.get_remote_sender_id()
	# Validierung: Name kürzen und bereinigen
	var safe_name = str(name_str).strip_edges()
	if safe_name.length() > 20:
		safe_name = safe_name.substr(0, 20)
	if safe_name == "":
		safe_name = "Racer " + str(sender_id)
	add_player(sender_id)
	players[sender_id]["name"] = safe_name
	lobby_updated.emit()

@rpc("authority", "call_local", "reliable")
func sync_lobby_state(new_index):
	# Bounds-Check gegen Array-Grenzen
	if new_index < 0 or new_index >= maps.size():
		return
	current_map_index = new_index
	lobby_state_changed.emit()

@rpc("authority", "call_local", "reliable")
func start_game():
	if current_map_index < 0 or current_map_index >= maps.size():
		return
	var map_data = maps[current_map_index]
	get_tree().change_scene_to_file(map_data["scene_path"])

@rpc("authority", "call_local", "reliable")
func return_to_lobby():
	get_tree().change_scene_to_file("res://levels/lobby.tscn")
