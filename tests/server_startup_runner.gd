extends Node

const ServerNetworkEndpointScript = preload("res://scripts/network/server_network_endpoint.gd")
const RoomServiceScript = preload("res://scripts/network/room_service.gd")

func _ready() -> void:
	var room_service = RoomServiceScript.new()
	var endpoint = ServerNetworkEndpointScript.new()
	add_child(endpoint)
	await get_tree().process_frame

	var tcp_probe := StreamPeerTCP.new()
	var probe_error := tcp_probe.connect_to_host("127.0.0.1", endpoint.port)
	var listener_accepting := false
	for _attempt in range(20):
		tcp_probe.poll()
		if tcp_probe.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			listener_accepting = true
			break
		await get_tree().process_frame

	var listener_ready: bool = (
		room_service != null
		and endpoint.room_service != null
		and is_instance_valid(endpoint.room_service)
		and endpoint.socket_peer != null
		and multiplayer.multiplayer_peer == endpoint.socket_peer
		and probe_error == OK
		and listener_accepting
	)
	if listener_ready:
		print("SERVER STARTUP PASS: ServerNetworkEndpoint, RoomService, and WebSocket listener initialized.")
	else:
		push_error("SERVER STARTUP FAIL: endpoint, RoomService, or WebSocket listener did not initialize.")

	tcp_probe.disconnect_from_host()
	endpoint.shutdown()
	endpoint.queue_free()
	get_tree().quit(0 if listener_ready else 1)
