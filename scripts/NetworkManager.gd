extends Node

const TubeClientClass = preload("res://addons/tube/tube_client.gd")
const TubeContextClass = preload("res://addons/tube/tube_context.gd")

# --- SIGNALE ---
signal status_update(message)
signal ping_updated(value_ms)
signal lobby_updated
signal lobby_state_changed
signal connection_failed(reason)

# --- KONFIGURATION ---
const MY_APP_ID = "ralf_racing_v1"
const CONNECTION_TIMEOUT := 15.0
const PING_INTERVAL := 1.0
const MAX_PLAYERS := 4

# --- DATEN ---
var players = {}
var current_tube_session: Node = null
var ping_timer := 0.0
var my_local_name: String = "Player"
var current_lobby_code: String = ""
var current_map_index := 0
var is_in_game := false

var maps = [
	{ "name": "Rapid Raceway", "scene_path": "res://levels/level01.tscn", "preview_path": "res://assets/PNG/level01.png" },
	{ "name": "Crazy Circuit", "scene_path": "res://levels/level02.tscn", "preview_path": "res://assets/PNG/level02.png" },
	{ "name": "Speedy Strip", "scene_path": "res://levels/level03.tscn", "preview_path": "res://assets/PNG/level03.png" },
	{ "name": "Turbo Track", "scene_path": "res://levels/level04.tscn", "preview_path": "res://assets/PNG/level04.png" }
]

# --- STUN/TRACKER Server ---
var stun_servers: Array[String] = [
	"stun:stun.l.google.com:19302",
	"stun:stun1.l.google.com:19302",
	"stun:stun2.l.google.com:19302",
	"stun:global.stun.twilio.com:3478?transport=udp"
]

var tracker_servers: Array[String] = [
	"wss://tracker.webtorrent.dev",
	"wss://tracker.openwebtorrent.com",
	"wss://tracker.files.fm:7073/announce",
]

# --- LIFECYCLE ---
func _ready():
	set_process(true)
	_connect_multiplayer_signals()

func _connect_multiplayer_signals():
	var mp = get_tree().get_multiplayer()
	if not mp.server_disconnected.is_connected(_on_server_disconnected):
		mp.server_disconnected.connect(_on_server_disconnected)
	if not mp.peer_connected.is_connected(_on_player_connected):
		mp.peer_connected.connect(_on_player_connected)
	if not mp.peer_disconnected.is_connected(_on_player_disconnected):
		mp.peer_disconnected.connect(_on_player_disconnected)

func _process(delta):
	if not multiplayer.has_multiplayer_peer(): return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED: return
	if multiplayer.is_server(): return

	ping_timer += delta
	if ping_timer >= PING_INTERVAL:
		ping_timer = 0.0
		request_ping()

# --- DISCONNECT ---
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
	is_in_game = false
	_reset_session()
	status_update.emit("Netzwerk zurückgesetzt.")

# --- HOSTING ---
func host_game():
	_reset_session()
	status_update.emit("Starte Host...")

	var tube = _create_tube()
	if not tube:
		status_update.emit("Fehler: Netzwerk konnte nicht initialisiert werden.")
		connection_failed.emit("tube_creation_failed")
		return null

	# Error-Handler verbinden BEVOR session erstellt wird
	var error_occurred := false
	var error_handler = func(code, msg):
		error_occurred = true
		status_update.emit("Fehler: " + msg)

	tube.error_raised.connect(error_handler)
	tube.create_session()

	# Timeout: Warten auf session_created ODER Fehler ODER Timeout
	var timeout_timer = get_tree().create_timer(CONNECTION_TIMEOUT)
	var result = await _await_with_timeout(tube.session_created, timeout_timer)

	if error_occurred:
		_reset_session()
		connection_failed.emit("session_error")
		return null

	if not result:
		status_update.emit("Timeout: Server konnte nicht erstellt werden.")
		_reset_session()
		connection_failed.emit("timeout")
		return null

	var key = tube.session_id
	if key:
		current_lobby_code = key
		add_player(1)
		players[1]["name"] = my_local_name
		status_update.emit("Lobby erstellt: " + key)
		return key

	_reset_session()
	return null

