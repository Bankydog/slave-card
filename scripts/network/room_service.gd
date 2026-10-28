class_name RoomService
extends RefCounted

signal send_to_peer(peer_id: int, message: Dictionary)

const GameStateScript = preload("res://scripts/game/game_state.gd")
const BotBrainScript = preload("res://scripts/ai/bot_brain.gd")
const RoleSystemScript = preload("res://scripts/game/role_system.gd")
const CardExchangeScript = preload("res://scripts/game/card_exchange.gd")
const Protocol = preload("res://scripts/network/network_protocol.gd")

var rooms: Dictionary = {}
var room_by_peer: Dictionary = {}
var rng := RandomNumberGenerator.new()
var next_bot_name := 1

func _init() -> void:
	rng.randomize()

func handle_message(peer_id: int, message: Dictionary) -> void:
	var message_type := str(message.get("type", ""))
	var payload: Dictionary = message.get("payload", {})
	match message_type:
		Protocol.CREATE_ROOM:
			_create_room(peer_id, payload)
		Protocol.JOIN_ROOM:
			_join_room(peer_id, payload)
		Protocol.LEAVE_ROOM:
			_leave_room(peer_id)
		Protocol.START_GAME:
			_start_game(peer_id, payload)
		Protocol.SET_READY:
			_set_ready(peer_id, payload)
		Protocol.START_NEXT_ROUND:
			_start_next_round(peer_id)
		Protocol.PLAY_CARDS:
			_play_cards(peer_id, payload)
		Protocol.PASS:
			_pass(peer_id)
		Protocol.SELECT_CARDS:
			_select_cards(peer_id, payload)
		_:
			_reject(peer_id, "Unknown action.")

func peer_disconnected(peer_id: int) -> void:
	_leave_room(peer_id, true)

func tick(delta: float) -> void:
	for room_code in rooms.keys():
		var room: Dictionary = rooms[room_code]
		if room.phase != "playing" or room.get("game_state") == null:
			continue
		room.bot_delay = float(room.get("bot_delay", 0.0)) + delta
		if room.bot_delay < 0.45:
			continue
		room.bot_delay = 0.0
		var game = room.game_state
		var player_index: int = game.current_player
		if player_index < 0 or player_index >= room.members.size():
			continue
		var member: Dictionary = room.members[player_index]
		if not member.is_bot:
			continue
		var hand: Array = game.players[player_index].hand
		var bot = BotBrainScript.new()
		var cards: Array = bot.choose_play(hand, game.current_cards, game.rules)
		if cards.is_empty():
			_apply_pass(room, player_index)
		else:
			var card_ids: Array[String] = []
			for card in cards:
				card_ids.append(card.card_id())
			_apply_play(room, player_index, card_ids)

func _create_room(peer_id: int, payload: Dictionary) -> void:
	if room_by_peer.has(peer_id):
		_reject(peer_id, "Leave your current room first.")
		return
	var max_players := clampi(int(payload.get("max_players", 8)), 2, 12)
	var code := _new_room_code()
	var name := _guest_name(str(payload.get("name", "")))
	var member := {"peer_id": peer_id, "name": name, "is_bot": false, "ready": false}
	var room := {
		"code": code,
		"host_peer": peer_id,
		"max_players": max_players,
		"members": [member],
		"phase": "lobby",
		"round_number": 0,
		"roles_by_player": {},
		"game_state": null,
		"exchange": null,
		"bot_delay": 0.0,
		"last_finished_count": 0
	}
	rooms[code] = room
	room_by_peer[peer_id] = code
	_send(peer_id, Protocol.ROOM_CREATED, {"room_code": code, "max_players": max_players, "host": true})
	_broadcast_lobby(room)

func _join_room(peer_id: int, payload: Dictionary) -> void:
	if room_by_peer.has(peer_id):
		_reject(peer_id, "Leave your current room first.")
		return
	var code := str(payload.get("room_code", "")).strip_edges().to_upper()
	if not rooms.has(code):
		_reject(peer_id, "Room code not found.")
		return
	var room: Dictionary = rooms[code]
	if room.phase != "lobby":
		_reject(peer_id, "This game has already started.")
		return
	if room.members.size() >= int(room.max_players):
		_reject(peer_id, "This room is full.")
		return
	var member := {"peer_id": peer_id, "name": _guest_name(str(payload.get("name", ""))), "is_bot": false, "ready": false}
	room.members.append(member)
	room_by_peer[peer_id] = code
	var player_index: int = room.members.size() - 1
	_broadcast(room, Protocol.PLAYER_JOINED, {"player_index": player_index, "name": member.name})
	_broadcast_lobby(room)

