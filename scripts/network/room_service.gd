class_name RoomService
extends RefCounted

signal send_to_peer(peer_id: int, message: Dictionary)

const BotBrainScript = preload("res://scripts/ai/bot_brain.gd")
const RoleSystemScript = preload("res://scripts/game/role_system.gd")
const CardExchangeScript = preload("res://scripts/game/card_exchange.gd")
const MatchStateScript = preload("res://scripts/game/match_state.gd")
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
			print("[MP Server] Start Game request received: peer=%d." % peer_id)
			_start_game(peer_id, payload)
		Protocol.SET_READY:
			_set_ready(peer_id, payload)
		Protocol.REQUEST_SEAT_SWAP:
			_request_seat_swap(peer_id, payload)
		Protocol.RESPOND_SEAT_SWAP:
			_respond_seat_swap(peer_id, payload)
		Protocol.START_NEXT_ROUND:
			_start_next_round(peer_id)
		Protocol.REMATCH:
			_rematch(peer_id)
		Protocol.PLAY_CARDS:
			_play_cards(peer_id, payload)
		Protocol.PASS:
			_pass(peer_id)
		Protocol.SELECT_CARDS:
			_select_cards(peer_id, payload)
		Protocol.SELECT_RPS:
			_select_rps(peer_id, payload)
		Protocol.CONTINUE_RPS:
			_continue_rps(peer_id)
		_:
			_reject(peer_id, "Unknown action.")

func peer_disconnected(peer_id: int) -> void:
	print("[MP Server] Peer disconnected: peer=%d." % peer_id)
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
	var match_round_limit := int(payload.get("match_round_limit", 4))
	if not MatchStateScript.ALLOWED_ROUND_LIMITS.has(match_round_limit):
		_reject(peer_id, "Match length must be 4, 8, or 12 rounds.")
		return
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
		"match_round_limit": match_round_limit,
		"match_state": MatchStateScript.new(),
		"roles_by_player": {},
		"game_state": null,
		"exchange": null,
		"rps_players": [],
		"rps_choices": {},
		"rps_round": 1,
		"rps_winner": -1,
		"bot_delay": 0.0,
		"last_finished_count": 0,
		"pending_seat_swaps": [],
		"next_swap_id": 1
	}
	rooms[code] = room
	room_by_peer[peer_id] = code
	_send(peer_id, Protocol.ROOM_CREATED, {"room_code": code, "max_players": max_players, "match_round_limit": match_round_limit, "host": true})
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
	print("[MP Server] Peer joined lobby: peer=%d players=%d." % [peer_id, room.members.size()])
	var player_index: int = room.members.size() - 1
	_broadcast(room, Protocol.PLAYER_JOINED, {"player_index": player_index, "name": member.name})
	_broadcast_lobby(room)

func _leave_room(peer_id: int, disconnected: bool = false) -> void:
	if not room_by_peer.has(peer_id):
		return
	var code: String = room_by_peer[peer_id]
	print("[MP Server] Peer leave request: peer=%d disconnected=%s." % [peer_id, str(disconnected)])
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
	_clear_swaps_for_peer(room, peer_id)
	if room.phase == "lobby":
		if int(room.host_peer) == peer_id:
			print("[MP Server] Lobby host left; closing room with %d guests." % maxi(0, room.members.size() - 1))
			for member in room.members:
				var remaining_peer := int(member.get("peer_id", 0))
				if remaining_peer <= 0 or remaining_peer == peer_id:
					continue
				_send(remaining_peer, Protocol.ROOM_CLOSED, {"reason": "The host left the room."})
				room_by_peer.erase(remaining_peer)
			if not disconnected:
				_send(peer_id, Protocol.ROOM_LEFT, {"reason": "You left the room."})
			rooms.erase(code)
			return
		room.members.remove_at(departed_index)
		print("[MP Server] Lobby player removed: peer=%d players=%d." % [peer_id, room.members.size()])
		if not disconnected:
			_send(peer_id, Protocol.ROOM_LEFT, {"reason": "You left the room."})
		if room.members.is_empty():
			rooms.erase(code)
			return
		_broadcast_lobby(room)
		return
	departed.peer_id = 0
	departed.disconnected = true
	departed.forfeited_this_round = room.phase in ["playing", "card_exchange", "rps_tiebreak", "rps_result"]
	departed.ready = false
	if int(room.host_peer) == peer_id:
		room.host_peer = _first_connected_peer(room)
	if room.phase == "playing" and room.game_state != null:
		room.game_state.forfeit_player(departed_index)
		_after_action(room)
	elif room.phase in ["card_exchange", "rps_tiebreak", "rps_result"] and room.game_state != null:
		_resolve_preplay_forfeit(room, departed_index)
	_broadcast(room, Protocol.PLAYER_LEFT, {"player_index": departed_index, "name": departed.name, "disconnected": disconnected})
	_broadcast_lobby(room)
	if not disconnected:
		_send(peer_id, Protocol.ROOM_LEFT, {"reason": "You left the room."})

