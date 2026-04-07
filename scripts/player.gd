extends CharacterBody2D

@onready var sync = $MultiplayerSynchronizer
@onready var sprite = $Sprite2D
@onready var engine_sound = $EngineSound
@onready var tire_squeal_sound = $TireSquealSound

var smoke_particles: CPUParticles2D
var skid_left: CPUParticles2D
var skid_right: CPUParticles2D

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

var current_steer := 0.0
var _smoothed_lean := 0.0
var last_pos := Vector2.ZERO
var last_rot := 0.0

# --- PHYSIK ---
# Speed
var max_speed = 600.0
var reverse_max_speed = 180.0

# Acceleration (progressiv)
var base_acceleration = 470.0
var speed_accel_falloff = 0.6
var friction_decel = 120.0
var brake_decel = 500.0
var drag_coefficient = 0.0004

# Steering
var base_angular_speed = PI * 1.3
var min_steer_speed = 15.0
var steering_tightness = 1.0

# Traction (Slip-Angle Modell)
var grip_front = 16.0
var grip_rear = 11.0
var drift_grip_rear = 0.8
var current_rear_grip = 11.0
var grip_recovery_speed = 3.5

# Drift / Handbrake
@export var handbrake_active = false
var drift_kick_factor = 0.85
var drift_brake_decel = 340.0

# Kollision
var wall_speed_retention = 0.65
var wall_bounce_factor = 0.3
var knockback_velocity = Vector2.ZERO
const KNOCKBACK_DECAY = 20.0
const RAM_FORCE = 130.0

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

	# Sound für alle starten (AudioStreamPlayer2D sorgt für Distanz-Dämpfung)
	if engine_sound:
		engine_sound.play()

	_setup_smoke_particles()

