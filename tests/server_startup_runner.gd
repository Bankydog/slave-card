extends Node

const ServerNetworkEndpointScript = preload("res://scripts/network/server_network_endpoint.gd")
const RoomServiceScript = preload("res://scripts/network/room_service.gd")
const Protocol = preload("res://scripts/network/network_protocol.gd")
const RoleSystemScript = preload("res://scripts/game/role_system.gd")

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

	var round_flow_ready := _test_room_service_round_flow(room_service)
	if round_flow_ready:
		print("SERVER START GAME PASS: first round and next round use GameState construction and emit expected messages.")
	else:
		push_error("SERVER START GAME FAIL: RoomService first-round or next-round flow did not complete.")

	endpoint.shutdown()
	endpoint.queue_free()
	get_tree().quit(0 if listener_ready and round_flow_ready else 1)

func _test_room_service_round_flow(room_service) -> bool:
	var emitted_types: Array[String] = []
	room_service.send_to_peer.connect(func(_peer_id: int, message: Dictionary) -> void:
		emitted_types.append(str(message.get("type", "")))
	)

	room_service.handle_message(101, Protocol.message(Protocol.CREATE_ROOM, {
		"name": "Startup Host",
		"max_players": 2,
		"match_round_limit": 4
	}))
	if not room_service.room_by_peer.has(101):
		return false
	var room_code := str(room_service.room_by_peer[101])

	room_service.handle_message(202, Protocol.message(Protocol.JOIN_ROOM, {
		"name": "Startup Guest",
		"room_code": room_code
	}))
	room_service.handle_message(101, Protocol.message(Protocol.SET_READY, {"ready": true}))
	room_service.handle_message(202, Protocol.message(Protocol.SET_READY, {"ready": true}))
	room_service.handle_message(101, Protocol.message(Protocol.START_GAME))

	var room: Dictionary = room_service.rooms[room_code]
	var first_game = room.get("game_state")
	if first_game == null:
		return false
	var first_starters: Array[int] = first_game.three_clubs_holders()
	var first_round_ready: bool = (
		str(room.get("phase", "")) == "playing"
		and int(room.get("round_number", 0)) == 1
		and first_game.players.size() == 2
		and first_starters.size() == 1
		and first_game.current_player == first_starters[0]
		and emitted_types.has(Protocol.START_GAME)
		and emitted_types.has(Protocol.DEAL)
		and emitted_types.has(Protocol.TURN_CHANGED)
	)
	if not first_round_ready:
		return false

	var finishing_order: Array[int] = [first_game.current_player, 1 - first_game.current_player]
	var role_result: Dictionary = RoleSystemScript.resolve(finishing_order, 2, {})
	if not bool(role_result.get("ok", false)):
		return false
	room.game_state.finishing_order = finishing_order
	room.roles_by_player = role_result.roles_by_player
	room.match_state.record_round(finishing_order)
	room.phase = "results"
	var first_game_id: int = first_game.get_instance_id()

	room_service.handle_message(101, Protocol.message(Protocol.START_NEXT_ROUND))
	var second_game = room.get("game_state")
	var next_round_ready: bool = (
		int(room.get("round_number", 0)) == 2
		and int(room.match_state.current_round) == 2
		and second_game != null
		and second_game.get_instance_id() != first_game_id
		and int(second_game.current_player) == finishing_order[0]
		and str(room.get("phase", "")) == "card_exchange"
		and emitted_types.count(Protocol.START_GAME) == 4
		and emitted_types.count(Protocol.DEAL) >= 4
		and emitted_types.has(Protocol.CARD_EXCHANGE)
	)
	return next_round_ready