func _peer_in_pending_swap(room: Dictionary, peer_id: int) -> bool:
	for request in room.get("pending_seat_swaps", []):
		if int(request.get("requester_peer", 0)) == peer_id or int(request.get("target_peer", 0)) == peer_id:
			return true
	return false

func _clear_swaps_for_peer(room: Dictionary, peer_id: int) -> void:
	var kept: Array[Dictionary] = []
	for request in room.get("pending_seat_swaps", []):
		if int(request.get("requester_peer", 0)) != peer_id and int(request.get("target_peer", 0)) != peer_id:
			kept.append(request)
	room.pending_seat_swaps = kept

func _request_seat_swap(peer_id: int, payload: Dictionary) -> void:
	var room = _room_for_peer(peer_id)
	if room == null or room.phase != "lobby":
		_reject(peer_id, "Seats can only be swapped in the lobby.")
		return
	var requester_index := _player_index_for_peer(room, peer_id)
	var target_peer := int(payload.get("target_peer_id", 0))
	var target_index := _player_index_for_peer(room, target_peer)
	if requester_index < 0 or target_index < 0 or requester_index == target_index:
		_reject(peer_id, "That player is no longer available to swap with.")
		return
	if bool(room.members[requester_index].get("is_bot", false)) or bool(room.members[target_index].get("is_bot", false)):
		_reject(peer_id, "Seat swaps are only available between human players.")
		return
	if _peer_in_pending_swap(room, peer_id) or _peer_in_pending_swap(room, target_peer):
		_reject(peer_id, "A seat swap involving one of those players is already pending. Wait for that request to be answered before trying again.")
		return
	var request_id := int(room.next_swap_id)
	room.next_swap_id = request_id + 1
	room.pending_seat_swaps.append({"request_id": request_id, "requester_peer": peer_id, "target_peer": target_peer})
	_broadcast_lobby(room)

func _respond_seat_swap(peer_id: int, payload: Dictionary) -> void:
	var room = _room_for_peer(peer_id)
	if room == null or room.phase != "lobby":
		_reject(peer_id, "Seat swaps are only available in the lobby.")
		return
	var request_id := int(payload.get("request_id", -1))
	var request_index := -1
	for i in range(room.pending_seat_swaps.size()):
		if int(room.pending_seat_swaps[i].get("request_id", -2)) == request_id:
			request_index = i
			break
	if request_index < 0 or int(room.pending_seat_swaps[request_index].get("target_peer", 0)) != peer_id:
		_reject(peer_id, "That seat swap request is no longer valid.")
		return
	var request: Dictionary = room.pending_seat_swaps[request_index]
	room.pending_seat_swaps.remove_at(request_index)
	var requester_peer := int(request.get("requester_peer", 0))
	if bool(payload.get("accept", false)):
		var requester_index := _player_index_for_peer(room, requester_peer)
		var target_index := _player_index_for_peer(room, peer_id)
		if requester_index < 0 or target_index < 0 or requester_index == target_index or bool(room.members[requester_index].get("is_bot", false)) or bool(room.members[target_index].get("is_bot", false)):
			_reject(peer_id, "That seat swap request is no longer valid.")
			_broadcast_lobby(room)
			return
		var requester: Dictionary = room.members[requester_index]
		room.members[requester_index] = room.members[target_index]
		room.members[target_index] = requester
		for member in room.members:
			if not bool(member.get("is_bot", false)):
				member["ready"] = false
		_broadcast_lobby(room)
		_send(requester_peer, Protocol.SEAT_SWAP_RESULT, {"accepted": true})
		return
	_broadcast_lobby(room)
	_send(requester_peer, Protocol.SEAT_SWAP_RESULT, {"accepted": false})