func _leave_room(peer_id: int, disconnected: bool = false) -> void:
	if not room_by_peer.has(peer_id):
		return
	var code: String = room_by_peer[peer_id]
	room_by_peer.erase(peer_id)
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	var departed_index := -1
	for i in range(room.members.size()):
		if int(room.members[i].peer_id) == peer_id:
			departed_index = i
			break
	if departed_index < 0:
		return
	var departed: Dictionary = room.members[departed_index]
	if room.phase == "lobby":
		room.members.remove_at(departed_index)
		if room.members.is_empty():
			rooms.erase(code)
			return
		if int(room.host_peer) == peer_id:
			room.host_peer = int(room.members[0].peer_id)
	else:
		# A disconnected player remains as an empty seat for this prototype.
		departed.peer_id = 0
		departed.name = "%s (disconnected)" % departed.name
		departed.is_bot = true
		if int(room.host_peer) == peer_id:
			room.host_peer = _first_connected_peer(room)
	_broadcast(room, Protocol.PLAYER_LEFT, {"player_index": departed_index, "name": departed.name, "disconnected": disconnected})
	_broadcast_lobby(room)

func _start_game(peer_id: int, payload: Dictionary) -> void:
	var room = _room_for_peer(peer_id)
	if room == null:
		_reject(peer_id, "You are not in a room.")
		return
	if int(room.host_peer) != peer_id:
		_reject(peer_id, "Only the host can start the game.")
		return
	if room.phase != "lobby":
		_reject(peer_id, "The game is already running.")
		return
	if not _all_humans_ready(room):
		_reject(peer_id, "All human players must be Ready before starting.")
		return
	var fill_bots := bool(payload.get("fill_bots", false))
	var final_count: int = int(room.max_players) if fill_bots else room.members.size()
	if final_count < 2:
		_reject(peer_id, "At least two seats are needed. Add bots or invite a player.")
		return
	if fill_bots:
		while room.members.size() < int(room.max_players):
			room.members.append({"peer_id": 0, "name": "Bot %d" % next_bot_name, "is_bot": true, "ready": true})
			next_bot_name += 1
	_start_round(room)

func _set_ready(peer_id: int, payload: Dictionary) -> void:
	var room = _room_for_peer(peer_id)
	if room == null or room.phase != "lobby":
		_reject(peer_id, "Ready can only be changed while in a lobby.")
		return
	var player_index := _player_index_for_peer(room, peer_id)
	if player_index < 0 or bool(room.members[player_index].get("is_bot", false)):
		_reject(peer_id, "Only a human lobby player can change Ready.")
		return
	room.members[player_index]["ready"] = bool(payload.get("ready", false))
	_broadcast_lobby(room)

func _all_humans_ready(room: Dictionary) -> bool:
	for member in room.members:
		if not bool(member.get("is_bot", false)) and not bool(member.get("ready", false)):
			return false
	return true

func _start_next_round(peer_id: int) -> void:
	var room = _room_for_peer(peer_id)
	if room == null:
		_reject(peer_id, "You are not in a room.")
		return
	if int(room.host_peer) != peer_id:
		_reject(peer_id, "Only the host can start the next round.")
		return
	if room.phase != "results":
		_reject(peer_id, "The previous round has not finished.")
		return
	_start_round(room)

