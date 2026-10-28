extends Node

const Protocol = preload("res://scripts/network/network_protocol.gd")

@export var room_code := "Y5PM7S"
@onready var endpoint = $MultiplayerFlow/NetworkEndpoint
var received_lobby := false

func _ready() -> void:
	endpoint.message_received.connect(_on_message)
	endpoint.connection_status_changed.connect(_on_connection_status)
	var error: Error = endpoint.connect_to_server("ws://127.0.0.1:9080")
	if error != OK:
		push_error("Client could not start its WebSocket connection.")
		get_tree().quit(1)
		return
	get_tree().create_timer(10.0).timeout.connect(_on_timeout)

func _on_connection_status(connection_ready: bool, _reason: String) -> void:
	if connection_ready:
		endpoint.send_intent(Protocol.JOIN_ROOM, {"name":"Friend", "room_code":room_code})

func _on_message(message: Dictionary) -> void:
	if message.type == Protocol.LOBBY_STATE:
		var payload: Dictionary = message.payload
		if int(payload.players.size()) >= 2 and int(payload.your_player_index) == 1:
			received_lobby = true
			print("NETWORK PASS: second client joined room ", room_code, " and received lobby state")
			endpoint.send_intent(Protocol.LEAVE_ROOM)
			get_tree().create_timer(0.25).timeout.connect(func() -> void: get_tree().quit(0))
	elif message.type == Protocol.ACTION_REJECTED:
		push_error("Network room join rejected: " + str(message.payload.get("reason", "unknown")))
		get_tree().quit(1)

func _on_timeout() -> void:
	if not received_lobby:
		push_error("Network client timed out waiting for lobby state.")
		get_tree().quit(1)
