class_name ServerNetworkEndpoint
extends "res://scripts/network/network_endpoint.gd"

const RoomServiceScript = preload("res://scripts/network/room_service.gd")

const DEFAULT_PORT := 10000
const BIND_ADDRESS := "0.0.0.0"
const INTERNAL_DEFAULT_PORT := 10001

var port: int = DEFAULT_PORT
var bind_address := BIND_ADDRESS
var socket_peer: WebSocketMultiplayerPeer
var room_service
var is_listening := false

static func _configured_port() -> int:
	var port_value := OS.get_environment("GODOT_PORT").strip_edges()
	if port_value.is_empty():
		if OS.get_environment("GODOT_BIND_ADDRESS").strip_edges() == "127.0.0.1":
			return INTERNAL_DEFAULT_PORT
		port_value = OS.get_environment("PORT").strip_edges()
	if port_value.is_empty():
		return DEFAULT_PORT
	if port_value.is_valid_int() and int(port_value) > 0 and int(port_value) <= 65535:
		return int(port_value)
	push_error("GODOT_PORT or PORT must be an integer between 1 and 65535.")
	return -1

func _ready() -> void:
	room_service = RoomServiceScript.new()
	if room_service == null or not is_instance_valid(room_service):
		push_error("FATAL: Could not create RoomService; stopping server.")
		get_tree().quit(1)
		return
	room_service.send_to_peer.connect(_send_to_peer)
	port = _configured_port()
	if port < 1:
		get_tree().quit(1)
		return
	socket_peer = WebSocketMultiplayerPeer.new()
	var configured_bind_address := OS.get_environment("GODOT_BIND_ADDRESS").strip_edges()
	if not configured_bind_address.is_empty():
		bind_address = configured_bind_address
	var error := socket_peer.create_server(port, bind_address)
	if error != OK:
		push_error("Could not start WebSocket room server on port %d (error %d)." % [port, error])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = socket_peer
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	is_listening = true
	print("Slave Card WebSocket room server listening on %s:%d" % [bind_address, port])
	print("GODOT_BACKEND_READY")

func _process(delta: float) -> void:
	if room_service == null:
		return
	room_service.tick(delta)

func is_server_endpoint() -> bool:
	return true

func handle_client_message(peer_id: int, message: Dictionary) -> void:
	var message_type := str(message.get("type", ""))
	if message_type in ["start_game", "select_rps", "continue_rps"]:
		print("[MP Server] Dispatching request: peer=%d type=%s." % [peer_id, message_type])
	room_service.handle_message(peer_id, message)

func _on_peer_disconnected(peer_id: int) -> void:
	room_service.peer_disconnected(peer_id)

func _send_to_peer(peer_id: int, message: Dictionary) -> void:
	var message_type := str(message.get("type", ""))
	if message_type in ["start_game", "deal", "rps_state", "turn_changed", "action_rejected"]:
		print("[MP Server] RPC queued: peer=%d type=%s." % [peer_id, message_type])
	rpc_id(peer_id, "receive_message", message)

func shutdown() -> void:
	is_listening = false
	if socket_peer != null:
		socket_peer.close()
		socket_peer = null
	if is_inside_tree():
		multiplayer.multiplayer_peer = null
