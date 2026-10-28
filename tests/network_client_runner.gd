extends Node

const Protocol = preload("res://scripts/network/network_protocol.gd")

@export var room_code := "Y5PM7S"
@onready var endpoint = $MultiplayerFlow/NetworkEndpoint
var mode := "join"
var server_url := "ws://127.0.0.1:9080"
var host_room_code := ""
var start_requested := false
var received_lobby := false

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		server_url = args[0]
	if args.size() > 1:
		mode = args[1]
	if args.size() > 2:
		room_code = args[2]
	endpoint.message_received.connect(_on_message)
	endpoint.connection_status_changed.connect(_on_connection_status)
	var error: Error = endpoint.connect_to_server(server_url)
	if error != OK:
		push_error("Client could not start its WebSocket connection.")
		get_tree().quit(1)
		return
	get_tree().create_timer(20.0).timeout.connect(_on_timeout)

func _on_connection_status(connection_ready: bool, _reason: String) -> void:
	if not connection_ready:
		return
	if mode == "host":
		endpoint.send_intent(Protocol.CREATE_ROOM, {"name":"Proxy Host", "max_players":2})
	else:
		endpoint.send_intent(Protocol.JOIN_ROOM, {"name":"Proxy Guest", "room_code":room_code})

func _on_message(message: Dictionary) -> void:
	if message.type == Protocol.ROOM_CREATED and mode == "host":
		host_room_code = str(message.payload.get("room_code", ""))
		print("PROXY TEST ROOM CODE: ", host_room_code)
	elif message.type == Protocol.LOBBY_STATE:
		var payload: Dictionary = message.payload
		if mode == "join" and int(payload.players.size()) >= 2 and int(payload.your_player_index) == 1:
			received_lobby = true
			print("NETWORK JOIN PASS: guest joined through WebSocket endpoint")
		elif mode == "host" and int(payload.players.size()) >= 2 and not start_requested:
			start_requested = true
			get_tree().create_timer(0.5).timeout.connect(_start_game)
	elif message.type == Protocol.DEAL and mode == "host" and start_requested:
		print("NETWORK CREATE/JOIN/START PASS: host created room, guest joined, and game started")
		get_tree().quit(0)
	elif message.type == Protocol.DEAL and mode == "join" and received_lobby:
		print("NETWORK JOIN/START PASS: guest received game deal")
		endpoint.send_intent(Protocol.LEAVE_ROOM)
		get_tree().create_timer(0.25).timeout.connect(func() -> void: get_tree().quit(0))
	elif message.type == Protocol.ACTION_REJECTED:
		push_error("Proxy network action rejected: " + str(message.payload.get("reason", "unknown")))
		get_tree().quit(1)

func _start_game() -> void:
	endpoint.send_intent(Protocol.START_GAME, {"fill_bots":false})

func _on_timeout() -> void:
	if mode == "join" and not received_lobby:
		push_error("Network client timed out waiting for lobby state.")
	elif mode == "host" and not start_requested:
		push_error("Network test host timed out waiting for the guest to join.")
	elif mode == "host":
		push_error("Network test host timed out waiting for the game to start.")
	get_tree().quit(1)
