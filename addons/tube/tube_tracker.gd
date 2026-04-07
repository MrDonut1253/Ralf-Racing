class_name TubeTracker extends RefCounted


const MAX_INTERVAL := 120.0 #sec


signal failed
signal connected
signal disconnected
signal received_answer(data: Dictionary)
signal interval_timeout


signal warning_raised(message: String)
signal state_changed

signal data_sent(data: Dictionary)
signal received_data(data: Dictionary)

# Wird geworfen wenn die Reconnect-Logik einen neuen Verbindungsversuch
# startet. Praktisch fürs Logging im NetworkManager.
signal reconnecting(attempt: int, delay: float)
# Wird einmalig gefeuert sobald wir aufgegeben haben (max attempts erreicht).
signal reconnect_exhausted


const CLOSE_CODE_CLIENT: int = 3001
const CLOSE_CODE_FAILED: int = 3002
# https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/close, custom code 3000-4999
# https://www.rfc-editor.org/rfc/rfc6455.html#section-7.4.1


var error_message: String
var socket := WebSocketPeer.new()
var state := socket.get_ready_state()

var connecting_time: float = 0.0 #sec
var up_time: float = 0.0 #sec
var interval_time: float = 0.0 #sec
var interval_time_left: float = -1.0


# --- Reconnect/Robustheit ---
# Public Tracker (openwebtorrent.com & co) sind notorisch wackelig: TLS-Handshakes
# brechen ab, der Server schmeißt einen kurzzeitig raus oder das WLAN hickst.
# Statt die Verbindung dann komplett aufzugeben (was bedeutet dass keine neuen
# Spieler mehr joinen können), versuchen wir hier automatisch wiederzuverbinden.
# tube_client behandelt is_close()==false während des Reconnects so als wäre
# alles in Ordnung, damit die Session am Leben bleibt.

## URL die wir uns merken um sie für reconnect wieder benutzen zu können.
var url: String = ""

## Wenn true, versucht der Tracker nach einem CLOSED automatisch wieder zu verbinden.
## Wird vom tube_client nach connect_to_url() auf true gesetzt.
var auto_reconnect: bool = false

## Aktueller Reconnect-Versuchszähler. Wird nach erfolgreichem OPEN auf 0 gesetzt.
var reconnect_attempt: int = 0

## Maximale Anzahl Reconnect-Versuche bevor wir aufgeben. ~30 Versuche mit
## Backoff bedeuten in Summe rund 8-10 Minuten — sollte für temporäre Tracker-
## Aussetzer dicke reichen.
var max_reconnect_attempts: int = 30

## Cooldown bis zum nächsten Reconnect-Versuch (sec). Zählt im _process runter.
var reconnect_cooldown: float = 0.0

## Basis-Delay für exponentielles Backoff (sec).
var reconnect_base_delay: float = 2.0

## Obergrenze fürs Backoff (sec). Wir wollen nicht ewig warten zwischen Versuchen.
var reconnect_max_delay: float = 30.0

## true sobald wir mindestens einmal STATE_OPEN erreicht hatten. Hilft beim
## Debuggen ("hat es initial überhaupt jemals geklappt?").
var was_ever_open: bool = false

## true während wir auf den Cooldown bis zum nächsten Reconnect-Versuch warten.
## In dieser Zeit ist der Socket CLOSED, aber wir wollen NICHT als "tot" zählen.
var pending_reconnect: bool = false

## Letzter bekannter WebSocket close-Code. Praktisch für Debug-Output.
var last_close_code: int = 0
var last_close_reason: String = ""


func _to_string() -> String:
	var string := socket.get_requested_url()
	
	if "Web" != OS.get_name():
		if WebSocketPeer.STATE_OPEN == socket.get_ready_state():
			string += "({protocol}://{address}:{port})".format({
				"protocol": socket.get_selected_protocol(),
				"address": socket.get_connected_host(),
				"port": socket.get_connected_port(),
			})
	
	return string