func _resolve_preplay_forfeit(room: Dictionary, departed_index: int) -> void:
	# Exchange and RPS happen before ordinary turn resolution; settle deterministically.
	var order: Array[int] = []
	for i in range(room.members.size()):
		if i != departed_index:
			order.append(i)
	order.append(departed_index)
	room.game_state.finishing_order = order
	for i in range(room.game_state.players.size()):
		room.game_state.players[i].finished = true
	room.game_state.changed.emit()
	room.phase = "playing"
	_finish_round(room)

func _start_game(peer_id: int, payload: Dictionary) -> void:
	var room = _room_for_peer(peer_id)
	if room == null:
		_reject_start_game(peer_id, "You are not in a room.")
		return
	if int(room.host_peer) != peer_id:
		_reject_start_game(peer_id, "Only the host can start the game.")
		return
	if room.phase != "lobby":
		_reject_start_game(peer_id, "The game is already starting." if room.phase == "starting" else "The game is already running.")
		return
	if not _all_humans_ready(room):
		_reject_start_game(peer_id, "All human players must be Ready before starting.")
		return
	var original_member_count: int = room.members.size()
	var fill_bots := bool(payload.get("fill_bots", false))
	var final_count: int = int(room.max_players) if fill_bots else original_member_count
	if final_count < 2:
		_reject_start_game(peer_id, "At least two seats are needed. Add bots or invite a player.")
		return
	var match_state = MatchStateScript.new()
	if not match_state.begin(final_count, int(room.match_round_limit)):
		_reject_start_game(peer_id, "The match configuration is invalid.")
		return
	print("[MP Server] Start Game validation passed: peer=%d." % peer_id)
	print("[MP Server] Match state created: seats=%d rounds=%d." % [final_count, int(room.match_round_limit)])
	room.phase = "starting"
	print("[MP Server] Room marked starting.")
	room.pending_seat_swaps.clear()
	if fill_bots:
		while room.members.size() < int(room.max_players):
			room.members.append({"peer_id": 0, "name": "Bot %d" % next_bot_name, "is_bot": true, "ready": true})
			next_bot_name += 1
	room.match_state = match_state
	room.round_number = 0
	room.roles_by_player.clear()
	for member in room.members:
		member["role"] = ""
	_start_round(room)
	if room.phase == "starting":
		room.phase = "lobby"
		room.members.resize(original_member_count)
		room.match_state = MatchStateScript.new()
		room.round_number = 0
		room.game_state = null
		room.exchange = null
		room.roles_by_player.clear()
		_reject_start_game(peer_id, "Could not initialize the first round. Please try again.")
		_broadcast_lobby(room)

func _rematch(peer_id: int) -> void:
	var room = _room_for_peer(peer_id)
	if room == null:
		_reject(peer_id, "You are not in a room.")
		return
	if int(room.host_peer) != peer_id:
		_reject(peer_id, "Only the host can request a rematch.")
		return
	if room.phase != "match_finished":
		_reject(peer_id, "A rematch is only available after the match finishes.")
		return
	room.phase = "lobby"
	room.round_number = 0
	room.match_state.begin(room.members.size(), int(room.match_round_limit))
	room.roles_by_player.clear()
	room.game_state = null
	room.exchange = null
	room.rps_players = []
	room.rps_choices = {}
	room.rps_round = 1
	room.last_finished_count = 0
	room.bot_delay = 0.0
	for member in room.members:
		if bool(member.get("disconnected", false)):
			member["is_bot"] = true
			member["name"] = "%s (Bot)" % str(member.get("name", "Player"))
			member.erase("disconnected")
			member.erase("forfeited_this_round")
		member["ready"] = bool(member.get("is_bot", false))
		member["role"] = ""
	_broadcast_lobby(room)

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