func _start_round(room: Dictionary) -> void:
	var round_starter := -1
	var previous_game = room.game_state
	if previous_game != null and not previous_game.finishing_order.is_empty():
		round_starter = previous_game.finishing_order[0]
	room.round_number = int(room.round_number) + 1
	room.game_state = GameStateScript.new()
	room.game_state.start(room.members.size(), 0, round_starter)
	for i in range(room.members.size()):
		var member: Dictionary = room.members[i]
		room.game_state.players[i].name = str(member.name)
		room.game_state.players[i].is_human = not bool(member.is_bot)
		room.game_state.players[i]["is_bot"] = bool(member.is_bot)
		room.game_state.players[i]["role"] = str(room.roles_by_player.get(i, ""))
	room.last_finished_count = 0
	room.bot_delay = 0.0

	var phase := "playing"
	var exchange_summary := {"ok": true, "pending_count": 0}
	if int(room.round_number) > 1:
		room.exchange = CardExchangeScript.new()
		var bot_flags: Array[bool] = []
		for member in room.members:
			bot_flags.append(bool(member.is_bot))
		exchange_summary = room.exchange.begin(room.game_state.players, room.roles_by_player, bot_flags)
		if not exchange_summary.ok:
			_reject(int(room.host_peer), str(exchange_summary.error))
			room.phase = "results"
			return
		phase = "card_exchange" if not room.exchange.is_complete() else "playing"
	else:
		room.exchange = null
	room.phase = phase
	_broadcast(room, Protocol.START_GAME, {
		"room_code": room.code,
		"round_number": room.round_number,
		"player_count": room.members.size(),
		"phase": room.phase,
		"roles_by_player": room.roles_by_player.duplicate(true),
		"players": _public_players(room)
	})
	_send_deals(room)
	if room.exchange != null:
		_broadcast_exchange(room, exchange_summary)
	if room.phase == "playing":
		_broadcast_turn(room)

func _play_cards(peer_id: int, payload: Dictionary) -> void:
	var room = _room_for_peer(peer_id)
	if room == null or room.phase != "playing":
		_reject(peer_id, "Cards can only be played during a round.")
		return
	var player_index := _player_index_for_peer(room, peer_id)
	var submitted: Variant = payload.get("card_ids", [])
	if not submitted is Array:
		_reject(peer_id, "Card IDs must be submitted as a list.")
		return
	if player_index < 0 or bool(room.members[player_index].is_bot):
		_reject(peer_id, "This player cannot act.")
		return
	_apply_play(room, player_index, submitted)

func _pass(peer_id: int) -> void:
	var room = _room_for_peer(peer_id)
	if room == null or room.phase != "playing":
		_reject(peer_id, "Passing is only available during a round.")
		return
	var player_index := _player_index_for_peer(room, peer_id)
	if player_index < 0 or bool(room.members[player_index].is_bot):
		_reject(peer_id, "This player cannot act.")
		return
	_apply_pass(room, player_index)

func _select_cards(peer_id: int, payload: Dictionary) -> void:
	var room = _room_for_peer(peer_id)
	if room == null or room.phase != "card_exchange" or room.exchange == null:
		_reject(peer_id, "No card exchange is waiting.")
		return
	var player_index := _player_index_for_peer(room, peer_id)
	if player_index < 0 or bool(room.members[player_index].is_bot):
		_reject(peer_id, "This player cannot select cards.")
		return
	var submitted: Variant = payload.get("card_ids", [])
	if not submitted is Array:
		_reject(peer_id, "Card IDs must be submitted as a list.")
		return
	var result: Dictionary = room.exchange.select_return_cards(player_index, submitted, room.game_state.players)
	if not result.ok:
		_reject(peer_id, str(result.error))
		return
	_send_deals(room)
	_broadcast_exchange(room, result)
	if room.exchange.is_complete():
		room.phase = "playing"
		_broadcast(room, Protocol.CARD_EXCHANGE, {"phase": "complete", "readiness": room.exchange.readiness_by_role()})
		_broadcast_turn(room)

func _apply_play(room: Dictionary, player_index: int, card_ids: Array) -> void:
	if room.phase != "playing":
		_reject_player(room, player_index, "The round is not in the playing phase.")
		return
	if player_index != room.game_state.current_player:
		_reject_player(room, player_index, "It is not this player's turn.")
		return
	if card_ids.is_empty():
		_reject_player(room, player_index, "Select at least one card to play.")
		return
	var hand: Array = room.game_state.players[player_index].hand
	var chosen: Array = []
	var seen_ids := {}
	for value in card_ids:
		var card_id := str(value)
		if seen_ids.has(card_id):
			_reject_player(room, player_index, "A card was submitted more than once.")
			return
		seen_ids[card_id] = true
		var owned_card
		for item in hand:
			if item.card_id() == card_id:
				owned_card = item
				break
		if owned_card == null:
			_reject_player(room, player_index, "A selected card is not in this player's hand.")
			return
		chosen.append(owned_card)
	if not room.game_state.play_cards(player_index, chosen):
		_reject_player(room, player_index, "That combination cannot be played.")
		return
	_after_action(room)

