#networkmanager.gd
extends Node

const TubeClientClass = preload("res://addons/tube/tube_client.gd")
const TubeContextClass = preload("res://addons/tube/tube_context.gd")

# --- SIGNALE ---
signal status_update(message)
signal ping_updated(value_ms)
signal lobby_updated        
signal lobby_state_changed  

# --- DATEN ---
var players = {}
var current_tube_session = null

# Ping Variablen
var ping_timer := 0.0
const PING_INTERVAL := 1.0

# SPIELER DATEN
var my_local_name: String = "Player"
var current_lobby_code: String = ""
var current_map_index = 0

# Maps Liste
var maps = [
	{
		"name": "Rapid Raceway",
		"scene_path": "res://levels/level01.tscn",
		"preview_path": "res://assets/PNG/level01.png"
	},
	{
		"name": "Crazy Ciruit",
		"scene_path": "res://levels/level02.tscn",
		"preview_path": "res://assets/PNG/level02.png"
	},
	{
		"name": "Speedy Strip",
		"scene_path": "res://levels/level03.tscn",
		"preview_path": "res://assets/PNG/level03.png"
	},
	{
		"name": "Turbo Track",
		"scene_path": "res://levels/level04.tscn",
		"preview_path": "res://assets/PNG/level04.png"
	}
]

const MY_APP_ID = "ralf_racing_001" 

func _ready():
	set_process(true)
	# Wenn der Server weg ist (Absturz etc.), müssen alle Clients raus
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _process(delta):
	if not multiplayer.has_multiplayer_peer(): return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED: return
	if multiplayer.is_server(): return

	ping_timer += delta
	if ping_timer >= PING_INTERVAL:
		ping_timer = 0.0
		request_ping()

# --- DISCONNECT HANDLER (Ungeplant) ---
func _on_server_disconnected():
	print("Verbindung verloren.")
	reset_network()
	status_update.emit("Verbindung zum Host verloren.")
	get_tree().change_scene_to_file.call_deferred("res://levels/menu.tscn")

# --- DISCONNECT HANDLER (Geplant vom Host) ---
@rpc("authority", "call_remote", "reliable")
func kicked_by_host():
	print("Host hat die Lobby geschlossen.")
	reset_network()
	status_update.emit("Host hat die Lobby geschlossen.")
	get_tree().change_scene_to_file("res://levels/menu.tscn")

# --- RESET (Öffentlich) ---
func reset_network():
	_reset_session()
	status_update.emit("Netzwerk zurückgesetzt.")

# --- HOSTING ---
func host_game():
	_reset_session()
	status_update.emit("Starte Host...")
	
	var tube = _create_tube()
	if not tube: return null 

	tube.create_session()
	_fix_signals()
	
	await tube.session_created
	
	var key = tube.session_id
	if key:
		current_lobby_code = key
		add_player(1)
		players[1]["name"] = my_local_name
		return key
	return null

# --- JOINING (CODE) ---
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

# --- INTERNE HELFER ---
func _fix_signals():
	var mp = get_tree().get_multiplayer()
	if mp.peer_connected.is_connected(_on_player_connected):
		mp.peer_connected.disconnect(_on_player_connected)
	if mp.peer_disconnected.is_connected(_on_player_disconnected):
		mp.peer_disconnected.disconnect(_on_player_disconnected)
	
	mp.peer_connected.connect(_on_player_connected)
	mp.peer_disconnected.connect(_on_player_disconnected)

func _create_tube():
	var tube = TubeClientClass.new()
	var context = TubeContextClass.new() 
	
	context.app_id = MY_APP_ID
	context.session_id_characters_set = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	
	var my_stun: Array[String] = [
		"stun:stun.l.google.com:19302",
		"stun:stun1.l.google.com:19302",
        "stun:global.stun.twilio.com:3478?transport=udp"
	]
	context.stun_servers_urls = my_stun
	
	var my_trackers: Array[String] = [
		"wss://tracker.webtorrent.dev",
		"wss://tracker.openwebtorrent.com",
        "wss://tracker.files.fm:7073/announce"
	]
	context.trackers_urls = my_trackers
	
	if not context.is_valid():
		print("FEHLER: Context ist invalid")
		return null

	tube.context = context
	add_child(tube)
	current_tube_session = tube
	return tube

func _reset_session():
	# Session zerstören
	if current_tube_session: 
		current_tube_session.queue_free()
		current_tube_session = null
		
	# Multiplayer Peer nullen
	if get_tree().get_multiplayer().has_multiplayer_peer():
		get_tree().get_multiplayer().multiplayer_peer = null
		
	players.clear()
	current_lobby_code = ""

# --- EVENT HANDLER ---
func _on_player_connected(id):
	add_player(id)
	status_update.emit("Spieler " + str(id) + " verbunden")
	
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

# --- RPCs ---
func request_ping():
	var time_now = Time.get_ticks_msec()
	_server_receive_ping.rpc_id(1, time_now)

@rpc("any_peer", "call_remote", "unreliable")
func _server_receive_ping(client_time):
	var sender_id = multiplayer.get_remote_sender_id()
	_client_receive_pong.rpc_id(sender_id, client_time)

@rpc("authority", "call_remote", "unreliable")
func _client_receive_pong(client_time):
	var rtt = Time.get_ticks_msec() - client_time
	ping_updated.emit(rtt)

@rpc("any_peer", "call_local", "reliable")
func send_player_info(name_str):
	var sender_id = multiplayer.get_remote_sender_id()
	add_player(sender_id)
	players[sender_id]["name"] = name_str
	lobby_updated.emit()

@rpc("any_peer", "call_local", "reliable")
func sync_lobby_state(new_index):
	current_map_index = new_index
	lobby_state_changed.emit()

@rpc("call_local", "reliable")
func start_game():
	var map_data = maps[current_map_index]
	var path = map_data["scene_path"]
	print("Starte Spiel auf Map: ", map_data["name"])
	get_tree().change_scene_to_file(path)
	


@rpc("any_peer", "call_local", "reliable")
func return_to_lobby():
	# Wir setzen den Status zurück, damit man in der Lobby wieder "Bereit" drücken kann
	# (Optional, je nachdem wie deine Lobby funktioniert)
	
	# Szene wechseln
	get_tree().change_scene_to_file("res://levels/lobby.tscn")