func _setup_smoke_particles():
	smoke_particles = CPUParticles2D.new()
	smoke_particles.emitting = false
	smoke_particles.amount = 60
	smoke_particles.lifetime = 1.0
	smoke_particles.local_coords = false
	smoke_particles.direction = Vector2(0, 1) # Nach hinten ausstoßen
	smoke_particles.spread = 45.0
	smoke_particles.gravity = Vector2(0, 0)
	smoke_particles.initial_velocity_min = 10.0
	smoke_particles.initial_velocity_max = 60.0
	smoke_particles.scale_amount_min = 4.0
	smoke_particles.scale_amount_max = 16.0
	smoke_particles.color = Color(0.4, 0.4, 0.4, 0.5) # Dunklerer Rauch
	smoke_particles.position = Vector2(-8, 25) # Auspuff leicht links versetzt (asymmetrisch)
	smoke_particles.z_index = -1
	smoke_particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	smoke_particles.emission_sphere_radius = 6.0
	smoke_particles.randomness = 0.5
	smoke_particles.lifetime_randomness = 0.3
	add_child(smoke_particles)
	
	skid_left = CPUParticles2D.new()
	skid_left.emitting = false
	skid_left.amount = 800
	skid_left.lifetime = 8.0
	skid_left.local_coords = false
	skid_left.gravity = Vector2.ZERO
	skid_left.initial_velocity_min = 0.0
	skid_left.initial_velocity_max = 0.0
	skid_left.scale_amount_min = 8.0
	skid_left.scale_amount_max = 8.0
	skid_left.color = Color(0.1, 0.1, 0.1, 0.6) # Konstant schwarz, sonst ändern sich alte Spuren!
	skid_left.position = Vector2(-15, 20) # Linkes Hinterrad
	skid_left.z_index = -2
	add_child(skid_left)

	skid_right = CPUParticles2D.new()
	skid_right.emitting = false
	skid_right.amount = 800
	skid_right.lifetime = 8.0
	skid_right.local_coords = false
	skid_right.gravity = Vector2.ZERO
	skid_right.initial_velocity_min = 0.0
	skid_right.initial_velocity_max = 0.0
	skid_right.scale_amount_min = 8.0
	skid_right.scale_amount_max = 8.0
	skid_right.color = Color(0.1, 0.1, 0.1, 0.6) # Konstant schwarz, sonst ändern sich alte Spuren!
	skid_right.position = Vector2(15, 20) # Rechtes Hinterrad
	skid_right.z_index = -2
	add_child(skid_right)

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
	current_steer = steer

	# --- ACCELERATION (3 Zustände) ---
	# Handbremse: Hinterräder blockiert → kaum Vortrieb möglich
	var effective_max = max_speed if not handbrake_active else 60.0
	var effective_accel = base_acceleration if not handbrake_active else base_acceleration * 0.08
	
	if gas > 0:
		var speed_ratio = clamp(current_speed / effective_max, 0.0, 1.0)
		var accel = effective_accel * pow(max(1.0 - speed_ratio, 0.01), speed_accel_falloff)
		current_speed = move_toward(current_speed, effective_max * gas, accel * delta)
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

	# Drift-Speed-Verlust: progressiv (quadratisch) — bei hoher Speed viel, bei niedriger wenig
	if handbrake_active and abs(current_speed) > 30.0:
		var speed_factor = abs(current_speed) / max_speed
		var decel = drift_brake_decel * speed_factor * speed_factor
		current_speed = move_toward(current_speed, 0, decel * delta)

	# --- STEERING ---
	if abs(current_speed) > min_steer_speed:
		var speed_ratio = abs(current_speed) / max_speed
		var angular_speed = base_angular_speed / (1.0 + steering_tightness * pow(speed_ratio, 0.8))
		if handbrake_active:
			angular_speed *= 1.2 # Leicht schneller eindrehen, Fokus liegt aber auf dem Rutschen
		var reverse_factor = 1.0 if current_speed >= 0 else -1.0
		rotation += angular_speed * steer * delta * reverse_factor

	# --- DRIFT: Heck lateral rausschieben ---
	if handbrake_active and abs(current_speed) > 80.0:
		var right_dir = Vector2.RIGHT.rotated(rotation)
		# Normaler Drift-Kick beim Lenken
		velocity += right_dir * steer * abs(current_speed) * drift_kick_factor * delta
		# Destabilisierung geradeaus: Heck kann nicht fixiert bleiben
		if abs(steer) < 0.1:
			velocity += right_dir * randf_range(-1.0, 1.0) * abs(current_speed) * 0.15 * delta

	# --- TRACTION (Slip-Angle Forward/Lateral Decomposition) ---
	var forward_dir = Vector2.UP.rotated(rotation)

	# Rear grip: smooth transition zwischen normal und drift
	var target_rear_grip = drift_grip_rear if handbrake_active else grip_rear
	current_rear_grip = move_toward(current_rear_grip, target_rear_grip, grip_recovery_speed * delta)

	if velocity.length() > 5.0:
		var forward_component = forward_dir * velocity.dot(forward_dir)
		var lateral_component = velocity - forward_component
		
		#ungenutzt, keine ahnung
		var front_influence = clamp(grip_front * delta, 0.0, 1.0)
		var rear_influence = clamp(current_rear_grip * delta, 0.0, 1.0)

		# Seitwärts-Drift: Abhängig vom Heck-Grip! Wenig Heck-Grip = langes Rutschen
		lateral_component = lateral_component * (1.0 - rear_influence)

		# Vorwärts: Snap abhängig vom Heck-Grip — beim Drift bleibt Velocity träge
		var vel_forward = velocity.dot(forward_dir)
		var forward_snap = clamp(rear_influence * 2.0, 0.02, 1.0)
		var blended_forward = lerp(vel_forward, current_speed, forward_snap)

		velocity = forward_dir * blended_forward + lateral_component
	else:
		velocity = forward_dir * current_speed

	# Knockback drauf addieren
	velocity += knockback_velocity

	# --- MOVE ---
	if move_and_slide():
		_handle_collisions()

	server_position = position
	server_rotation = rotation

