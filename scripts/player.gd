extends CharacterBody2D

@onready var sync = $MultiplayerSynchronizer
@onready var sprite = $Sprite2D
@onready var engine_sound = $EngineSound
@onready var tire_squeal_sound = $TireSquealSound

# --- Texturen & Assets ---
const TEX_BLUE = preload("res://assets/PNG/Cars/car_blue_1.png")
const TEX_RED = preload("res://assets/PNG/Cars/car_red_1.png")
const TEX_YELLOW = preload("res://assets/PNG/Cars/car_yellow_1.png")
const TEX_GREEN = preload("res://assets/PNG/Cars/car_green_1.png")

var game_node = null

# Networking
@export var server_position := Vector2.ZERO
@export var server_rotation := 0.0
@export var current_speed := 0.0
var player_index := 0
const INTERPOLATION_SPEED = 20.0

# --- PHYSIK (Original + Verbesserungen) ---
var max_speed = 550.0
var base_acceleration = 400.0
var speed_accel_falloff = 0.7
var friction_decel = 60.0
var brake_decel = 500.0
var drag_coefficient = 0.0003
var base_angular_speed = PI * 1.2
var steering_factor = 1.6
var traction_slow = 20.0
var traction_fast = 8.0

# Handbrake / Drift
var handbrake_active = false
var drift_traction = 3.0
var drift_angular_boost = 1.5
var drift_speed_retention = 0.98

# Kollision
var collision_speed_loss = 0.85
var knockback_velocity = Vector2.ZERO
const KNOCKBACK_DECAY = 15.0
const RAM_FORCE = 250.0

func _enter_tree():
	set_multiplayer_authority(name.to_int())

func _ready():
	# Group-basierte Suche ist robuster als find_child
	var game_nodes = get_tree().get_nodes_in_group("game_controller")
	game_node = game_nodes[0] if game_nodes.size() > 0 else null
	if sprite:
		match player_index % 4:
			0: sprite.texture = TEX_BLUE
			1: sprite.texture = TEX_RED
			2: sprite.texture = TEX_YELLOW
			3: sprite.texture = TEX_GREEN
	server_position = position
	server_rotation = rotation

	# Sound nur für lokalen Spieler starten
	if is_multiplayer_authority():
		if engine_sound:
			engine_sound.play()
	else:
		if engine_sound: engine_sound.stop()
		if tire_squeal_sound: tire_squeal_sound.stop()

