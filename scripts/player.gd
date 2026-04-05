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

# --- PHYSIK ---
# Speed
var max_speed = 600.0
var reverse_max_speed = 200.0

# Acceleration (progressiv)
var base_acceleration = 400.0
var speed_accel_falloff = 0.7
var friction_decel = 60.0
var brake_decel = 500.0
var drag_coefficient = 0.0003

# Steering
var base_angular_speed = PI * 1.0
var min_steer_speed = 15.0
var steering_tightness = 1.8

# Traction (Slip-Angle Modell)
var grip_front = 18.0
var grip_rear = 16.0
var drift_grip_rear = 4.0
var current_rear_grip = 16.0
var grip_recovery_speed = 6.0

# Drift / Handbrake
var handbrake_active = false
var drift_angular_boost = 1.4
var drift_speed_retention = 0.97

# Kollision
var wall_speed_retention = 0.65
var wall_bounce_factor = 0.3
var knockback_velocity = Vector2.ZERO
const KNOCKBACK_DECAY = 15.0
const RAM_FORCE = 300.0

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
	var gas = Input.get_axis("ui_down", "ui_up")
	var steer = Input.get_axis("ui_left", "ui_right")
	handbrake_active = Input.is_action_pressed("drift")

	# --- ACCELERATION (3 Zustände) ---
	if gas > 0:
		# Vorwärts: progressive Kurve - starker Punch am Start, nachlassend bei hoher Speed
		var speed_ratio = clamp(current_speed / max_speed, 0.0, 1.0)
		var accel = base_acceleration * pow(max(1.0 - speed_ratio, 0.01), speed_accel_falloff)
		current_speed = move_toward(current_speed, max_speed * gas, accel * delta)
	elif gas < 0:
		if current_speed > 0:
			# Aktives Bremsen
			current_speed = move_toward(current_speed, 0, brake_decel * delta)
		else:
			# Rückwärts fahren (langsamer)
			var speed_ratio = clamp(abs(current_speed) / reverse_max_speed, 0.0, 1.0)
			var accel = base_acceleration * 0.5 * pow(max(1.0 - speed_ratio, 0.01), speed_accel_falloff)
			current_speed = move_toward(current_speed, reverse_max_speed * gas, accel * delta)
	else:
		# Ausrollen: sanfte Friction + quadratischer Drag
		var drag = friction_decel + drag_coefficient * current_speed * current_speed
		current_speed = move_toward(current_speed, 0, drag * delta)

	# Drift-Speed-Verlust
	if handbrake_active and abs(current_speed) > 30.0:
		current_speed *= drift_speed_retention

	# --- STEERING ---
	if abs(current_speed) > min_steer_speed:
		var speed_ratio = abs(current_speed) / max_speed
		var angular_speed = base_angular_speed / (1.0 + steering_tightness * pow(speed_ratio, 0.8))
		if handbrake_active:
			angular_speed *= drift_angular_boost
		var reverse_factor = 1.0 if current_speed >= 0 else -1.0
		rotation += angular_speed * steer * delta * reverse_factor

	# --- TRACTION (Slip-Angle Forward/Lateral Decomposition) ---
	var forward_dir = Vector2.UP.rotated(rotation)
	var desired_velocity = forward_dir * current_speed

	# Rear grip: smooth transition zwischen normal und drift
	var target_rear_grip = drift_grip_rear if handbrake_active else grip_rear
	current_rear_grip = move_toward(current_rear_grip, target_rear_grip, grip_recovery_speed * delta)

	if velocity.length() > 5.0:
		# Velocity in Vorwärts- und Seitwärts-Komponente zerlegen
		var forward_component = forward_dir * velocity.dot(forward_dir)
		var lateral_component = velocity - forward_component

		# Grip bestimmt wie schnell Seitwärts-Bewegung abgebaut wird
		var front_influence = clamp(grip_front * delta, 0.0, 1.0)
		var rear_influence = clamp(current_rear_grip * delta, 0.0, 1.0)
		var avg_grip = (front_influence + rear_influence) / 2.0

		lateral_component = lateral_component * (1.0 - avg_grip)

		# Vorwärts-Komponente auf aktuelle Speed anpassen
		velocity = forward_dir * current_speed + lateral_component
	else:
		velocity = desired_velocity

	# Knockback drauf addieren
	velocity += knockback_velocity

	# --- VISUAL FEEDBACK: Sprite Lean ---
	if sprite:
		var lean = steer * clamp(abs(current_speed) / max_speed, 0.0, 1.0) * 0.08
		sprite.scale.x = 1.0 - abs(lean)

	# --- SOUND FEEDBACK ---
	_update_sounds()

	# --- MOVE ---
	if move_and_slide():
		_handle_collisions()

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

	# Tire Squeal: bei Drift oder hohem Slip-Angle
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
			# Wand-Kollision: spürbarer Speed-Verlust + Bounce
			current_speed *= wall_speed_retention
			var bounce = collision.get_normal() * abs(current_speed) * wall_bounce_factor
			velocity += bounce

@rpc("any_peer", "call_local", "reliable")
func apply_impulse(force_vector):
	knockback_velocity += force_vector
	current_speed *= 0.9