func _reject_start_game(peer_id: int, reason: String) -> void:
	print("[MP Server] Start Game validation rejected: %s" % reason)
	_reject(peer_id, reason)

func _all_humans_ready(room: Dictionary) -> bool:
	for member in room.members:
		if not bool(member.get("is_bot", false)) and int(member.get("peer_id", 0)) > 0 and not bool(member.get("ready", false)):
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
	if int(room.match_state.current_round) >= int(room.match_round_limit):
		_reject(peer_id, "The match is already complete.")
		return
	_start_round(room)

func _start_round(room: Dictionary) -> void:
	if int(room.match_state.current_round) >= int(room.match_round_limit):
		return
	var round_starter := -1
	var previous_game = room.game_state
	if int(room.match_state.current_round) > 0 and previous_game != null and not previous_game.finishing_order.is_empty():
		round_starter = previous_game.finishing_order[0]
	for member in room.members:
		if bool(member.get("disconnected", false)):
			member["is_bot"] = true
			member["name"] = "%s (Bot)" % str(member.get("name", "Player"))
			member["ready"] = true
			member.erase("disconnected")
			member.erase("forfeited_this_round")
	if not room.match_state.advance_round():
		return
	room.round_number = int(room.match_state.current_round)
	room.game_state = GameState.new()
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
	room.rps_players = []
	room.rps_choices = {}
	room.rps_round = 1
	room.rps_winner = -1
	if round_starter < 0:
		room.rps_players = room.game_state.three_clubs_holders()
		if room.rps_players.size() > 1:
			phase = "rps_tiebreak"
			for player_index in room.rps_players:
				if bool(room.members[player_index].is_bot):
					room.rps_choices[str(player_index)] = rng.randi_range(0, 2)
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
	if room.round_number == 1:
		print("[MP Server] Initial round state created; room phase=%s." % room.phase)
	print("[MP Server] Starter decision: phase=%s rps_players=%d." % [room.phase, room.rps_players.size()])
	print("[MP Server] Broadcasting Start Game; players=%d round=%d." % [room.members.size(), room.round_number])
	_broadcast(room, Protocol.START_GAME, {
		"room_code": room.code,
		"round_number": room.round_number,
		"current_round": room.match_state.current_round,
		"match_round_limit": room.match_round_limit,
		"player_count": room.members.size(),
		"phase": room.phase,
		"roles_by_player": room.roles_by_player.duplicate(true),
		"players": _public_players(room)
	})
	_send_deals(room)
	if room.phase == "rps_tiebreak":
		_resolve_rps(room)
	if room.exchange != null:
		_broadcast_exchange(room, exchange_summary)
	if room.phase == "playing":
		_broadcast_turn(room)

func _select_rps(peer_id: int, payload: Dictionary) -> void:
	var room = _room_for_peer(peer_id)
	if room == null or room.phase != "rps_tiebreak":
		_reject(peer_id, "Rock-paper-scissors is not waiting.")
		return
	var player_index := _player_index_for_peer(room, peer_id)
	if not room.rps_players.has(player_index) or bool(room.members[player_index].is_bot):
		_reject(peer_id, "This player cannot choose a card.")
		return
	var choice := int(payload.get("choice", -1))
	if choice < 0 or choice > 2:
		_reject(peer_id, "Choose rock, paper, or scissors.")
		return
	var key := str(player_index)
	if room.rps_choices.has(key):
		_reject(peer_id, "Your choice is already locked.")
		return
	room.rps_choices[key] = choice
	_resolve_rps(room)

