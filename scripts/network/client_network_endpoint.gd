class_name ClientNetworkEndpoint
extends "res://scripts/network/network_endpoint.gd"

const Protocol = preload("res://scripts/network/network_protocol.gd")

signal message_received(message: Dictionary)
signal connection_status_changed(connected: bool, reason: String)

var socket_peer: WebSocketMultiplayerPeer
var connected := false

func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func connect_to_server(url: String) -> Error:
	disconnect_from_server()
	socket_peer = WebSocketMultiplayerPeer.new()
	var error := socket_peer.create_client(url)
	if error != OK:
		connection_status_changed.emit(false, "Could not open WebSocket connection.")
		return error
	multiplayer.multiplayer_peer = socket_peer
	return OK

func disconnect_from_server() -> void:
	if socket_peer != null:
		socket_peer.close()
		socket_peer = null
	connected = false
	if is_inside_tree():
		multiplayer.multiplayer_peer = null

func send_intent(message_type: String, payload: Dictionary = {}) -> bool:
	if not connected:
		return false
	var message := NetworkProtocol.message(message_type, payload)
	if message_type in [NetworkProtocol.START_GAME, NetworkProtocol.SELECT_RPS, NetworkProtocol.CONTINUE_RPS]:
		print("[MP Client] Request serialized: type=%s." % str(message.get("type", "")))
	rpc_id(1, "submit_message", message)
	if message_type in [NetworkProtocol.START_GAME, NetworkProtocol.SELECT_RPS, NetworkProtocol.CONTINUE_RPS]:
		print("[MP Client] WebSocket RPC queued: type=%s." % message_type)
	return true

func handle_server_message(message: Dictionary) -> void:
	message_received.emit(message)

func _on_connected_to_server() -> void:
	connected = true
	connection_status_changed.emit(true, "")

func _on_connection_failed() -> void:
	connected = false
	connection_status_changed.emit(false, "Could not connect to the room server.")

func _on_server_disconnected() -> void:
	connected = false
	connection_status_changed.emit(false, "The room server disconnected.")
