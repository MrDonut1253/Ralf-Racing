extends Node

@onready var countdown_label = get_node("../HUD/CountdownLabel")
@onready var timer_p1_label = get_node("../HUD/TimerPlayer1")
@onready var timer_p2_label = get_node("../HUD/TimerPlayer2")
@onready var runden_p1_label = get_node("../HUD/RundenPlayer1")
@onready var runden_p2_label = get_node("../HUD/RundenPlayer2")

@onready var audio_start = get_node("../audio_start")

var countdown_value = 4
var timer = 0.0
var is_counting_down = true
var start = false
var countdown_go_timer = 0.0
var total_laps = 3

var players = {
	"Player1": {
		"stopwatch_time": 0.0,
		"lap_start_time": 0.0,
		"completed_laps": 0,
		"lap_times": [],
		"next_checkpoint": 1,
		"finish_time": 0.0
	},
	"Player2": {
		"stopwatch_time": 0.0,
		"lap_start_time": 0.0,
		"completed_laps": 0,
		"lap_times": [],
		"next_checkpoint": 1,
		"finish_time": 0.0
	}
}

func _ready():
	await get_tree().create_timer(0.55).timeout  # 0.55 Sekunden warten
	audio_start.play()

func _process(delta):
	if Input.is_action_pressed("exit"):
		get_tree().change_scene_to_file("res://levels/menu.tscn")
	
	if is_counting_down:
		timer += delta
		print(timer)
		if timer >= 1.0:
			timer -= 1.0
			countdown_value -= 1
			if countdown_value > 0:
				countdown_label.text = str(countdown_value)
			elif countdown_value == 0:
				countdown_label.text = "GO!"
				countdown_go_timer = 2.0
				is_counting_down = false
				start = true
				for name in players:
					players[name]["lap_start_time"] = 0.0
	else:
		if countdown_go_timer > 0.0:
			countdown_go_timer -= delta
			if countdown_go_timer <= 0.0:
				countdown_label.text = ""

	if start:
		for name in players:
			if players[name]["completed_laps"] < total_laps:
				players[name]["stopwatch_time"] += delta

		var p1_lap_time = players["Player1"]["stopwatch_time"] - players["Player1"]["lap_start_time"]
		var p2_lap_time = players["Player2"]["stopwatch_time"] - players["Player2"]["lap_start_time"]

		timer_p1_label.text = "Laptime: %.2f s" % p1_lap_time
		timer_p2_label.text = "Laptime: %.2f s" % p2_lap_time
		runden_p1_label.text = "Completed Laps: %d / %d" % [players["Player1"]["completed_laps"], total_laps]
		runden_p2_label.text = "Completed Laps: %d / %d" % [players["Player2"]["completed_laps"], total_laps]

func on_checkpoint_entered(body, checkpoint_num):
	if not start or not players.has(body.name):
		return

	var player = players[body.name]
	if checkpoint_num == player["next_checkpoint"]:
		player["next_checkpoint"] += 1
		print("Checkpoint %d reached by %s" % [checkpoint_num, body.name])

func on_start_finish_entered(body):
	if not start or not players.has(body.name):
		return

	var player = players[body.name]
	if player["next_checkpoint"] == 4:
		var lap_time = player["stopwatch_time"] - player["lap_start_time"]
		player["lap_times"].append(lap_time)
		player["lap_start_time"] = player["stopwatch_time"]
		player["completed_laps"] += 1
		player["next_checkpoint"] = 1
		print("%s completed lap %d: %.2f seconds" % [body.name, player["completed_laps"], lap_time])

		if player["completed_laps"] == total_laps:
			player["finish_time"] = player["stopwatch_time"]
			print("%s finished! Total time: %.2f seconds" % [body.name, player["finish_time"]])
			if players["Player1"]["completed_laps"] >= total_laps and players["Player2"]["completed_laps"] >= total_laps:
				_game_over()

func _game_over():
	start = false
	var t1 = players["Player1"]["finish_time"]
	var t2 = players["Player2"]["finish_time"]
	var winner_text = ""
	if t1 < t2:
		winner_text = "Blue car wins! (%.2f s vs %.2f s)" % [t1, t2]
	elif t2 < t1:
		winner_text = "Red car wins! (%.2f s vs %.2f s)" % [t2, t1]
	else:
		winner_text = "Tie! (%.2f s)" % t1
	countdown_label.text = "Game Over\n" + winner_text + "\nPress escape to exit"


func on_start_finish_body_entered(body: Node2D) -> void:
	on_start_finish_entered(body)

func on_checkpoint_1_body_entered(body: Node2D) -> void:
	on_checkpoint_entered(body, 1)

func on_checkpoint_2_body_entered(body: Node2D) -> void:
	on_checkpoint_entered(body, 2)

func on_checkpoint_3_body_entered(body: Node2D) -> void:
	on_checkpoint_entered(body, 3)