func _resolve_rps(room: Dictionary) -> void:
	if room.rps_choices.size() < room.rps_players.size():
		_broadcast_rps_state(room)
		return
	var first := int(room.rps_choices[str(room.rps_players[0])])
	var second := int(room.rps_choices[str(room.rps_players[1])])
	var outcome := _rps_winner(first, second)
	room.rps_winner = -1 if outcome < 0 else (int(room.rps_players[0]) if outcome == 0 else int(room.rps_players[1]))
	if room.rps_winner >= 0:
		room.game_state.current_player = int(room.rps_winner)
		room.game_state.turns.start_at(int(room.rps_winner), room.members.size())
	room.phase = "rps_result"
	_broadcast_rps_state(room)

func _continue_rps(peer_id: int) -> void:
	var room = _room_for_peer(peer_id)
	if room == null or room.phase != "rps_result":
		_reject(peer_id, "The tiebreak result is not waiting for confirmation.")
		return
	if peer_id != int(room.host_peer):
		_reject(peer_id, "Only the host can continue from the tiebreak result.")
		return
	if int(room.rps_winner) >= 0:
		room.phase = "playing"
		_broadcast_turn(room)
		return
	room.phase = "rps_tiebreak"
	room.rps_round = int(room.rps_round) + 1
	room.rps_choices.clear()
	for player_index in room.rps_players:
		if bool(room.members[player_index].is_bot):
			room.rps_choices[str(player_index)] = rng.randi_range(0, 2)
	_broadcast_rps_state(room)
	if room.rps_choices.size() == room.rps_players.size():
		_resolve_rps(room)

func _broadcast_rps_state(room: Dictionary) -> void:
	print("[MP Server] Broadcasting RPS state: phase=%s players=%d choices=%d." % [room.phase, room.rps_players.size(), room.rps_choices.size()])
	_broadcast(room, Protocol.RPS_STATE, {
		"phase": room.phase,
		"players": room.rps_players.duplicate(),
		"choices": room.rps_choices.duplicate(true),
		"round": room.rps_round,
		"winner": int(room.rps_winner)
	})

func _rps_winner(first: int, second: int) -> int:
	if first == second:
		return -1
	return 0 if (first == 0 and second == 2) or (first == 1 and second == 0) or (first == 2 and second == 1) else 1

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
	if room.phase != "playing" or room.game_state == null:
		return
	var match_result: Dictionary = room.match_state.record_round(room.game_state.finishing_order)
	if not match_result.ok:
		room.phase = "results"
		_broadcast(room, Protocol.ACTION_REJECTED, {"reason": str(match_result.error)})
		return
	var resolution: Dictionary = RoleSystemScript.resolve(room.game_state.finishing_order, room.members.size(), room.roles_by_player)
	if not resolution.ok:
		room.phase = "results"
		_broadcast(room, Protocol.ACTION_REJECTED, {"reason": resolution.error})
		return
	room.roles_by_player = resolution.roles_by_player
	for i in range(room.members.size()):
		room.members[i]["role"] = str(room.roles_by_player.get(i, ""))
	var is_final_round: bool = int(room.match_state.current_round) == int(room.match_round_limit)
	room.phase = "match_finished" if is_final_round else "results"
	var role_payload := {
		"roles_by_player": room.roles_by_player.duplicate(true),
		"previous_king_demoted": resolution.previous_king_demoted,
		"previous_king_player": resolution.previous_king_player
	}
	_broadcast(room, Protocol.ROLES_ASSIGNED, role_payload)
	var result_payload := {
		"round_number": room.round_number,
		"current_round": room.match_state.current_round,
		"match_round_limit": room.match_round_limit,
		"finishing_order": room.game_state.finishing_order.duplicate(),
		"round_points": match_result.round_points,
		"match_scores": match_result.match_scores,
		"first_place_counts": match_result.first_place_counts,
		"second_place_counts": match_result.second_place_counts,
		"final_positions": room.match_state.final_positions.duplicate(),
		"roles_by_player": room.roles_by_player.duplicate(true),
		"players": _public_players(room),
		"previous_king_demoted": resolution.previous_king_demoted,
		"next_round_available": not is_final_round
	}
	if is_final_round:
		result_payload["leaderboard"] = _match_leaderboard(room)
		_broadcast(room, Protocol.MATCH_FINISHED, result_payload)
	else:
		_broadcast(room, Protocol.ROUND_FINISHED, result_payload)
	_broadcast_lobby(room)