func _apply_pass(room: Dictionary, player_index: int) -> void:
	if room.phase != "playing" or player_index != room.game_state.current_player:
		_reject_player(room, player_index, "Passing is not valid now.")
		return
	if not room.game_state.pass_turn(player_index):
		_reject_player(room, player_index, "Passing is not valid now.")
		return
	_after_action(room)

func _after_action(room: Dictionary) -> void:
	var game = room.game_state
	var finished_count: int = game.finishing_order.size()
	if finished_count > int(room.last_finished_count):
		var newly_finished: int = game.finishing_order[finished_count - 1]
		room.last_finished_count = finished_count
		_broadcast(room, Protocol.PLAYER_FINISHED, {
			"player_index": newly_finished,
			"name": room.members[newly_finished].name,
			"place": finished_count
		})
	_broadcast(room, Protocol.TURN_CHANGED, _public_turn(room))
	_send_deals(room)
	if finished_count == room.members.size():
		_finish_round(room)

func _finish_round(room: Dictionary) -> void:
	var resolution: Dictionary = RoleSystemScript.resolve(room.game_state.finishing_order, room.members.size(), room.roles_by_player)
	if not resolution.ok:
		room.phase = "results"
		_broadcast(room, Protocol.ACTION_REJECTED, {"reason": resolution.error})
		return
	room.roles_by_player = resolution.roles_by_player
	for i in range(room.members.size()):
		room.members[i]["role"] = str(room.roles_by_player.get(i, ""))
	room.phase = "results"
	var role_payload := {
		"roles_by_player": room.roles_by_player.duplicate(true),
		"previous_king_demoted": resolution.previous_king_demoted,
		"previous_king_player": resolution.previous_king_player
	}
	_broadcast(room, Protocol.ROLES_ASSIGNED, role_payload)
	_broadcast(room, Protocol.ROUND_FINISHED, {
		"round_number": room.round_number,
		"finishing_order": room.game_state.finishing_order.duplicate(),
		"roles_by_player": room.roles_by_player.duplicate(true),
		"previous_king_demoted": resolution.previous_king_demoted,
		"next_round_available": true
	})
	_broadcast_lobby(room)

func _send_deals(room: Dictionary) -> void:
	for i in range(room.members.size()):
		var member: Dictionary = room.members[i]
		if bool(member.is_bot) or int(member.peer_id) <= 0:
			continue
		var hand: Array = room.game_state.players[i].hand
		var exchange_data: Array = []
		if room.exchange != null:
			exchange_data = room.exchange.transfers_for_player(i)
		_send(int(member.peer_id), Protocol.DEAL, {
			"player_index": i,
			"player_count": room.members.size(),
			"round_number": room.round_number,
			"phase": room.phase,
			"hand": _serialize_hand(hand),
			"role": str(room.roles_by_player.get(i, "")),
			"exchange_return_count": room.exchange.pending_amount_for(i) if room.exchange != null else 0,
			"exchange_role": room.exchange.role_for_player(i) if room.exchange != null else "",
				"exchange_mandatory_ids": room.exchange.mandatory_ids_for(i) if room.exchange != null else [],
				"exchange_readiness": room.exchange.readiness_by_role() if room.exchange != null else {},
				"exchange_participant": room.exchange.is_participant(i) if room.exchange != null else false,
				"exchange": exchange_data,
			"players": _public_players(room)
		})

func _broadcast_exchange(room: Dictionary, result: Dictionary) -> void:
	_broadcast(room, Protocol.CARD_EXCHANGE, {
		"phase": room.phase,
		"remaining": int(result.get("remaining", result.get("pending_count", 0))),
		"readiness": room.exchange.readiness_by_role()
	})

func _broadcast_turn(room: Dictionary) -> void:
	_broadcast(room, Protocol.TURN_CHANGED, _public_turn(room))