func _process(delta):
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	var is_remote = not is_multiplayer_authority()
	var forward_dir = Vector2.UP.rotated(rotation)
	var speed_ratio = clamp(abs(current_speed) / max_speed, 0.0, 1.0)

	var current_vel = velocity
	var rot_diff = 0.0
	if is_remote:
		current_vel = (position - last_pos) / max(delta, 0.0001)
		rot_diff = wrapf(rotation - last_rot, -PI, PI) / max(delta, 0.0001)

	var lateral_vel = current_vel - forward_dir * current_vel.dot(forward_dir)
	var is_drifting = handbrake_active and abs(current_speed) > 50.0
	#slipping für die zukunft
	var is_slipping = current_vel.length() > 50.0 and lateral_vel.length() > 20.0
	var is_skidding = is_drifting

	if smoke_particles:
		smoke_particles.emitting = true
		var smoke_alpha = lerp(0.05, 0.5, speed_ratio)
		smoke_particles.color = Color(0.4, 0.4, 0.4, smoke_alpha)

		if skid_left and skid_right:
			skid_left.emitting = is_skidding
			skid_right.emitting = is_skidding

	if sprite:
		var lean_target = current_steer
		if is_remote:
			lean_target = clamp(rot_diff * 0.2, -0.5, 0.5)
		if is_drifting:
			lean_target *= 1.2
		lean_target = clamp(lean_target, -0.5, 0.5)
		_smoothed_lean = lerp(_smoothed_lean, lean_target, delta * 4.0)

		# Minimaler Lean-Effekt für ein subtiles Fahrgefühl (fast unbewusst)
		var lean_factor = _smoothed_lean * speed_ratio
		sprite.skew = lean_factor * 0.1
		sprite.scale.x = 1.0 - abs(lean_factor) * 0.06
		sprite.position.x = lean_factor * 2.0

	if engine_sound and tire_squeal_sound:
		var remote_vol_offset = -14.0 if is_remote else 0.0
		
		var s_ratio = clamp(speed_ratio, 0.0, 1.0)
		engine_sound.pitch_scale = lerp(0.7, 1.3, s_ratio)
		engine_sound.volume_db = lerp(-20.0, -6.0, speed_ratio) + remote_vol_offset

		var slip_amount = 0.0
		if current_vel.length() > 30.0:
			slip_amount = lateral_vel.length() / max(current_vel.length(), 1.0)

		if slip_amount > 0.15 or is_drifting:
			var intensity = clamp(slip_amount / 0.6, 0.0, 1.0)
			if is_drifting:
				intensity = max(intensity, 0.5)
			tire_squeal_sound.volume_db = lerp(-25.0, -8.0, intensity) + remote_vol_offset
			if not tire_squeal_sound.playing:
				tire_squeal_sound.play()
		else:
			if tire_squeal_sound.playing:
				tire_squeal_sound.stop()

	last_pos = position
	last_rot = rotation

func _handle_collisions():
	for i in get_slide_collision_count():
		var collision = get_slide_collision(i)
		var collider = collision.get_collider()
		if collider is CharacterBody2D and collider.has_method("apply_impulse"):
			var push_dir = -collision.get_normal()
			var impact = clamp(abs(current_speed), 0.0, max_speed) / max_speed
			var force = impact * RAM_FORCE
			var target_id = collider.name.to_int()
			if target_id != multiplayer.get_unique_id():
				collider.apply_impulse.rpc_id(target_id, push_dir * force)
			# Kein Rückprall: Rammer wird nur gebremst, nicht zurückgeworfen
			current_speed *= 0.80
		else:
			# Wand-Kollision: spürbarer Speed-Verlust + Bounce
			current_speed *= wall_speed_retention
			var bounce = collision.get_normal() * abs(current_speed) * wall_bounce_factor
			velocity += bounce

@rpc("any_peer", "call_local", "reliable")
func apply_impulse(force_vector):
	knockback_velocity += force_vector
	current_speed *= 0.9
