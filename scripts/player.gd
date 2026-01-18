# player.gd
extends CharacterBody2D

# --- NODES ---
@onready var sync = $MultiplayerSynchronizer
@onready var sprite = $Sprite2D 

# --- TEXTUREN ---
const TEX_BLUE = preload("res://assets/PNG/Cars/car_blue_1.png")
const TEX_RED = preload("res://assets/PNG/Cars/car_red_1.png")
const TEX_YELLOW = preload("res://assets/PNG/Cars/car_yellow_1.png")
const TEX_GREEN = preload("res://assets/PNG/Cars/car_green_1.png")

# --- REFERENCE ---
var game_node = null

# --- NETZWERK VARIABLEN ---
@export var server_position := Vector2.ZERO
@export var server_rotation := 0.0
@export var current_speed := 0.0 

var player_index := 0 

# Glättung
const INTERPOLATION_SPEED = 20.0

# --- PHYSIK SETUP (TUNING: GRIP & KONTROLLE) ---
var max_speed = 550.0       
# Zurückgefahren auf 300 (Original war 250, mein Vorschlag war 450). 
# Ein guter Kompromiss zwischen Trägheit und Kontrolle.
var acceleration = 250.0    
var deceleration = 700.0    # Etwas höher, damit das Auto "satter" bremst.
var base_angular_speed = PI * 1.2 

var steering_factor = 1.6   
var current_acceleration = acceleration

# --- TRAKTION (Das "Eis" Problem beheben) ---
# Werte drastisch erhöht. Das sorgt für festen Grip.
# slow: 20.0 (fast sofortige Reaktion)
# fast: 6.0 (minimales Rutschen bei Highspeed, aber kein Driften)
var traction_slow = 20.0  
var traction_fast = 8.0   

# --- KOLLISION ---
var collision_speed_loss = 0.85 
var collision_acceleration_loss = 0.12 
var collision_recovery_time = 0.75 
var collision_timer = 0.0

# --- SPIELER-INTERAKTION ---
var knockback_velocity = Vector2.ZERO
const KNOCKBACK_DECAY = 15.0 # Schnellerer Decay = weniger Rutschen nach Rammstoß
const RAM_FORCE = 250.0      # Etwas moderater als vorher

# --- INIT ---
func _enter_tree():
	set_multiplayer_authority(name.to_int())

func _ready():
	game_node = get_tree().root.find_child("Game", true, false)
		
	if sprite:
		match player_index:
			0: sprite.texture = TEX_BLUE
			1: sprite.texture = TEX_RED
			2: sprite.texture = TEX_YELLOW
			3: sprite.texture = TEX_GREEN
			_: sprite.texture = TEX_BLUE

	server_position = position
	server_rotation = rotation

# --- MOVEMENT LOOP ---
func _process(delta):
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	if not is_multiplayer_authority():
		if position.distance_to(server_position) > 200.0:
			position = server_position
			rotation = server_rotation
		else:
			position = position.lerp(server_position, delta * INTERPOLATION_SPEED)
			rotation = lerp_angle(rotation, server_rotation, delta * INTERPOLATION_SPEED)

func _physics_process(delta):
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	# Knockback abbauen (schneller als vorher für mehr Stabilität)
	if knockback_velocity.length() > 5.0:
		knockback_velocity = knockback_velocity.lerp(Vector2.ZERO, KNOCKBACK_DECAY * delta)
	else:
		knockback_velocity = Vector2.ZERO

	if not is_multiplayer_authority():
		return

	if game_node and "game_started" in game_node and not game_node.game_started:
		return

	# --- KOLLISIONS-ERHOLUNG ---
	if collision_timer > 0:
		collision_timer -= delta
		var t = 1.0 - (collision_timer / collision_recovery_time)
		current_acceleration = lerp(acceleration * (1 - collision_acceleration_loss), acceleration, t)
	else:
		current_acceleration = acceleration

	# --- INPUT ---
	var direction = Input.get_axis("ui_left", "ui_right")
	
	# Lenk-Logik
	var angular_speed = base_angular_speed / (1 + steering_factor * abs(current_speed / max_speed))
	
	if abs(current_speed) > 10.0: 
		# Rückwärtsgang Logik beibehalten (Realismus)
		var reverse_factor = 1.0 if current_speed >= 0 else -1.0
		rotation += angular_speed * direction * delta * reverse_factor

	var gas = Input.get_axis("ui_down", "ui_up")
	var intended_speed = gas * max_speed
	if gas < 0: intended_speed *= 0.6 

	# --- MOTOR ---
	if (intended_speed > 0 and current_speed >= 0) or (intended_speed < 0 and current_speed <= 0):
		if intended_speed != 0:
			current_speed = move_toward(current_speed, intended_speed, current_acceleration * delta)
	else:
		current_speed = move_toward(current_speed, 0, deceleration * delta)

	# --- BEWEGUNG (SUBTIL) ---
	var desired_velocity = Vector2.UP.rotated(rotation) * current_speed
	
	# Hier haben wir "Ice" entfernt: Wir nehmen sehr hohe Traktionswerte.
	# Das Auto folgt fast 1:1 der Rotation, aber "smoothness" bleibt erhalten.
	var current_traction = lerp(traction_slow, traction_fast, abs(current_speed) / max_speed)
	
	var velocity_without_knockback = velocity - knockback_velocity
	
	if is_zero_approx(current_speed):
		velocity_without_knockback = Vector2.ZERO
	else:
		velocity_without_knockback = velocity_without_knockback.lerp(desired_velocity, current_traction * delta)
	
	velocity = velocity_without_knockback + knockback_velocity
	
	var collision_happened = move_and_slide()
	
	if collision_happened:
		_handle_collisions()

	server_position = position
	server_rotation = rotation

# --- KOLLISIONS-WEICHE ---
func _handle_collisions():
	for i in get_slide_collision_count():
		var collision = get_slide_collision(i)
		var collider = collision.get_collider()
		
		# A) SPIELER (Rammen bleibt drin, fühlt sich gut an)
		if collider is CharacterBody2D and collider.has_method("apply_impulse"):
			var push_dir = -collision.get_normal()
			var impact = clamp(abs(current_speed), 0.0, max_speed) / max_speed
			var force = impact * RAM_FORCE
			
			collider.apply_impulse.rpc(push_dir * force)
			
			# Kleiner Rückstoß für Angreifer (Physik), aber kein wildes Herumfliegen
			knockback_velocity += collision.get_normal() * (force * 0.2)
			current_speed *= 0.85 
			
		# B) WAND / OBJEKT (Gefixed: Kein Bouncing mehr)
		else:
			# Einfach nur Speed verlieren, kein künstlicher Rückstoß.
			# Das fühlt sich an wie "in die Mauer krachen".
			current_speed *= collision_speed_loss
			
			# Optional: Knockback nullen, damit man nicht an der Wand "entlang rutscht"
			# knockback_velocity = Vector2.ZERO 
			
			collision_timer = collision_recovery_time

# --- RPC ---
@rpc("any_peer", "call_local", "reliable")
func apply_impulse(force_vector):
	knockback_velocity += force_vector
	current_speed *= 0.9
