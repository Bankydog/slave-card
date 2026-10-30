extends Node

const ServerNetworkEndpointScript = preload("res://scripts/network/server_network_endpoint.gd")
const RoomServiceScript = preload("res://scripts/network/room_service.gd")

func _ready() -> void:
	var room_service = RoomServiceScript.new()
	var endpoint = ServerNetworkEndpointScript.new()
	add_child(endpoint)
	await get_tree().process_frame

	var listener_ready: bool = (
		room_service != null
		and endpoint.room_service != null
		and is_instance_valid(endpoint.room_service)
		and endpoint.socket_peer != null
		and endpoint.is_listening
		and multiplayer.multiplayer_peer == endpoint.socket_peer
	)
	if listener_ready:
		print("SERVER STARTUP PASS: ServerNetworkEndpoint, RoomService, and WebSocket listener initialized.")
	else:
		push_error("SERVER STARTUP FAIL: endpoint, RoomService, or WebSocket listener did not initialize.")

	endpoint.shutdown()
	endpoint.queue_free()
	get_tree().quit(0 if listener_ready else 1)