func raise_warning(message: String):
	push_warning(message)
	warning_raised.emit(message)


func connect_to_url(p_url: String) -> Error:
	# URL für Reconnects merken (siehe _try_schedule_reconnect / _do_reconnect).
	url = p_url
	var error := socket.connect_to_url(p_url)
	if error:
		error_message = "connection failed: {error}".format({
			"error": error_string(error)
		})
		failed.emit()

	return error


func is_open() -> bool:
	return WebSocketPeer.STATE_OPEN == socket.get_ready_state()


## Liefert true wenn der WebSocket geschlossen ist UND wir auch keinen
## Reconnect mehr planen. Während eines Reconnect-Cooldowns liefert die Funktion
## bewusst false, damit tube_client den Tracker nicht aus der Liste wirft.
func is_close() -> bool:
	if pending_reconnect:
		return false
	return WebSocketPeer.STATE_CLOSED == socket.get_ready_state()


## true während wir auf den nächsten Reconnect-Versuch warten.
func is_reconnecting() -> bool:
	return pending_reconnect


## Setzt den Reconnect-Zähler zurück (z.B. nach erfolgreichem OPEN).
func _reset_reconnect_state() -> void:
	reconnect_attempt = 0
	reconnect_cooldown = 0.0
	pending_reconnect = false


## Plant einen Reconnect mit exponentiellem Backoff. Wird beim Übergang
## STATE_OPEN/CONNECTING -> STATE_CLOSED aufgerufen.
func _try_schedule_reconnect() -> void:
	if not auto_reconnect:
		return

	if url.is_empty():
		return

	if reconnect_attempt >= max_reconnect_attempts:
		# Aufgeben — pending_reconnect bleibt false, damit is_close() jetzt true
		# zurückgibt und tube_client den Tracker rauswirft.
		pending_reconnect = false
		reconnect_exhausted.emit()
		raise_warning("Tracker reconnect exhausted after %d attempts: %s" % [
			reconnect_attempt, url
		])
		return

	reconnect_attempt += 1

	# Exponentielles Backoff mit Cap. 1. Versuch ~2s, dann 3s, 4.5s, ... bis 30s.
	var delay: float = reconnect_base_delay * pow(1.5, float(reconnect_attempt - 1))
	if delay > reconnect_max_delay:
		delay = reconnect_max_delay

	reconnect_cooldown = delay
	pending_reconnect = true
	reconnecting.emit(reconnect_attempt, delay)


## Führt den eigentlichen Reconnect aus (wird vom _process aufgerufen sobald
## der Cooldown abgelaufen ist).
func _do_reconnect() -> void:
	pending_reconnect = false
	# Internen State zurücksetzen, sonst zählen connecting_time/up_time falsch.
	connecting_time = 0.0
	interval_time = 0.0
	interval_time_left = -1.0
	error_message = ""
	last_close_code = 0
	last_close_reason = ""

	# Wir brauchen einen frischen WebSocketPeer — Godot 4 erlaubt zwar
	# connect_to_url() auf einer existierenden Instanz, in der Praxis lässt
	# sich aber die TLS-Stream-Pipeline nach Fehlern nicht zuverlässig
	# wiederbeleben. Ein neuer Peer ist sauberer.
	socket = WebSocketPeer.new()
	state = socket.get_ready_state()

	var error := socket.connect_to_url(url)
	if error:
		error_message = "reconnect failed: %s" % error_string(error)
		# Direkt nochmal versuchen lassen (mit weiterem Backoff).
		_try_schedule_reconnect()


func close(p_info_hash: String, p_peer_id_hash: String):
	# Bewusst ausgelöster Close — kein Auto-Reconnect mehr.
	auto_reconnect = false
	pending_reconnect = false

	if is_open():
		send_stop(
			p_info_hash,
			p_peer_id_hash
		)

	if WebSocketPeer.STATE_CLOSED != socket.get_ready_state():
		socket.close(
			CLOSE_CODE_CLIENT,
			"Close by client",
		)