func _public_turn(room: Dictionary) -> Dictionary:
	var game = room.game_state
	var players: Array[Dictionary] = []
	for i in range(room.members.size()):
		var player: Dictionary = game.players[i]
		players.append({
			"player_index": i,
			"name": room.members[i].name,
			"card_count": player.hand.size(),
			"finished": player.finished,
			"passed": game.passed[i],
			"role": str(room.roles_by_player.get(i, ""))
		})
	return {
		"room_code": room.code,
		"round_number": room.round_number,
		"phase": room.phase,
		"current_player": game.current_player,
		"current_card": game.current_card.to_dict() if game.current_card != null else {},
		"current_cards": _serialize_hand(game.current_cards),
		"combination": game.current_combination.duplicate(true),
		"last_player": game.last_player,
		"last_player_name": str(room.members[game.last_player].name) if game.last_player >= 0 else "",
		"players": players,
		"finishing_order": game.finishing_order.duplicate()
	}

func _public_players(room: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for i in range(room.members.size()):
		var member: Dictionary = room.members[i]
		result.append({
			"player_index": i,
			"name": member.name,
			"is_bot": member.is_bot,
			"is_host": int(member.peer_id) > 0 and int(member.peer_id) == int(room.host_peer),
			"ready": bool(member.get("is_bot", false)) or bool(member.get("ready", false)),
			"role": str(room.roles_by_player.get(i, ""))
		})
	return result

func _broadcast_lobby(room: Dictionary) -> void:
	var human_count := 0
	var ready_count := 0
	for member in room.members:
		if not bool(member.get("is_bot", false)):
			human_count += 1
			if bool(member.get("ready", false)):
				ready_count += 1
	var payload := {
		"room_code": room.code,
		"max_players": room.max_players,
		"phase": room.phase,
		"round_number": room.round_number,
		"players": _public_players(room),
		"ready_count": ready_count,
		"human_count": human_count,
		"all_ready": ready_count == human_count and human_count > 0
	}
	for player_index in range(room.members.size()):
		var peer_id: int = int(room.members[player_index].peer_id)
		if peer_id <= 0:
			continue
		var recipient_payload := payload.duplicate(true)
		recipient_payload["your_player_index"] = player_index
		recipient_payload["is_host"] = peer_id == int(room.host_peer)
		_send(peer_id, Protocol.LOBBY_STATE, recipient_payload)

func _broadcast(room: Dictionary, message_type: String, payload: Dictionary) -> void:
	for member in room.members:
		if int(member.peer_id) > 0:
			_send(int(member.peer_id), message_type, payload)

func _send(peer_id: int, message_type: String, payload: Dictionary) -> void:
	send_to_peer.emit(peer_id, Protocol.message(message_type, payload))

func _reject(peer_id: int, reason: String) -> void:
	_send(peer_id, Protocol.ACTION_REJECTED, {"reason": reason})

func _reject_player(room: Dictionary, player_index: int, reason: String) -> void:
	if player_index >= 0 and player_index < room.members.size():
		var peer_id: int = int(room.members[player_index].peer_id)
		if peer_id > 0:
			_reject(peer_id, reason)

func _room_for_peer(peer_id: int) -> Variant:
	if not room_by_peer.has(peer_id):
		return null
	var code: String = room_by_peer[peer_id]
	return rooms.get(code)

func _first_connected_peer(room: Dictionary) -> int:
	for member in room.members:
		if int(member.peer_id) > 0:
			return int(member.peer_id)
	return 0

func _player_index_for_peer(room: Dictionary, peer_id: int) -> int:
	for i in range(room.members.size()):
		if int(room.members[i].peer_id) == peer_id:
			return i
	return -1

func _new_room_code() -> String:
	const ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	for _attempt in range(100):
		var code := ""
		for _i in range(6):
			code += ALPHABET[rng.randi_range(0, ALPHABET.length() - 1)]
		if not rooms.has(code):
			return code
	return "%06d" % rng.randi_range(0, 999999)

func _guest_name(requested: String) -> String:
	var cleaned := requested.strip_edges()
	if cleaned.is_empty():
		cleaned = "Guest %d" % next_bot_name
		next_bot_name += 1
	return cleaned.substr(0, 16)

static func _serialize_hand(hand: Array) -> Array[Dictionary]:
	var serialized: Array[Dictionary] = []
	for card in hand:
		serialized.append(card.to_dict())
	return serialized
