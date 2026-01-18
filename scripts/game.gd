# game.gd
extends Node

const PLAYER_SCENE_PATH := "res://prefabs/player.tscn"

# --- ZUKUNFTS-MUSIK: REGISTRIERUNG DER MODI ---
# Hier trägst du später neue Modi ein.
# Key: Ein Enum oder String (kommt vom NetworkManager)
# Value: Der Pfad zum Skript
const GAME_MODES = {
	"RACE": "res://scripts/game_modes/race_mode.gd",
	# "TAG": "res://scripts/game_modes/tag_mode.gd",
	# "BATTLE": "res://scripts/game_modes/battle_mode.gd"
}

# Aktuell gewählter Modus (später via NetworkManager holen)
var current_mode_key = "RACE" 

# --- REFERENZEN ---
@onready var players_container = $"../Players"
@onready var spawner = $"../Players/MultiplayerSpawner"
@onready var spawn_points_container = $"../SpawnPoints"

# Referenz auf den dynamisch erzeugten Modus
var active_game_mode_node: Node = null

# --- DATEN ---
# Diese Variable ist der "Master Switch" für Inputs (player.gd greift hierauf zu)
var game_started := false 
var players_loaded_count := 0

func _ready():
	# 1. DYNAMISCHES ERZEUGEN DES SPIELMODUS
	_load_and_attach_gamemode()

	# 2. Spawner Setup
	if spawner:
		spawner.spawn_path = ".." 
		spawner.spawn_function = _spawn_player_internal

	# 3. Infrastruktur-Signale
	players_container.child_entered_tree.connect(_on_player_node_added)
	players_container.child_exiting_tree.connect(_on_player_node_removed)
	multiplayer.peer_connected.connect(_on_player_connected)
	multiplayer.peer_disconnected.connect(_on_player_disconnected)
	
	# 4. Ready-Signal an Host
	await get_tree().process_frame
	notify_im_ready.rpc_id(1)

func _process(_delta):
	if Input.is_action_just_pressed("exit"):
		_return_to_menu()

# --- MODUS FACTORY ---
func _load_and_attach_gamemode():
	# In Zukunft: var key = NetworkManager.selected_game_mode
	var key = current_mode_key 
	
	if not GAME_MODES.has(key):
		push_error("Spielmodus nicht gefunden: " + key)
		return

	var script_path = GAME_MODES[key]
	var script = load(script_path)
	
	# Neuen Node erzeugen
	var mode_node = Node.new()
	mode_node.name = "GameMode" # WICHTIG: Damit RPCs den Pfad finden (/root/Level/GameMode)
	mode_node.set_script(script)
	
	# Als GESCHWISTER anhängen (Kind von Level)
	get_parent().call_deferred("add_child", mode_node)
	
	# Referenz speichern
	active_game_mode_node = mode_node
	print("Spielmodus geladen: ", key)

# --- LOAD SYNC ---
@rpc("any_peer", "call_local", "reliable")
func notify_im_ready():
	if not multiplayer.is_server(): return
	players_loaded_count += 1
	var expected = multiplayer.get_peers().size() + 1
	if players_loaded_count >= expected:
		_start_game_sequence()

func _start_game_sequence():
	# A) Spieler spawnen (Aufgabe der Infrastruktur)
	spawner.spawn([1, 0]) 
	var index = 1
	for id in multiplayer.get_peers():
		spawner.spawn([id, index])
		index += 1
	
	await get_tree().create_timer(1.0).timeout
	
	# B) Spielmodus starten
	# Wir rufen die Funktion auf dem dynamischen Node auf
	if active_game_mode_node:
		# RPC Aufruf auf dem neuen Node
		active_game_mode_node.rpc("start_match")
	else:
		print("FEHLER: Kein GameMode aktiv!")

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

# --- EVENT WEITERLEITUNG ---
# Da der GameMode erst später entsteht, leiten wir Events weiter
func _on_player_node_added(node):
	if active_game_mode_node and active_game_mode_node.has_method("on_player_spawned"):
		active_game_mode_node.on_player_spawned(node)

func _on_player_node_removed(node):
	if active_game_mode_node and active_game_mode_node.has_method("on_player_despawned"):
		active_game_mode_node.on_player_despawned(node)

func _return_to_menu():
	NetworkManager.reset_network()
	get_tree().change_scene_to_file("res://levels/menu.tscn")

func _on_player_connected(_id): pass
func _on_player_disconnected(id): 
	if players_container.has_node(str(id)): 
		players_container.get_node(str(id)).queue_free()
