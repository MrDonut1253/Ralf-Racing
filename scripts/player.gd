extends CharacterBody2D

# Referenz zum Game-Node
@onready var game: Node = $"../Game"


# Konstanten
var max_speed = 450.0
var acceleration = 400.0
var deceleration = 700.0
var base_angular_speed = PI * 1.2
var steering_factor = 1.3
var current_speed = 0.0
# Konstanten für Kollisionsdämpfung
var collision_speed_loss = 0.85  # 15% Geschwindigkeitsverlust
var collision_acceleration_loss = 0.12  # 12% Beschleunigungsverlust
var collision_recovery_time = 0.75  # 0.75 Sekunden Wiederherstellungszeit
var collision_timer = 0.0
var current_acceleration = acceleration

func _ready() -> void:
	if name == "Player1":
		var audio_auto: AudioStreamPlayer2D = $audio_auto
		audio_auto.play()
	

func _physics_process(delta):
	if game.start == true:
		# Timer für Kollisionswiederherstellung
		if collision_timer > 0:
			collision_timer -= delta
			# Lineare Interpolation der Beschleunigung
			var t = 1.0 - (collision_timer / collision_recovery_time)
			current_acceleration = lerp(acceleration * (1 - collision_acceleration_loss), acceleration, t)
		else:
			current_acceleration = acceleration

		# Lenkung
		var direction = 0
		if name == "Player1":
			if Input.is_action_pressed("p1_left"):
				direction = -1
			elif Input.is_action_pressed("p1_right"):
				direction = 1
		if name == "Player2":
			if Input.is_action_pressed("p2_left"):
				direction = -1
			elif Input.is_action_pressed("p2_right"):
				direction = 1

		var angular_speed = base_angular_speed / (1 + steering_factor * abs(current_speed / max_speed))
		if abs(current_speed) > 5.0:
			rotation += angular_speed * direction * delta

		# Geschwindigkeit
		var intended_speed = 0.0
		if name == "Player1":
			if Input.is_action_pressed("p1_up"):
				intended_speed = max_speed
			elif Input.is_action_pressed("p1_down"):
				intended_speed = -max_speed * 0.6
		if name == "Player2":
			if Input.is_action_pressed("p2_up"):
				intended_speed = max_speed
			elif Input.is_action_pressed("p2_down"):
				intended_speed = -max_speed * 0.6

		if (intended_speed > 0 and current_speed >= 0) or (intended_speed < 0 and current_speed <= 0):
			if intended_speed > 0:
				current_speed = min(current_speed + current_acceleration * delta, max_speed)
			else:
				current_speed = max(current_speed - current_acceleration * delta, -max_speed)
		else:
			if current_speed > 0:
				current_speed = max(current_speed - deceleration * delta, 0)
			elif current_speed < 0:
				current_speed = min(current_speed + deceleration * delta, 0)

		# Bewegung mit move_and_slide (inkl. Kollision)
		velocity = Vector2.UP.rotated(rotation) * current_speed
		var collision = move_and_slide()

		# Kollisionsabfrage
		if collision:
			# Geschwindigkeit bei Kollision reduzieren
			current_speed *= collision_speed_loss
			# Beschleunigung temporär reduzieren
			current_acceleration = acceleration * (1 - collision_acceleration_loss)
			# Timer für Wiederherstellung setzen
			collision_timer = collision_recovery_time