func _socket_connection_opened():
	connected.emit()


func _socket_connection_closed(p_code: int, p_reason: String):
	#if -1 == p_code: # error
	
	if WebSocketPeer.State.STATE_CONNECTING == state:
		error_message = "connection impossible"
	
	p_reason = p_reason if p_reason else "Closed unexpectedly, code: {code}".format({
		"code": p_code,
	})
	
	if WebSocketPeer.State.STATE_OPEN == state:
		error_message = "connection failed: {reason}".format({
			"reason": p_reason,
		})
	
	disconnected.emit()


## Encodes tracker packet data as JSON string.
func encode_data(data: Dictionary) -> String:
	var json := JSON.stringify(data)
	return json


## Decodes tracker packet data from a [PackedByteArray].
func decode_packet(p_packet: PackedByteArray) -> Variant:
	var string := p_packet.get_string_from_utf8()
	var data = JSON.parse_string(string)
	return data


func send_data(p_data: Dictionary) -> Error:
	var text := encode_data(p_data)
	var error := socket.send_text(
		text
	)
	
	if error:
		raise_warning(
			"Cannot send text: {error}".format({
			"error": error_string(error)
		}))
	
	else:
		data_sent.emit(p_data)
	
	return error


func send_announce(p_info_hash: String, p_peer_id_hash: String) -> Error:
	return send_data({
		"action": "announce",
		"info_hash": p_info_hash,
		"peer_id": p_peer_id_hash,
		
		"uploaded": 0,
		"downloaded": 0,
	})


func send_answer(
	p_info_hash: String,
	p_peer_id_hash: String,
	p_to_peer_id_hash: String,
	description: Dictionary,
	ice_candidates: Array
) -> Error:
	return send_data({
		"action": "announce",
		"info_hash": p_info_hash,
		"peer_id": p_peer_id_hash,
		
		"to_peer_id": p_to_peer_id_hash,
		"answer": {
			"type": description.type,
			"sdp": description.sdp,
			"ice_candidates": ice_candidates,
		},
		"offer_id": "0",
	})


func send_stop(p_info_hash: String, p_peer_id_hash: String) -> Error:
	return send_data({
	  "action": "announce",
	  "info_hash": p_info_hash,
	  "peer_id": p_peer_id_hash,
	  "event": "stopped"
	})


func _received_packet(p_packet: PackedByteArray):
	var data = decode_packet(p_packet)
	if not data is Dictionary:
		raise_warning("Received invalid packet: {packet}".format({
			"packet": str(p_packet)
		}))
		return
	
	received_data.emit(data)
	if data.has("answer"):
		_handle_answer(data)
		return
	
	_handle_announce(data)


func _handle_announce(p_data: Dictionary):
	if not p_data.has("interval"):
		raise_warning("announce data has no interval")
		return
	
	if not p_data.interval is float:
		raise_warning("interval invalid data type")
		return
	
	interval_time = min(p_data.interval, MAX_INTERVAL)
	interval_time_left = interval_time


func _handle_answer(p_data: Dictionary):
	if not p_data is Dictionary:
		raise_warning("answer data invalid data type")
		return
	
	if not p_data.has("peer_id"):
		raise_warning("answer data has no peer_id")
		return
	
	if not p_data.peer_id is String:
		raise_warning("peer_id invalid data type")
		return
	
	if not p_data.has("answer"):
		raise_warning("answer data has no answer")
		return
	
	if not p_data.answer is Dictionary:
		raise_warning("answer invalid data type")
		return
	
	var answer: Dictionary = p_data.answer
	if not answer.has("sdp"):
		raise_warning("answer data has no sdp")
	
	if not answer.sdp is String:
		raise_warning("sdp invalid data type")
		return
	
	if not answer.has("type"):
		raise_warning("answer data has no type")
		return
	
	if not answer.type is String:
		raise_warning("type invalid data type")
		return
	
	if not answer.has("ice_candidates"):
		raise_warning("answer data has no ice_candidates")
		return
	
	if not answer.ice_candidates is Array:
		raise_warning("ice_candidates invalid data type")
		return
	
	received_answer.emit(p_data)


