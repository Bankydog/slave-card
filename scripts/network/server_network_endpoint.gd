class_name ServerNetworkEndpoint
extends "res://scripts/network/network_endpoint.gd"

const RoomServiceScript = preload("res://scripts/network/room_service.gd")

const DEFAULT_PORT := 10000
const BIND_ADDRESS := "0.0.0.0"

var port: int = DEFAULT_PORT
var bind_address := BIND_ADDRESS
var socket_peer: WebSocketMultiplayerPeer
var room_service = RoomServiceScript.new()

static func _configured_port() -> int:
	var port_value := OS.get_environment("PORT").strip_edges()
	if port_value.is_empty():
		return DEFAULT_PORT
	if port_value.is_valid_int() and int(port_value) > 0 and int(port_value) <= 65535:
		return int(port_value)
	push_error("PORT must be an integer between 1 and 65535.")
	return -1

func _ready() -> void:
	port = _configured_port()
	if port < 1:
		get_tree().quit(1)
		return
	room_service.send_to_peer.connect(_send_to_peer)
	socket_peer = WebSocketMultiplayerPeer.new()
	var error := socket_peer.create_server(port, bind_address)
	if error != OK:
		push_error("Could not start WebSocket room server on port %d (error %d)." % [port, error])
		return
	multiplayer.multiplayer_peer = socket_peer
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("Slave Card WebSocket room server listening on %s:%d" % [bind_address, port])

func _process(delta: float) -> void:
	room_service.tick(delta)

func is_server_endpoint() -> bool:
	return true

func handle_client_message(peer_id: int, message: Dictionary) -> void:
	room_service.handle_message(peer_id, message)

func _on_peer_disconnected(peer_id: int) -> void:
	room_service.peer_disconnected(peer_id)

func _send_to_peer(peer_id: int, message: Dictionary) -> void:
	rpc_id(peer_id, "receive_message", message)

func shutdown() -> void:
	if socket_peer != null:
		socket_peer.close()
		socket_peer = null
	if is_inside_tree():
		multiplayer.multiplayer_peer = null
