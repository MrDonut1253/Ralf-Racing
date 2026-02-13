extends Node

const PLAYER_SCENE_PATH := "res://prefabs/player.tscn"

# Wir laden den Race-Mode nur als "Helper" für Rundenzeiten, nicht als Netzwerk-Controller
const RACE_LOGIC_SCRIPT = "res://scripts/game_modes/race_mode.gd"

# --- REFERENZEN ---
@onready var players_container = $"../Players"
@onready var spawner = $"../Players/MultiplayerSpawner"
@onready var spawn_points_container = $"../SpawnPoints"
# UI Referenzen direkt hier holen, wie in 0.4
@onready var countdown_label = $"../HUD/CountdownLabel"
@onready var audio_start = $"../audio_start"

# --- DATEN ---
# Diese Variable steuert, ob gefahren werden darf. 
# Da sie in game.gd ist, finden Host und Client sie immer!
var game_started := false 
var players_loaded_count := 0

# Countdown
var countdown_value := 4
var countdown_timer := 0.0

# Logik-Helfer
var race_logic_node: Node = null

func _ready():
	# 1. Infrastruktur
	if spawner:
		spawner.spawn_path = ".." 
		spawner.spawn_function = _spawn_player_internal

	players_container.child_entered_tree.connect(_on_player_node_added)
	players_container.child_exiting_tree.connect(_on_player_node_removed)
	multiplayer.peer_connected.connect(_on_player_connected)
	multiplayer.peer_disconnected.connect(_on_player_disconnected)
	
	# 2. Race Logic lokal laden (kein Networking, nur Rechnen)
	_attach_race_logic()
	
	# 3. Ready Signal senden
	await get_tree().process_frame
	notify_im_ready.rpc_id(1)
	
	# Prozess aus, bis Countdown startet
	set_process(false)

func _process(delta):
	if Input.is_action_just_pressed("exit"):
		_return_to_menu()
		
	# Countdown Management (Exakt wie in 0.4)
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
	add_child(logic_node) # Als Kind von Game
	race_logic_node = logic_node

# --- SYNC & START (0.4 Style) ---
@rpc("any_peer", "call_local", "reliable")
func notify_im_ready():
	if not multiplayer.is_server(): return
	players_loaded_count += 1
	var expected = multiplayer.get_peers().size() + 1
	if players_loaded_count >= expected:
		_start_game_sequence()

func _start_game_sequence():
	# 1. Spawnen
	spawner.spawn([1, 0]) 
	var index = 1
	for id in multiplayer.get_peers():
		spawner.spawn([id, index])
		index += 1
	
	# 2. Warten (damit Clients Zeit haben Autos zu instanziieren)
	await get_tree().create_timer(1.0).timeout
	
	# 3. RPC an ALLE: "Startet den Countdown!"
	start_countdown_sequence.rpc()

@rpc("call_local", "reliable")
func start_countdown_sequence():
	print("Countdown beginnt!")
	countdown_value = 4
	countdown_timer = 0.0
	if audio_start: audio_start.play()
	set_process(true) # Aktiviert _process für den Countdown
	
	# Info an Logik-Script weitergeben
	if race_logic_node and race_logic_node.has_method("reset_match"):
		race_logic_node.reset_match()

func _update_countdown_ui():
	if not countdown_label: return
	
	if countdown_value > 0:
		countdown_label.text = str(countdown_value)
	else:
		countdown_label.text = "GO!"
		# HIER IST DER SCHLÜSSEL: Variable setzen
		game_started = true
		
		# Label später löschen
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
	if players_container.has_node(str(id)): 
		players_container.get_node(str(id)).queue_free()