static func get_peer_id_hash_from_answer_data(p_data: Dictionary) -> String:
	return p_data.peer_id


static func get_type_from_answer_data(p_data: Dictionary) -> String:
	return p_data.answer.type


static func get_sdp_from_answer_data(p_data: Dictionary) -> String:
	return p_data.answer.sdp


static func get_ice_candidates_from_answer_data(p_data: Dictionary) -> Array:
	return p_data.answer.ice_candidates


static func is_ice_candidate_data_valid(p_data: Variant) -> bool:
	if not p_data is Dictionary:
		push_error("Ice candidate data invalid data type")
		return false
	
	if not p_data.has("media"):
		push_error("Ice candidate data has no media")
		return false
	
	if not p_data.media is String:
		push_error("media invalid data type")
		return false
	
	if not p_data.has("index"):
		push_error("Ice candidate has no index")
		return false
	
	if not (typeof(p_data.index) in [TYPE_INT, TYPE_FLOAT]):
		push_error("index invalid data type")
		return false
	
	if not p_data.has("sdp"):
		push_error("Ice candidate has no sdp")
		return false
	
	if not p_data.sdp is String:
		push_error("Ice candidate sdp invalid data type")
		return false
	
	return true


static func get_media_from_ice_candidate_data(p_data: Dictionary) -> String:
	return p_data.media


static func get_index_from_ice_candidate_data(p_data: Dictionary) -> int:
	return int(p_data.index)


static func get_sdp_from_ice_candidate_data(p_data: Dictionary) -> String:
	return p_data.sdp


func _process(delta: float):
	# --- Reconnect-Cooldown ---
	# Während wir auf den nächsten Reconnect-Versuch warten ist der alte Socket
	# tot, ein poll() wäre sinnlos. Wir zählen nur den Cooldown runter und feuern
	# dann einen neuen Verbindungsversuch.
	if pending_reconnect:
		reconnect_cooldown -= delta
		if reconnect_cooldown <= 0.0:
			_do_reconnect()
		return

	socket.poll() # push error when 502 bad gateway, doesn't block anything

	var old_state := state
	state = socket.get_ready_state()
	if state != old_state:
		state_changed.emit()


	if WebSocketPeer.STATE_CONNECTING == state:
		connecting_time += delta

	if WebSocketPeer.STATE_OPEN == state:
		if WebSocketPeer.STATE_OPEN != old_state:
			_socket_connection_opened()
			# Nach erfolgreichem (Re-)Connect Backoff zurücksetzen damit der
			# nächste Aussetzer wieder mit voller Geduld neu probiert wird.
			was_ever_open = true
			_reset_reconnect_state()

		while socket.get_available_packet_count():
			var packet := socket.get_packet()
			_received_packet(packet)

		up_time += delta

		if 0.0 < interval_time:
			interval_time_left -= delta
			if interval_time_left < 0.0:
				interval_time_left = interval_time
				interval_timeout.emit()


	elif WebSocketPeer.STATE_CLOSING == state:
		# Keep polling to achieve proper close.
		pass

	elif WebSocketPeer.STATE_CLOSED == state:
		# Nur beim *Übergang* in CLOSED behandeln — sonst feuert der Code jeden
		# Frame neu, sobald der Socket einmal zu ist. (Das war im Original
		# fragwürdig, aber harmlos. Mit Reconnect-Logik wäre es ein Bug.)
		if WebSocketPeer.STATE_CLOSED != old_state:
			var code = socket.get_close_code()
			var reason = socket.get_close_reason()
			last_close_code = code
			last_close_reason = reason
			_socket_connection_closed(code, reason)
			# Auto-Reconnect anstoßen falls aktiviert.
			_try_schedule_reconnect()