func _physics_process(delta):
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	# Knockback Physik (immer berechnen)
	if knockback_velocity.length() > 5.0:
		knockback_velocity = knockback_velocity.lerp(Vector2.ZERO, KNOCKBACK_DECAY * delta)
	else:
		knockback_velocity = Vector2.ZERO

	# Netzwerk-Interpolation für Remote-Spieler
	if not is_multiplayer_authority():
		if position.distance_to(server_position) > 200.0:
			position = server_position
			rotation = server_rotation
		else:
			position = position.lerp(server_position, delta * INTERPOLATION_SPEED)
			rotation = lerp_angle(rotation, server_rotation, delta * INTERPOLATION_SPEED)
		return

	# --- START-BLOCKER ---
	if game_node and "game_started" in game_node and not game_node.game_started:
		return

	# --- INPUT ---
	var direction = Input.get_axis("ui_left", "ui_right")
	var gas = Input.get_axis("ui_down", "ui_up")
	handbrake_active = Input.is_action_pressed("drift")

	# --- STEERING (Original + Drift-Boost) ---
	var angular_speed = base_angular_speed / (1 + steering_factor * abs(current_speed / max_speed))
	if handbrake_active:
		angular_speed *= drift_angular_boost
	if abs(current_speed) > 10.0:
		var reverse_factor = 1.0 if current_speed >= 0 else -1.0
		rotation += angular_speed * direction * delta * reverse_factor

	# --- ACCELERATION (Progressiv + Ausrollen) ---
	if gas > 0:
		var speed_ratio = clamp(current_speed / max_speed, 0.0, 1.0)
		var accel = base_acceleration * pow(max(1.0 - speed_ratio, 0.01), speed_accel_falloff)
		current_speed = move_toward(current_speed, max_speed * gas, accel * delta)
	elif gas < 0:
		if current_speed > 0:
			current_speed = move_toward(current_speed, 0, brake_decel * delta)
		else:
			current_speed = move_toward(current_speed, max_speed * gas * 0.6, base_acceleration * 0.5 * delta)
	else:
		var drag = friction_decel + drag_coefficient * current_speed * current_speed
		current_speed = move_toward(current_speed, 0, drag * delta)

	# --- TRACTION (Original Lerp + Handbrake) ---
	var desired_velocity = Vector2.UP.rotated(rotation) * current_speed
	var current_traction = lerp(traction_slow, traction_fast, abs(current_speed) / max_speed)

	# Handbrake: Traction drastisch reduzieren → Drift
	if handbrake_active and abs(current_speed) > 30.0:
		current_traction = drift_traction
		current_speed *= drift_speed_retention

	var velocity_without_knockback = velocity - knockback_velocity

	if is_zero_approx(current_speed):
		velocity_without_knockback = Vector2.ZERO
	else:
		velocity_without_knockback = velocity_without_knockback.lerp(desired_velocity, current_traction * delta)

	velocity = velocity_without_knockback + knockback_velocity

	# --- VISUAL FEEDBACK: Sprite Lean ---
	if sprite:
		var lean = direction * clamp(abs(current_speed) / max_speed, 0.0, 1.0) * 0.08
		sprite.scale.x = 1.0 - abs(lean)

	# --- SOUND FEEDBACK ---
	_update_sounds()

	# --- MOVE ---
	if move_and_slide(): _handle_collisions()

	server_position = position
	server_rotation = rotation

func _update_sounds():
	if not is_multiplayer_authority():
		return

	# Engine Sound: Pitch und Volume skalieren mit Speed
	if engine_sound:
		var speed_ratio = clamp(abs(current_speed) / max_speed, 0.0, 1.0)
		engine_sound.pitch_scale = lerp(0.6, 1.8, speed_ratio)
		engine_sound.volume_db = lerp(-20.0, -6.0, speed_ratio)

	# Tire Squeal: bei Drift oder hohem Slip
	if tire_squeal_sound:
		var forward_dir = Vector2.UP.rotated(rotation)
		var slip_amount = 0.0
		if velocity.length() > 30.0:
			var lateral = velocity - forward_dir * velocity.dot(forward_dir)
			slip_amount = lateral.length() / max(velocity.length(), 1.0)

		if slip_amount > 0.15 or (handbrake_active and abs(current_speed) > 50.0):
			var intensity = clamp(slip_amount / 0.6, 0.0, 1.0)
			if handbrake_active:
				intensity = max(intensity, 0.5)
			tire_squeal_sound.volume_db = lerp(-25.0, -8.0, intensity)
			if not tire_squeal_sound.playing:
				tire_squeal_sound.play()
		else:
			if tire_squeal_sound.playing:
				tire_squeal_sound.stop()

func _handle_collisions():
	for i in get_slide_collision_count():
		var collision = get_slide_collision(i)
		var collider = collision.get_collider()
		if collider is CharacterBody2D and collider.has_method("apply_impulse"):
			var push_dir = -collision.get_normal()
			var impact = clamp(abs(current_speed), 0.0, max_speed) / max_speed
			var force = impact * RAM_FORCE
			# Gezielt nur an den betroffenen Spieler senden
			var target_id = collider.name.to_int()
			if target_id != multiplayer.get_unique_id():
				collider.apply_impulse.rpc_id(target_id, push_dir * force)
			collider.apply_impulse(push_dir * force)
			knockback_velocity += collision.get_normal() * (force * 0.2)
			current_speed *= 0.85
		else:
			current_speed *= collision_speed_loss

@rpc("any_peer", "call_local", "reliable")
func apply_impulse(force_vector):
	knockback_velocity += force_vector
	current_speed *= 0.9