# --- JOINING ---
func join_game(code):
	_reset_session()
	status_update.emit("Verbinde...")

	var tube = _create_tube()
	if not tube:
		status_update.emit("Fehler: Netzwerk konnte nicht initialisiert werden.")
		connection_failed.emit("tube_creation_failed")
		return false

	code = code.strip_edges().to_upper()
	current_lobby_code = code

	# Error-Handler
	var error_occurred := false
	var error_msg := ""
	var error_handler = func(err_code, msg):
		error_occurred = true
		error_msg = msg

	tube.error_raised.connect(error_handler)
	tube.join_session(code)

	# Timeout
	var timeout_timer = get_tree().create_timer(CONNECTION_TIMEOUT)
	var result = await _await_with_timeout(tube.session_joined, timeout_timer)

	if error_occurred:
		status_update.emit("Verbindung fehlgeschlagen: " + error_msg)
		_reset_session()
		connection_failed.emit("join_error")
		return false

	if not result:
		status_update.emit("Timeout: Konnte nicht beitreten.")
		_reset_session()
		connection_failed.emit("timeout")
		return false

	status_update.emit("Verbunden! Gehe zur Lobby...")
	send_player_info.rpc(my_local_name)
	get_tree().change_scene_to_file("res://levels/lobby.tscn")
	return true

# --- HELFER ---

## Wartet auf ein Signal mit Timeout. Gibt true zurück wenn Signal kam, false bei Timeout.
func _await_with_timeout(success_signal: Signal, timeout_timer: SceneTreeTimer) -> bool:
	var completed := false
	var success := false

	var on_success = func():
		if not completed:
			completed = true
			success = true
	var on_timeout = func():
		if not completed:
			completed = true

	success_signal.connect(on_success, CONNECT_ONE_SHOT)
	timeout_timer.timeout.connect(on_timeout, CONNECT_ONE_SHOT)

	# Warten bis eines der beiden feuert
	while not completed:
		await get_tree().process_frame

	return success

func _create_tube():
	var tube = TubeClientClass.new()
	var context = TubeContextClass.new()

	context.app_id = MY_APP_ID
	context.session_id_characters_set = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	context.stun_servers_urls = stun_servers
	context.trackers_urls = tracker_servers

	if not context.is_valid():
		status_update.emit("Fehler: Ungültige Netzwerk-Konfiguration.")
		return null

	tube.context = context

	# WebRTC-Timeouts erhöhen für langsame Netze / Mobilfunk
	tube.peer_signaling_timeout = 5.0
	tube.peer_signaling_max_attempts = 5

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
	is_in_game = false

# --- EVENT HANDLER ---
func _on_player_connected(id):
	# Max-Players Check
	if multiplayer.is_server() and players.size() >= MAX_PLAYERS:
		status_update.emit("Lobby voll - Spieler abgelehnt.")
		return
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

# --- RPCs ---
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
	if new_index < 0 or new_index >= maps.size():
		return
	current_map_index = new_index
	lobby_state_changed.emit()

@rpc("authority", "call_local", "reliable")
func start_game():
	if current_map_index < 0 or current_map_index >= maps.size():
		return
	is_in_game = true
	# Neue Verbindungen blockieren wenn Spiel läuft
	if multiplayer.is_server() and current_tube_session:
		current_tube_session.refuse_new_connections = true
	var map_data = maps[current_map_index]
	get_tree().change_scene_to_file(map_data["scene_path"])

@rpc("authority", "call_local", "reliable")
func return_to_lobby():
	is_in_game = false
	# Verbindungen wieder erlauben
	if multiplayer.is_server() and current_tube_session:
		current_tube_session.refuse_new_connections = false
	get_tree().change_scene_to_file("res://levels/lobby.tscn")
