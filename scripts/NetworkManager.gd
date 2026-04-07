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
var _last_tube_error: String = ""

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

const MY_APP_ID = "ralf_racing_007" # Exakt 15 Zeichen Pflicht für TubeContext!
const HOST_TIMEOUT := 30.0
const JOIN_TIMEOUT := 40.0

# DEBUG EINSTELLUNGEN
# Wenn true, wird lokales UDP-Signaling abgeschaltet -> Online-Pfad-Zwang
const DEBUG_FORCE_ONLINE_ONLY := true
const DEBUG_NETWORK_LOG := true
const DEBUG_STATUS_INTERVAL := 5.0
var _debug_status_timer := 0.0

func _ready():
	set_process(true)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_load_name()

func _load_name():
	var config = ConfigFile.new()
	if config.load("user://settings.cfg") == OK:
		my_local_name = config.get_value("user", "name", "Player")

func set_local_name(new_name: String):
	my_local_name = new_name
	var config = ConfigFile.new()
	config.load("user://settings.cfg")
	config.set_value("user", "name", my_local_name)
	config.save("user://settings.cfg")

func _process(delta):
	# Debug Status Report
	if DEBUG_NETWORK_LOG and current_tube_session != null:
		_debug_status_timer += delta
		if _debug_status_timer >= DEBUG_STATUS_INTERVAL:
			_debug_status_timer = 0.0
			_print_debug_status()

	if not multiplayer.has_multiplayer_peer(): return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED: return
	if multiplayer.is_server(): return

	ping_timer += delta
	if ping_timer >= PING_INTERVAL:
		ping_timer = 0.0
		request_ping()

# --- DEBUG STATUS ---
func _print_debug_status():
	var tube = current_tube_session
	if not tube: return
	
	print("[Net] === Status (session=%s) ===" % tube.session_id)
	if "_trackers" in tube:
		for t in tube._trackers:
			var ws_state = t.socket.get_ready_state() if t.socket else -1
			print("  [Tracker] %s | State: %d" % [t.url.split("/")[-1], ws_state])
	if "_peers" in tube:
		for pid in tube._peers:
			var p = tube._peers[pid]
			print("  [Peer %d] Conn: %d | ICE: %d | Sig: %d" % [pid, p.connection_state, p.ice_candidates.size(), p.signaling_state])

# --- DISCONNECT HANDLER ---
func _on_server_disconnected():
	print("Verbindung verloren.")
	reset_network()
	status_update.emit("Verbindung zum Host verloren.")
	get_tree().change_scene_to_file.call_deferred("res://levels/menu.tscn")

@rpc("authority", "call_remote", "reliable")
func kicked_by_host():
	print("Host hat die Lobby geschlossen.")
	reset_network()
	status_update.emit("Host hat die Lobby geschlossen.")
	get_tree().change_scene_to_file.call_deferred("res://levels/menu.tscn")

# --- RESET ---
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
	_maybe_force_online_only(tube)
	_fix_signals()
	
	var success = await _wait_for_signal(tube.session_created, HOST_TIMEOUT)
	if not success:
		status_update.emit("Host-Timeout: Tracker nicht erreichbar.")
		_reset_session()
		return null
	
	var key = tube.session_id
	if key:
		current_lobby_code = key
		add_player(1)
		players[1]["name"] = my_local_name
		status_update.emit("Lobby erstellt: " + key)
		return key
	return null

# --- JOINING ---
func join_game(code):
	_reset_session()
	status_update.emit("Verbinde...")
	
	var tube = _create_tube()
	if not tube: return
	
	code = code.strip_edges().to_upper()
	current_lobby_code = code
	
	tube.join_session(code)
	_maybe_force_online_only(tube)
	_fix_signals()
	
	var success = await _wait_for_signal(tube.session_joined, JOIN_TIMEOUT)
	if not success:
		status_update.emit("Lobby nicht gefunden oder Timeout.")
		_reset_session()
		return
	
	status_update.emit("Verbunden! Synchronisiere...")
	await get_tree().create_timer(0.8).timeout
	send_player_info.rpc(my_local_name)
	get_tree().change_scene_to_file("res://levels/lobby.tscn")

# --- HELFER ---
func _maybe_force_online_only(tube):
	if not DEBUG_FORCE_ONLINE_ONLY: return
	if not tube: return
	# Wir greifen auf das interne Signaling-Objekt zu und schließen es
	if "_local_signaling_peer" in tube and tube._local_signaling_peer != null:
		tube._local_signaling_peer.close()
		tube._local_signaling_peer = null
		print("[Net] DEBUG: Lokales Signaling deaktiviert - Online-Pfad erzwungen.")

func _wait_for_signal(sig: Signal, timeout_sec: float) -> bool:
	var fired := [false]
	var callable = func(): fired[0] = true
	sig.connect(callable, CONNECT_ONE_SHOT)
	var start_ms := Time.get_ticks_msec()
	while not fired[0]:
		await get_tree().process_frame
		if Time.get_ticks_msec() - start_ms >= timeout_sec * 1000.0:
			if sig.is_connected(callable): sig.disconnect(callable)
			return false
	return true

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
	
	# Typisierte Arrays für Godot 4
	var stuns: Array[String] = [
		"stun:stun.l.google.com:19302",
		"stun:stun1.l.google.com:19302",
		"stun:global.stun.twilio.com:3478?transport=udp"
	]
	context.stun_servers_urls = stuns
	
	var trackers: Array[String] = [
		"wss://tracker.openwebtorrent.com",
		"wss://tracker.files.fm:7073/announce"
	]
	context.trackers_urls = trackers
	
	if not context.is_valid():
		print("FEHLER: Context ist invalid (Prüfe AppID Länge 15!)")
		return null

	tube.context = context
	tube.peer_signaling_timeout = 20.0
	tube.peer_signaling_max_attempts = 10
	tube.error_raised.connect(_on_tube_error)

	# Debug Hooks
	if DEBUG_NETWORK_LOG:
		tube.peer_connected.connect(func(id): print("[Net] ✓ Peer verbunden: ", id))
		tube._tracker_initiated.connect(_on_tracker_initiated_debug)

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

func _on_tube_error(_code, message):
	_last_tube_error = str(message)
	print("[Net] Tube Error: ", message)

func _on_tracker_initiated_debug(tracker):
	print("[Net] Tracker init: ", tracker.url)
	tracker.connected.connect(func(): print("[Net] ✓ Tracker verbunden: ", tracker.url))
	tracker.disconnected.connect(func(): print("[Net] ✗ Tracker getrennt: ", tracker.url))

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
	if sender_id == 0: sender_id = multiplayer.get_unique_id()
	add_player(sender_id)
	players[sender_id]["name"] = str(name_str)
	lobby_updated.emit()

@rpc("any_peer", "call_local", "reliable")
func sync_lobby_state(new_index):
	current_map_index = new_index
	lobby_state_changed.emit()

@rpc("call_local", "reliable")
func start_game():
	var map_data = maps[current_map_index]
	print("Starte Spiel auf Map: ", map_data["name"])
	get_tree().change_scene_to_file.call_deferred(map_data["scene_path"])