func _match_leaderboard(room: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for player_index in room.match_state.ranked_player_indices():
		result.append({
			"player_index": player_index,
			"name": str(room.members[player_index].name),
			"score": room.match_state.match_scores[player_index],
			"first_place_count": room.match_state.first_place_counts[player_index],
			"second_place_count": room.match_state.second_place_counts[player_index],
			"final_position": room.match_state.final_positions[player_index],
			"role": str(room.roles_by_player.get(player_index, ""))
		})
	return result

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
			"current_round": room.match_state.current_round,
			"match_round_limit": room.match_round_limit,
			"match_scores": room.match_state.match_scores.duplicate(),
			"first_place_counts": room.match_state.first_place_counts.duplicate(),
			"second_place_counts": room.match_state.second_place_counts.duplicate(),
			"phase": room.phase,
			"rps_players": room.rps_players.duplicate(),
			"rps_choices": room.rps_choices.duplicate(true),
			"rps_round": room.rps_round,
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
			"disconnected": bool(room.members[i].get("disconnected", false)),
			"forfeited": bool(room.members[i].get("forfeited_this_round", false)),
			"passed": game.passed[i],
			"role": str(room.roles_by_player.get(i, ""))
		})
	return {
		"room_code": room.code,
		"round_number": room.round_number,
		"current_round": room.match_state.current_round,
		"match_round_limit": room.match_round_limit,
		"match_scores": room.match_state.match_scores.duplicate(),
		"first_place_counts": room.match_state.first_place_counts.duplicate(),
		"second_place_counts": room.match_state.second_place_counts.duplicate(),
		"phase": room.phase,
		"current_player": game.current_player,
		"current_card": game.current_card.to_dict() if game.current_card != null else {},
		"current_cards": _serialize_hand(game.current_cards),
		"pile_cards": _serialize_hand(game.trick_pile_cards),
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
			"peer_id": int(member.get("peer_id", 0)),
			"name": member.name,
			"is_bot": member.is_bot,
			"disconnected": bool(member.get("disconnected", false)),
			"forfeited": bool(member.get("forfeited_this_round", false)),
			"is_host": int(member.peer_id) > 0 and int(member.peer_id) == int(room.host_peer),
			"ready": bool(member.get("is_bot", false)) or bool(member.get("ready", false)),
			"role": str(room.roles_by_player.get(i, ""))
		})
	return result

func _broadcast_lobby(room: Dictionary) -> void:
	print("[MP Server] Broadcasting lobby snapshot: players=%d phase=%s." % [room.members.size(), str(room.phase)])
	var human_count := 0
	var ready_count := 0
	for member in room.members:
		if not bool(member.get("is_bot", false)) and int(member.get("peer_id", 0)) > 0:
			human_count += 1
			if bool(member.get("ready", false)):
				ready_count += 1
	var payload := {
		"room_code": room.code,
		"max_players": room.max_players,
		"phase": room.phase,
		"round_number": room.round_number,
		"current_round": room.match_state.current_round,
		"match_round_limit": room.match_round_limit,
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
		recipient_payload["incoming_swap"] = {}
		recipient_payload["outgoing_swaps"] = []
		for request in room.get("pending_seat_swaps", []):
			if int(request.get("target_peer", 0)) == peer_id:
				var requester_index := _player_index_for_peer(room, int(request.get("requester_peer", 0)))
				if requester_index >= 0:
					recipient_payload["incoming_swap"] = {"request_id": int(request.request_id), "name": str(room.members[requester_index].name)}
			if int(request.get("requester_peer", 0)) == peer_id:
				recipient_payload.outgoing_swaps.append(int(request.get("request_id", 0)))
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
