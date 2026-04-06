extends Node

const PLAYER_SCENE_PATH := "res://prefabs/player.tscn"
const RACE_LOGIC_SCRIPT = "res://scripts/game_modes/race_mode.gd"

# --- REFERENZEN ---
@onready var players_container = $"../Players"
@onready var spawner = $"../Players/MultiplayerSpawner"
@onready var spawn_points_container = $"../SpawnPoints"
@onready var countdown_label = $"../HUD/CountdownLabel"
@onready var audio_start = $"../audio_start"

# --- DATEN ---
var game_started := false
var players_ready: Dictionary = {}
var spawn_complete := false

# Countdown
var countdown_value := 4
var countdown_timer := 0.0

# Logik-Helfer
var race_logic_node: Node = null

func _ready():
	add_to_group("game_controller")

	# 1. Infrastruktur
	if spawner:
		spawner.spawn_path = ".."
		spawner.spawn_function = _spawn_player_internal

	players_container.child_entered_tree.connect(_on_player_node_added)
	players_container.child_exiting_tree.connect(_on_player_node_removed)
	multiplayer.peer_connected.connect(_on_player_connected)
	multiplayer.peer_disconnected.connect(_on_player_disconnected)

	# 2. Race Logic laden
	_attach_race_logic()

	# 3. Ready-Signal mit Retry senden
	_send_ready_with_retry()

	# Prozess aus, bis Countdown startet
	set_process(false)

func _send_ready_with_retry():
	# Warten bis Verbindung steht, dann ready senden
	for attempt in range(5):
		await get_tree().create_timer(0.5).timeout
		if multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			notify_im_ready.rpc_id(1)
			return
	# Nach 5 Versuchen (2.5s) aufgeben
	if countdown_label:
		countdown_label.text = "Verbindung fehlgeschlagen"

func _process(delta):
	if Input.is_action_just_pressed("exit"):
		_return_to_menu()

	# Countdown Management
	if not game_started and countdown_value > 0:
		countdown_timer += delta
		if countdown_timer >= 1.0:
			countdown_timer = 0.0
			countdown_value -= 1
			_update_countdown_ui()

# --- INITIALISIERUNG ---
func _attach_race_logic():
	var script = load(RACE_LOGIC_SCRIPT)
	var logic_node = Node.new()
	logic_node.name = "RaceLogic"
	logic_node.set_script(script)
	add_child(logic_node)
	race_logic_node = logic_node

# --- SYNC & START ---
@rpc("any_peer", "call_local", "reliable")
func notify_im_ready():
	if not multiplayer.is_server(): return

	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id == 0: sender_id = 1
	players_ready[sender_id] = true

	# Alle Peers + Host müssen ready sein
	var expected_peers = multiplayer.get_peers()
	var all_ready = players_ready.has(1) # Host ready?
	for peer_id in expected_peers:
		if not players_ready.has(peer_id):
			all_ready = false
			break

	if all_ready and not spawn_complete:
		_start_game_sequence()

func _start_game_sequence():
	spawn_complete = true

	# 1. Spawnen
	spawner.spawn([1, 0])
	var index = 1
	for id in multiplayer.get_peers():
		spawner.spawn([id, index])
		index += 1

	# 2. Warten damit Clients Autos instanziieren können
	await get_tree().create_timer(1.0).timeout

	# 3. Bestätigen, dass alle Spieler noch da sind
	var peers_still_connected = multiplayer.get_peers()
	for id in players_ready.keys():
		if id != 1 and not (id in peers_still_connected):
			# Spieler hat während des Wartens disconnected
			players_ready.erase(id)
			if players_container.has_node(str(id)):
				players_container.get_node(str(id)).queue_free()

	# 4. Countdown starten
	start_countdown_sequence.rpc()

@rpc("authority", "call_local", "reliable")
func start_countdown_sequence():
	countdown_value = 4
	countdown_timer = 0.0
	if audio_start: audio_start.play()
	set_process(true)

	if race_logic_node and race_logic_node.has_method("reset_match"):
		race_logic_node.reset_match()

func _update_countdown_ui():
	if not countdown_label: return

	if countdown_value > 0:
		countdown_label.text = str(countdown_value)
	else:
		countdown_label.text = "GO!"
		game_started = true
		get_tree().create_timer(1.0).timeout.connect(func(): if countdown_label: countdown_label.text = "")

# --- SPAWN ---
func _spawn_player_internal(data):
	var id = data[0]
	var idx = data[1]
	var p = load(PLAYER_SCENE_PATH).instantiate()
	p.name = str(id)
	p.player_index = idx

	var spawns = []
	if spawn_points_container: spawns = spawn_points_container.get_children()

	if idx < spawns.size():
		p.position = spawns[idx].position
		p.rotation = spawns[idx].rotation
	else:
		p.position = Vector2.ZERO
	p.z_index = 10
	return p

# --- WEITERLEITUNG AN LOGIK ---
func _on_player_node_added(node):
	if race_logic_node: race_logic_node.on_player_spawned(node)

func _on_player_node_removed(node):
	if race_logic_node: race_logic_node.on_player_despawned(node)

func _return_to_menu():
	NetworkManager.reset_network()
	get_tree().change_scene_to_file("res://levels/menu.tscn")

func _on_player_connected(_id): pass

func _on_player_disconnected(id):
	players_ready.erase(id)
	# Spieler-Node entfernen und alle Clients benachrichtigen
	if players_container.has_node(str(id)):
		players_container.get_node(str(id)).queue_free()
	# Race Logic informieren (check_game_over wird automatisch über child_exiting_tree getriggert)
