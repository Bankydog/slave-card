extends Node

const RoomServiceScript = preload("res://scripts/network/room_service.gd")
const Protocol = preload("res://scripts/network/network_protocol.gd")
const GameStateScript = preload("res://scripts/game/game_state.gd")
const RoleSystemScript = preload("res://scripts/game/role_system.gd")
const CardExchangeScript = preload("res://scripts/game/card_exchange.gd")
const MatchStateScript = preload("res://scripts/game/match_state.gd")
const BotBrainScript = preload("res://scripts/ai/bot_brain.gd")
const GameRulesScript = preload("res://scripts/game/game_rules.gd")
const HandSorterScript = preload("res://scripts/cards/hand_sorter.gd")
const CardViewScript = preload("res://scripts/ui/card_view.gd")
const TablePresentationScript = preload("res://scripts/ui/table_presentation.gd")
const TableLayoutScript = preload("res://scripts/ui/table_layout.gd")
const MultiplayerFlowScript = preload("res://scripts/ui/multiplayer_flow.gd")

var failures: Array[String] = []
var messages_by_peer: Dictionary = {}

func _ready() -> void:
	if OS.get_cmdline_user_args().has("--start-game-only"):
		_test_start_game_initializes_first_round()
		if failures.is_empty():
			print("TARGETED START GAME PASS")
			get_tree().quit(0)
		else:
			for failure in failures:
				push_error(failure)
			get_tree().quit(1)
		return
	if OS.get_cmdline_user_args().has("--play-animation-only"):
		await _test_play_animation_pile()
		if failures.is_empty():
			print("TARGETED PLAY ANIMATION PASS")
			get_tree().quit(0)
		else:
			for failure in failures:
				push_error(failure)
			get_tree().quit(1)
		return
	_test_decks_and_deals()
	_test_roles()
	_test_exchange()
	_test_trade_rules()
	_test_entry_input_layout()
	_test_trade_waiting_ui()
	_test_server_trade_authority()
	_test_turn_flow()
	_test_local_combo_flow()
	_test_round_starter()
	_test_pass_regressions()
	_test_bot_pass_turn_regression()
	_test_combinations()
	_test_suit_comparisons()
	_test_selection_helpers()
	_test_suit_selection_helpers()
	_test_card_hover_visuals()
	_test_table_presentation()
	await _test_play_animation_pile()
	_test_lobby_visual_styles()
	_test_bot_combinations()
	_test_server_ready_authority()
	_test_start_game_initializes_first_round()
	_test_server_seat_swaps()
	_test_server_lobby_presence()
	_test_server_disconnect_forfeit()
	_test_start_game_client_feedback()
	_test_multiple_disconnect_order()
	_test_match_state_scoring()
	_test_server_match_flow(4, 960)
	_test_server_match_flow(8, 970)
	_test_server_match_flow(12, 980)
	_test_invalid_match_length()
	_test_room_round(6)
	_test_room_round(7)
	_test_room_round(12)
	_test_server_multi_card_validation()
	_test_server_single_against_multi_card_server_validation()
	_test_server_suit_validation()
	_test_server_parity_validation()
	_test_server_cross_type_combo()
	if failures.is_empty():
		print("VALIDATION PASS")
		await get_tree().create_timer(3.0).timeout
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("VALIDATION FAIL: %d issue(s)" % failures.size())
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(1)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
	else:
		print("PASS: " + message)

func _card(rank: String, suit: String = "Clubs", deck_index: int = 0) -> CardData:
	return CardData.new(rank, suit, deck_index)

func _ids(cards: Array) -> Array[String]:
	var result: Array[String] = []
	for card: CardData in cards:
		result.append(card.card_id())
	return result

func _ready_peers(service, peers: Array[int]) -> void:
	for peer_id in peers:
		service.handle_message(peer_id, {"type":Protocol.SET_READY, "payload":{"ready":true}})

func _test_match_state_scoring() -> void:
	for player_count in range(2, 13):
		var tracker = MatchStateScript.new()
		_check(tracker.begin(player_count, 4), "%d players can initialize a match tracker" % player_count)
		_check(tracker.advance_round(), "%d-player match advances to Round 1" % player_count)
		var order: Array[int] = []
		for player_index in range(player_count):
			order.append(player_index)
		var result: Dictionary = tracker.record_round(order)
		var points_ok := bool(result.get("ok", false))
		for place in range(player_count):
			points_ok = points_ok and tracker.match_scores[place] == player_count - place - 1
		_check(points_ok, "scoring uses player count minus finishing position for %d players" % player_count)
		_check(tracker.first_place_counts[0] == 1 and tracker.second_place_counts[1] == 1, "first and second place counters update for %d players" % player_count)
	for round_limit in [4, 8, 12]:
		var tracker = MatchStateScript.new()
		tracker.begin(2, round_limit)
		for round_number in range(round_limit):
			tracker.advance_round()
			var result: Dictionary = tracker.record_round([0, 1])
			if not result.ok:
				_check(false, "%d-round match records round %d" % [round_limit, round_number + 1])
				break
		_check(tracker.current_round == round_limit and not tracker.advance_round(), "%d-round match stops exactly at its configured limit" % round_limit)
	var ranked = MatchStateScript.new()
	ranked.begin(3, 4)
	ranked.advance_round()
	ranked.record_round([0, 1, 2])
	ranked.advance_round()
	ranked.record_round([2, 1, 0])
	_check(ranked.match_scores == [2, 2, 2] and ranked.ranked_player_indices() == [2, 0, 1], "ranking breaks score ties by first-place counts, then final position deterministically")

func _test_server_match_flow(round_limit: int, host_peer: int) -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	service.handle_message(host_peer, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":2, "match_round_limit":round_limit}})
	var code := str(_last_message(host_peer, Protocol.ROOM_CREATED).get("payload", {}).get("room_code", ""))
	var guest_peer := host_peer + 1
	service.handle_message(guest_peer, {"type":Protocol.JOIN_ROOM, "payload":{"name":"Guest", "room_code":code}})
	var guest_lobby: Dictionary = _last_message(guest_peer, Protocol.LOBBY_STATE).get("payload", {})
	_check(int(guest_lobby.get("match_round_limit", 0)) == round_limit, "guest receives server-selected %d-round length" % round_limit)
	_ready_peers(service, [host_peer, guest_peer])
	service.handle_message(host_peer, {"type":Protocol.START_GAME, "payload":{"fill_bots":false, "match_round_limit":12}})
	var room: Dictionary = service.rooms[code]
	_check(room.phase == "playing" and room.match_state.current_round == 1 and room.match_round_limit == round_limit, "server starts a fresh %d-round match and ignores client round-limit changes" % round_limit)
	_check(room.game_state.current_player == room.game_state.first_player_by_three_clubs(), "new match starts through existing 3-club starter logic")
	for round_number in range(1, round_limit + 1):
		room.phase = "playing"
		room.game_state.finishing_order.clear()
		room.game_state.finishing_order.append(0)
		room.game_state.finishing_order.append(1)
		service._finish_round(room)
		if round_number < round_limit:
			var round_payload: Dictionary = _last_message(host_peer, Protocol.ROUND_FINISHED).get("payload", {})
			_check(room.phase == "results" and room.match_state.current_round == round_number and round_payload.get("match_scores", []) == [round_number, 0], "%d-round match publishes cumulative scores after round %d" % [round_limit, round_number])
			var before_duplicate := int(room.match_state.current_round)
			service.handle_message(guest_peer, {"type":Protocol.START_NEXT_ROUND, "payload":{}})
			_check(int(room.match_state.current_round) == before_duplicate, "guest cannot advance the server match")
			service.handle_message(host_peer, {"type":Protocol.START_NEXT_ROUND, "payload":{}})
			var after_advance := int(room.match_state.current_round)
			service.handle_message(host_peer, {"type":Protocol.START_NEXT_ROUND, "payload":{}})
			_check(after_advance == round_number + 1 and int(room.match_state.current_round) == after_advance, "duplicate next-round requests cannot skip a round")
		else:
			var final_payload: Dictionary = _last_message(host_peer, Protocol.MATCH_FINISHED).get("payload", {})
			_check(room.phase == "match_finished" and room.match_state.current_round == round_limit and not bool(final_payload.get("next_round_available", true)), "%d-round match ends exactly once on its final round" % round_limit)
			_check(final_payload.get("leaderboard", []).size() == room.members.size() and final_payload.get("match_scores", []) == [round_limit, 0], "final leaderboard includes every player and cumulative score")
			var final_scores: Array[int] = room.match_state.match_scores.duplicate()
			service._finish_round(room)
			_check(room.match_state.match_scores == final_scores and int(room.match_state.current_round) == round_limit, "duplicate final completion cannot score or advance twice")
	service.handle_message(guest_peer, {"type":Protocol.REMATCH, "payload":{}})
	_check(room.phase == "match_finished", "guest cannot reset a completed match")
	service.handle_message(host_peer, {"type":Protocol.REMATCH, "payload":{}})
	_check(room.phase == "lobby" and room.match_state.current_round == 0 and room.match_state.match_scores == [0, 0] and room.roles_by_player.is_empty(), "host rematch resets score, rounds, roles, and returns the same room to lobby")
	_check(not bool(room.members[0].ready) and not bool(room.members[1].ready), "rematch requires humans to ready again")
	_ready_peers(service, [host_peer, guest_peer])
	service.handle_message(host_peer, {"type":Protocol.START_GAME, "payload":{"fill_bots":false}})
	_check(room.match_state.current_round == 1 and room.match_state.match_round_limit == round_limit and room.game_state.current_player == room.game_state.first_player_by_three_clubs(), "rematch preserves length and restores first-round 3-club starter")

func _test_server_seat_swaps() -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	service.handle_message(1201, {"type":Protocol.CREATE_ROOM, "payload":{"name":"A", "max_players":3}})
	var code := str(_last_message(1201, Protocol.ROOM_CREATED).payload.room_code)
	service.handle_message(1202, {"type":Protocol.JOIN_ROOM, "payload":{"name":"B", "room_code":code}})
	service.handle_message(1201, {"type":Protocol.SET_READY, "payload":{"ready":true}})
	service.handle_message(1202, {"type":Protocol.SET_READY, "payload":{"ready":true}})
	service.handle_message(1201, {"type":Protocol.REQUEST_SEAT_SWAP, "payload":{"target_peer_id":1202}})
	var incoming: Dictionary = _last_message(1202, Protocol.LOBBY_STATE).payload.get("incoming_swap", {})
	_check(not incoming.is_empty(), "seat swap request is shown only to its target")
	service.handle_message(1203, {"type":Protocol.RESPOND_SEAT_SWAP, "payload":{"request_id":int(incoming.get("request_id", -1)), "accept":true}})
	_check(int(service.rooms[code].members[0].peer_id) == 1201, "unjoined peer cannot fabricate a seat swap response")
	service.handle_message(1202, {"type":Protocol.RESPOND_SEAT_SWAP, "payload":{"request_id":int(incoming.get("request_id", -1)), "accept":false}})
	_check(int(service.rooms[code].members[0].peer_id) == 1201 and bool(service.rooms[code].members[0].ready), "reject leaves seats and ready state unchanged")
	service.handle_message(1201, {"type":Protocol.REQUEST_SEAT_SWAP, "payload":{"target_peer_id":1202}})
	incoming = _last_message(1202, Protocol.LOBBY_STATE).payload.get("incoming_swap", {})
	service.handle_message(1202, {"type":Protocol.RESPOND_SEAT_SWAP, "payload":{"request_id":int(incoming.get("request_id", -1)), "accept":true}})
	_check(int(service.rooms[code].members[0].peer_id) == 1202 and int(service.rooms[code].members[1].peer_id) == 1201, "accepted swap changes authoritative seat order")
	_check(not bool(service.rooms[code].members[0].ready) and not bool(service.rooms[code].members[1].ready), "accepted seat swap resets human Ready state")
	service.handle_message(1202, {"type":Protocol.REQUEST_SEAT_SWAP, "payload":{"target_peer_id":1201}})
	service.handle_message(1202, {"type":Protocol.SET_READY, "payload":{"ready":true}})
	var pending_before_leave: int = service.rooms[code].pending_seat_swaps.size()
	service.handle_message(1202, {"type":Protocol.LEAVE_ROOM, "payload":{}})
	_check(pending_before_leave == 1 and service.rooms[code].pending_seat_swaps.is_empty(), "leaving player clears pending seat swap requests")

func _test_server_lobby_presence() -> void:
	var guest_leave_service = RoomServiceScript.new()
	guest_leave_service.send_to_peer.connect(_capture_message)
	guest_leave_service.handle_message(1501, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":3}})
	var guest_leave_code := str(_last_message(1501, Protocol.ROOM_CREATED).payload.room_code)
	guest_leave_service.handle_message(1502, {"type":Protocol.JOIN_ROOM, "payload":{"name":"Guest", "room_code":guest_leave_code}})
	_ready_peers(guest_leave_service, [1501, 1502])
	guest_leave_service.handle_message(1501, {"type":Protocol.REQUEST_SEAT_SWAP, "payload":{"target_peer_id":1502}})
	guest_leave_service.handle_message(1502, {"type":Protocol.LEAVE_ROOM, "payload":{}})
	var guest_leave_room: Dictionary = guest_leave_service.rooms[guest_leave_code]
	var host_snapshot: Dictionary = _last_message(1501, Protocol.LOBBY_STATE).payload
	var guest_leave_ack: Dictionary = _last_message(1502, Protocol.ROOM_LEFT).payload
	_check(guest_leave_room.members.size() == 1 and not guest_leave_service.room_by_peer.has(1502), "guest leave removes the guest from authoritative lobby membership")
	_check(host_snapshot.players.size() == 1 and int(host_snapshot.ready_count) == 1, "remaining host receives a fresh lobby snapshot without the guest or stale ready count")
	_check(guest_leave_room.pending_seat_swaps.is_empty() and str(guest_leave_ack.reason) == "You left the room.", "guest leave clears involving seat swaps and acknowledges the leaver")

	var host_leave_service = RoomServiceScript.new()
	host_leave_service.send_to_peer.connect(_capture_message)
	host_leave_service.handle_message(1511, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":2}})
	var host_leave_code := str(_last_message(1511, Protocol.ROOM_CREATED).payload.room_code)
	host_leave_service.handle_message(1512, {"type":Protocol.JOIN_ROOM, "payload":{"name":"Guest", "room_code":host_leave_code}})
	host_leave_service.handle_message(1511, {"type":Protocol.LEAVE_ROOM, "payload":{}})
	var host_closed: Dictionary = _last_message(1512, Protocol.ROOM_CLOSED).payload
	_check(not host_leave_service.rooms.has(host_leave_code) and not host_leave_service.room_by_peer.has(1511) and not host_leave_service.room_by_peer.has(1512), "host leave closes the lobby without transferring host ownership")
	_check(str(host_closed.reason) == "The host left the room.", "remaining guest receives the clear host-left event")

	var guest_disconnect_service = RoomServiceScript.new()
	guest_disconnect_service.send_to_peer.connect(_capture_message)
	guest_disconnect_service.handle_message(1521, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":2}})
	var guest_disconnect_code := str(_last_message(1521, Protocol.ROOM_CREATED).payload.room_code)
	guest_disconnect_service.handle_message(1522, {"type":Protocol.JOIN_ROOM, "payload":{"name":"Guest", "room_code":guest_disconnect_code}})
	_ready_peers(guest_disconnect_service, [1521, 1522])
	guest_disconnect_service.peer_disconnected(1522)
	var disconnect_snapshot: Dictionary = _last_message(1521, Protocol.LOBBY_STATE).payload
	_check(guest_disconnect_service.rooms[guest_disconnect_code].members.size() == 1 and disconnect_snapshot.players.size() == 1 and int(disconnect_snapshot.ready_count) == 1, "guest disconnect removes the player and ready state and broadcasts a fresh snapshot")

	var host_disconnect_service = RoomServiceScript.new()
	host_disconnect_service.send_to_peer.connect(_capture_message)
	host_disconnect_service.handle_message(1531, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":2}})
	var host_disconnect_code := str(_last_message(1531, Protocol.ROOM_CREATED).payload.room_code)
	host_disconnect_service.handle_message(1532, {"type":Protocol.JOIN_ROOM, "payload":{"name":"Guest", "room_code":host_disconnect_code}})
	host_disconnect_service.peer_disconnected(1531)
	var disconnect_closed: Dictionary = _last_message(1532, Protocol.ROOM_CLOSED).payload
	_check(not host_disconnect_service.rooms.has(host_disconnect_code) and not host_disconnect_service.room_by_peer.has(1532), "host disconnect removes the room and all lobby peer mappings")
	_check(str(disconnect_closed.reason) == "The host left the room.", "host disconnect notifies guests with the same host-left reason")

func _test_start_game_client_feedback() -> void:
	var flow = MultiplayerFlowScript.new()
	flow.page = "lobby"
	flow.is_host = true
	flow.room_code = "TEST01"
	flow.room_players = [
		{"peer_id":1601, "player_index":0, "name":"Host", "is_host":true, "ready":true},
		{"peer_id":1602, "player_index":1, "name":"Guest", "ready":true}
	]
	flow.lobby_all_ready = true
	add_child(flow)
	flow._show_lobby()
	flow.request_in_flight = true
	flow.request_type_in_flight = Protocol.START_GAME
	flow._on_server_message({"type":Protocol.ACTION_REJECTED, "payload":{"reason":"Only the host can start the game."}})
	var start_button := flow.find_child("Action_StartGame", true, false) as Button
	_check(not flow.request_in_flight and flow.status_text == "Only the host can start the game." and start_button != null and not start_button.disabled, "server rejection shows its reason and restores Start Game controls")
	flow.request_in_flight = true
	flow.request_type_in_flight = Protocol.START_GAME
	flow.request_timeout_timer.wait_time = 8.0
	flow._on_request_timeout()
	start_button = flow.find_child("Action_StartGame", true, false) as Button
	_check(not flow.request_in_flight and flow.status_text == "Start Game timed out. Please try again." and start_button != null and not start_button.disabled, "Start Game timeout exits pending state and restores lobby controls")
	flow.request_in_flight = true
	flow.request_type_in_flight = Protocol.START_GAME
	flow.request_timeout_timer.start(8.0)
	flow._on_server_message({"type":Protocol.START_GAME, "payload":{"current_round":1, "match_round_limit":4, "phase":"playing", "players":[]}})
	_check(flow.page == "game" and not flow.request_in_flight and not flow.request_timeout_timer.time_left, "successful Start Game cancels its timeout and transitions into gameplay")
	flow.free()

func _test_server_disconnect_forfeit() -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	service.handle_message(1301, {"type":Protocol.CREATE_ROOM, "payload":{"name":"A", "max_players":2, "match_round_limit":4}})
	var code := str(_last_message(1301, Protocol.ROOM_CREATED).payload.room_code)
	service.handle_message(1302, {"type":Protocol.JOIN_ROOM, "payload":{"name":"B", "room_code":code}})
	_ready_peers(service, [1301, 1302])
	service.handle_message(1301, {"type":Protocol.START_GAME, "payload":{"fill_bots":false}})
	var room: Dictionary = service.rooms[code]
	var current_index: int = room.game_state.current_player
	var departed_peer := int(room.members[current_index].peer_id)
	service.peer_disconnected(departed_peer)
	var result_message := Protocol.MATCH_FINISHED if room.phase == "match_finished" else Protocol.ROUND_FINISHED
	var result: Dictionary = _last_message(1302 if departed_peer == 1301 else 1301, result_message).payload
	_check(room.phase == "results" and room.game_state.finishing_order.size() == 2, "disconnect on the current turn immediately resolves a two-player round")
	_check(int(room.game_state.finishing_order[-1]) == current_index and int(room.match_state.match_scores[current_index]) == 0, "forfeiter receives the last finishing place and zero round points")
	_check(str(room.roles_by_player.get(current_index, "")) == "Slave 1", "two-player forfeiter receives the existing Slave 1 last-place role")
	_check(bool(room.members[current_index].get("disconnected", false)) and not bool(room.members[current_index].get("is_bot", true)), "disconnected seat remains non-bot for the current round")
	var survivor_peer := int(room.host_peer)
	service.handle_message(survivor_peer, {"type":Protocol.START_NEXT_ROUND, "payload":{}})
	_check(room.match_state.current_round == 2 and bool(room.members[current_index].get("is_bot", false)), "disconnected seat becomes a bot at the same index on the next round")
	_check(not room.game_state.players[current_index].hand.is_empty(), "replacement bot receives a fresh dealt hand")

func _test_multiple_disconnect_order() -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	service.handle_message(1401, {"type":Protocol.CREATE_ROOM, "payload":{"name":"A", "max_players":3}})
	var code := str(_last_message(1401, Protocol.ROOM_CREATED).payload.room_code)
	service.handle_message(1402, {"type":Protocol.JOIN_ROOM, "payload":{"name":"B", "room_code":code}})
	service.handle_message(1403, {"type":Protocol.JOIN_ROOM, "payload":{"name":"C", "room_code":code}})
	_ready_peers(service, [1401, 1402, 1403])
	service.handle_message(1401, {"type":Protocol.START_GAME, "payload":{"fill_bots":false}})
	var room: Dictionary = service.rooms[code]
	var active_index: int = room.game_state.current_player
	var departed_indices: Array[int] = []
	for i in range(room.members.size()):
		if i != active_index:
			departed_indices.append(i)
	service.peer_disconnected(int(room.members[departed_indices[0]].peer_id))
	_check(room.phase == "playing" and room.game_state.players[departed_indices[0]].finished and room.game_state._active_player_count() == 2, "a non-current forfeit is finished while remaining players stay active")
	service.peer_disconnected(int(room.members[departed_indices[1]].peer_id))
	_check(room.phase == "results" and room.game_state.finishing_order == [active_index, departed_indices[0], departed_indices[1]], "multiple disconnects settle in stable departure order behind the remaining player")

func _test_invalid_match_length() -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	service.handle_message(995, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":4, "match_round_limit":6}})
	_check(service.rooms.is_empty() and _last_message(995, Protocol.ACTION_REJECTED).size() > 0, "server rejects match lengths outside 4, 8, and 12")

func _test_server_ready_authority() -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	service.handle_message(910, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":4}})
	var code := ""
	for message in messages_by_peer.get(910, []):
		if message.type == Protocol.ROOM_CREATED:
			code = str(message.payload.room_code)
	service.handle_message(911, {"type":Protocol.JOIN_ROOM, "payload":{"name":"Guest", "room_code":code}})
	service.handle_message(911, {"type":Protocol.SET_READY, "payload":{"ready":true}})
	service.handle_message(910, {"type":Protocol.START_GAME, "payload":{"fill_bots":false}})
	_check(service.rooms[code].phase == "lobby" and _last_message(910, Protocol.ACTION_REJECTED).payload.reason == "All human players must be Ready before starting.", "server rejects start when host is Not Ready")
	service.handle_message(910, {"type":Protocol.SET_READY, "payload":{"ready":true}})
	service.handle_message(911, {"type":Protocol.SET_READY, "payload":{"ready":false}})
	service.handle_message(910, {"type":Protocol.START_GAME, "payload":{"fill_bots":false}})
	_check(service.rooms[code].phase == "lobby", "server rejects start when joiner is Not Ready")
	service.handle_message(911, {"type":Protocol.SET_READY, "payload":{"ready":true}})
	service.handle_message(912, {"type":Protocol.JOIN_ROOM, "payload":{"name":"New guest", "room_code":code}})
	_check(not bool(service.rooms[code].members[2].ready), "new human joins Not Ready")
	service.handle_message(910, {"type":Protocol.START_GAME, "payload":{"fill_bots":true}})
	_check(service.rooms[code].phase == "lobby", "new Not Ready player blocks server start even with bot fill")
	service.handle_message(912, {"type":Protocol.SET_READY, "payload":{"ready":true}})
	service.handle_message(911, {"type":Protocol.START_GAME, "payload":{"fill_bots":true}})
	_check(service.rooms[code].phase == "lobby" and str(_last_message(911, Protocol.ACTION_REJECTED).payload.reason) == "Only the host can start the game.", "non-host Start Game request receives an explicit rejection")
	service.handle_message(910, {"type":Protocol.START_GAME, "payload":{"fill_bots":true}})
	_check(service.rooms[code].phase == "playing" and service.rooms[code].members.size() == 4 and bool(service.rooms[code].members[3].get("ready", false)), "all Ready humans can start and bots are automatically Ready")
	service.handle_message(910, {"type":Protocol.START_GAME, "payload":{"fill_bots":true}})
	_check(service.rooms[code].match_state.current_round == 1 and str(_last_message(910, Protocol.ACTION_REJECTED).payload.reason) == "The game is already running.", "duplicate Start Game request is rejected without initializing a second match")
	var host_lobby := _last_message(910, Protocol.LOBBY_STATE)
	var guest_lobby := _last_message(911, Protocol.LOBBY_STATE)
	_check(host_lobby.payload.all_ready and guest_lobby.payload.all_ready and host_lobby.payload.ready_count == guest_lobby.payload.ready_count, "readiness summary is broadcast identically to clients")

func _test_start_game_initializes_first_round() -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	service.handle_message(905, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":2, "match_round_limit":4}})
	var code := str(_last_message(905, Protocol.ROOM_CREATED).get("payload", {}).get("room_code", ""))
	service.handle_message(906, {"type":Protocol.JOIN_ROOM, "payload":{"name":"Guest", "room_code":code}})
	_ready_peers(service, [905, 906])
	service.handle_message(905, {"type":Protocol.START_GAME, "payload":{"fill_bots":false}})
	var room: Dictionary = service.rooms[code]
	_check(room.phase == "playing" and room.match_state.current_round == 1, "two-human Start Game initializes the first round")
	_check(room.game_state != null and room.game_state.players.size() == 2 and room.game_state.players[0].hand.size() > 0, "first round creates and deals a GameState")
	_check(_last_message(905, Protocol.START_GAME).size() > 0 and _last_message(906, Protocol.START_GAME).size() > 0 and _last_message(905, Protocol.DEAL).size() > 0 and _last_message(906, Protocol.DEAL).size() > 0 and _last_message(905, Protocol.TURN_CHANGED).size() > 0 and _last_message(906, Protocol.TURN_CHANGED).size() > 0, "first-round start, deal, and turn snapshots reach both peers")
	room.game_state.finishing_order.clear()
	room.game_state.finishing_order.append(0)
	room.game_state.finishing_order.append(1)
	service._finish_round(room)
	service.handle_message(905, {"type":Protocol.START_NEXT_ROUND, "payload":{}})
	_check(room.phase in ["card_exchange", "playing"] and room.match_state.current_round == 2 and room.game_state != null and room.game_state.players.size() == 2, "next-round path reuses the GameState constructor successfully")

func _last_message(peer_id: int, message_type: String) -> Dictionary:
	var result := {}
	for message in messages_by_peer.get(peer_id, []):
		if message.type == message_type:
			result = message
	return result

func _test_decks_and_deals() -> void:
	for count in [2, 6, 7, 12]:
		var rng := RandomNumberGenerator.new()
		rng.seed = count
		var deck = DeckFactory.create_deck(count, rng)
		var expected_decks := 1 if count <= 6 else 2
		_check(deck.size() == expected_decks * 52, "%d players use the correct deck count" % count)
		var hands = DeckFactory.deal(deck, count)
		var total := 0
		var unique := {}
		for hand in hands:
			total += hand.size()
			for card: CardData in hand:
				unique[card.card_id()] = true
		_check(total == deck.size() and unique.size() == deck.size(), "%d-player deal assigns every unique card once" % count)
		var min_hand := 999
		var max_hand := 0
		for hand in hands:
			min_hand = mini(min_hand, hand.size())
			max_hand = maxi(max_hand, hand.size())
		_check(max_hand - min_hand <= 1, "%d-player hand sizes differ by at most one" % count)
	var sorted: Array = [_card("2"), _card("3", "Spades"), _card("3", "Clubs")]
	HandSorterScript.sort_hand(sorted)
	_check(sorted[0].rank == "3" and sorted[1].rank == "3" and sorted[2].rank == "2" and sorted[0].suit == "Clubs" and sorted[1].suit == "Spades", "hand sorter orders ranks and uses the shared suit order")
	var duplicate_sort: Array = [_card("3", "Spades", 1), _card("3", "Spades", 0), _card("3", "Diamonds")]
	HandSorterScript.sort_hand(duplicate_sort)
	_check(duplicate_sort[0].suit == "Diamonds" and duplicate_sort[1].deck_index == 0 and duplicate_sort[2].deck_index == 1, "duplicate identical cards use deck identity only as a final presentation sort")

func _test_roles() -> void:
	var order: Array[int] = []
	for i in range(7):
		order.append(i)
	var result: Dictionary = RoleSystemScript.resolve(order, 7, {})
	_check(result.ok and str(result.roles_by_player[0]) == "King", "first place receives King")
	_check(str(result.roles_by_player[6]) == "Slave 1", "last place receives Slave 1")
	_check(RoleSystemScript.role_order_for_count(7) == ["King", "Queen", "Seven", "4th", "Slave 3", "Slave 2", "Slave 1"], "seven-player role order includes King, Queen, Seven, and three Slaves")
	var previous := {0:"King", 1:"Queen", 2:"Seven", 3:"4th", 4:"Slave 3", 5:"Slave 2", 6:"Slave 1"}
	var lost_order: Array[int] = [1, 2, 3, 4, 5, 6, 0]
	var lost: Dictionary = RoleSystemScript.resolve(lost_order, 7, previous)
	_check(lost.previous_king_demoted and str(lost.roles_by_player[0]) == "Slave 1" and str(lost.roles_by_player[1]) == "King", "previous King loses and is demoted while winner becomes King")
	var won_order: Array[int] = [0, 1, 2, 3, 4, 5, 6]
	var won: Dictionary = RoleSystemScript.resolve(won_order, 7, previous)
	_check(not won.previous_king_demoted and str(won.roles_by_player[0]) == "King", "previous King can win again and retain King")

func _test_exchange() -> void:
	var game = GameStateScript.new()
	game.start(12, 1234)
	var roles := {0:"King", 1:"Queen", 2:"Seven", 9:"Slave 3", 10:"Slave 2", 11:"Slave 1"}
	var flags: Array[bool] = []
	var before: Array[int] = []
	for i in range(12):
		flags.append(true)
		before.append(game.players[i].hand.size())
	var exchange = CardExchangeScript.new()
	var result: Dictionary = exchange.begin(game.players, roles, flags)
	var amounts := {}
	for transfer in exchange.completed_transfers:
		amounts[str(transfer.amount)] = true
	var after: Array[int] = []
	for player in game.players:
		after.append(player.hand.size())
	_check(result.ok and exchange.is_complete() and amounts.has("3") and amounts.has("2") and amounts.has("1"), "roles exchange exactly 3, 2, and 1 cards")
	_check(before == after, "exchange preserves every hand size")

func _test_trade_rules() -> void:
	var game = GameStateScript.new()
	game.start(7, 771)
	var roles := {0:"King", 1:"Queen", 2:"Seven", 3:"4th", 4:"Slave 3", 5:"Slave 2", 6:"Slave 1"}
	var bot_flags: Array[bool] = [false, false, false, false, false, false, false]
	for player_index in range(7):
		var hand: Array = []
		for rank in ["3", "4", "5", "6", "7"]:
			hand.append(_card(rank, "Clubs", player_index))
		game.players[player_index].hand = hand
	var exchange = CardExchangeScript.new()
	var begin_result: Dictionary = exchange.begin(game.players, roles, bot_flags)
	_check(begin_result.ok and not exchange.is_complete() and exchange.pending_returns.size() == 3, "trade waits for the three upper-role selections")
	_check(exchange.pending_amount_for(0) == 3 and exchange.pending_amount_for(1) == 2 and exchange.pending_amount_for(2) == 1, "King, Queen, and Seven receive exact 3/2/1 return counts")
	_check(exchange.mandatory_ids_for(6) == _ids(game.players[6].hand.slice(2, 5)), "Slave 1 is assigned its highest three cards")
	_check(exchange.mandatory_ids_for(5) == _ids(game.players[5].hand.slice(3, 5)), "Slave 2 is assigned its highest two cards")
	_check(exchange.mandatory_ids_for(4) == _ids(game.players[4].hand.slice(4, 5)), "Slave 3 is assigned its highest card")
	var before_sizes: Array[int] = []
	for player in game.players:
		before_sizes.append(player.hand.size())
	var slave_one_wrong := _ids(game.players[6].hand.slice(0, 3))
	var rejected_slave: Dictionary = exchange.select_return_cards(6, slave_one_wrong, game.players)
	_check(not rejected_slave.ok, "Slave cannot substitute lower cards for its mandatory highest cards")
	var king_ids: Array[String] = [_ids(game.players[0].hand)[0], _ids(game.players[0].hand)[2], _ids(game.players[0].hand)[4]]
	var queen_ids: Array[String] = [_ids(game.players[1].hand)[1], _ids(game.players[1].hand)[3]]
	var seven_ids: Array[String] = [_ids(game.players[2].hand)[4]]
	exchange.select_return_cards(0, king_ids, game.players)
	exchange.select_return_cards(1, queen_ids, game.players)
	_check(not exchange.is_complete() and bool(exchange.ready_by_player[6]) and exchange.readiness_by_role()["King"] == "Ready", "upper-role selections are tracked while slaves are automatically ready")
	exchange.select_return_cards(2, seven_ids, game.players)
	var after_sizes: Array[int] = []
	for player in game.players:
		after_sizes.append(player.hand.size())
	_check(exchange.is_complete() and exchange.completed_transfers.size() == 3, "all three exchanges commit together after every role is ready")
	_check(before_sizes == after_sizes, "completed role trades preserve every hand size")
	_check(_contains_all_ids(game.players[0].hand, exchange.completed_transfers[0].given_card_ids), "King receives Slave 1's server-selected highest cards")
	var sorted_hands := true
	for player in game.players:
		for i in range(1, player.hand.size()):
			sorted_hands = sorted_hands and player.hand[i - 1].strength() <= player.hand[i].strength()
	_check(sorted_hands, "all hands are sorted after the completed trade")
	_check(not exchange.is_participant(3), "players outside the six exchange roles are marked as nonparticipants")

func _contains_all_ids(hand: Array, ids: Array) -> bool:
	var owned := {}
	for card: CardData in hand:
		owned[card.card_id()] = true
	for id in ids:
		if not owned.has(str(id)):
			return false
	return true

func _test_entry_input_layout() -> void:
	var flow = MultiplayerFlowScript.new()
	add_child(flow)
	var name_label: Label = flow.find_child("NameLabel", true, false)
	var host_label: Label = flow.find_child("HostLabel", true, false)
	var name_input: LineEdit = flow.find_child("NameInput", true, false)
	var host_input: LineEdit = flow.find_child("HostInput", true, false)
	var single_button: Button = flow.find_child("Action_SinglePlayer", true, false)
	_check(name_label != null and name_label.visible and name_label.text == "Name", "entry screen shows a visible Name label")
	_check(name_input != null and single_button != null and is_equal_approx(name_input.custom_minimum_size.x, single_button.custom_minimum_size.x), "Name input width matches the main action button width")
	flow.free()

func _test_trade_waiting_ui() -> void:
	var flow = MultiplayerFlowScript.new()
	add_child(flow)
	flow.online_phase = "card_exchange"
	flow.online_round = 2
	flow.online_player_index = 3
	flow.online_players = [
		{"name":"King"}, {"name":"Queen"}, {"name":"Seven"}, {"name":"Guest"},
		{"name":"Slave 3"}, {"name":"Slave 2"}, {"name":"Slave 1"}
	]
	flow.exchange_role = "4th"
	flow.exchange_participant = false
	flow.exchange_readiness = {"King":"Ready", "Queen":"Selecting", "Seven":"Ready", "Slave 1":"Ready", "Slave 2":"Ready", "Slave 3":"Selecting"}
	flow._show_online_game()
	_check(flow.find_child("TradeWaiting", true, false) != null and flow.find_child("TradeWaiting", true, false).text == "Waiting Trade", "nonparticipant sees Waiting Trade instead of a playable hand")
	_check(flow.find_child("TradeStatus_King", true, false) != null, "trade waiting screen shows role readiness progress")
	flow.exchange_role = "King"
	flow.exchange_participant = true
	flow.exchange_readiness["King"] = "Ready"
	flow._show_online_game()
	_check(flow.find_child("TradeWaiting", true, false) != null and flow.find_child("TradeWaiting", true, false).text == "Waiting Trade", "confirmed trader sees Waiting Trade and cannot edit cards")
	flow.exchange_role = "Slave 1"
	flow.exchange_participant = true
	flow.return_card_count = 3
	flow.exchange_readiness["Slave 1"] = "Selecting"
	flow.online_hand.clear()
	flow.online_hand.append_array([_card("3"), _card("4"), _card("5"), _card("6")])
	flow.exchange_mandatory_ids.clear()
	flow.exchange_mandatory_ids.append_array([_ids(flow.online_hand)[1], _ids(flow.online_hand)[2], _ids(flow.online_hand)[3]])
	flow.selected_card_ids.clear()
	flow._show_online_game()
	_check(flow.selected_card_ids == flow.exchange_mandatory_ids, "Slave hand automatically selects the server-mandated highest cards")
	flow._toggle_card(flow.exchange_mandatory_ids[0])
	_check(flow.selected_card_ids.size() == 3, "Slave cannot deselect a mandatory card")
	flow.exchange_role = "King"
	flow.return_card_count = 3
	flow.exchange_mandatory_ids.clear()
	flow.exchange_readiness["King"] = "Selecting"
	flow.selected_card_ids.clear()
	flow._show_online_game()
	var confirm: Button = flow.find_child("ConfirmTradeButton", true, false)
	_check(confirm != null and confirm.disabled, "upper-role Confirm Trade is disabled until exactly three cards are selected")
	flow._toggle_card(_ids(flow.online_hand)[0])
	flow._toggle_card(_ids(flow.online_hand)[1])
	confirm = flow.find_child("ConfirmTradeButton", true, false)
	_check(confirm != null and confirm.disabled, "upper role cannot confirm a partial trade")
	flow._toggle_card(_ids(flow.online_hand)[2])
	confirm = flow.find_child("ConfirmTradeButton", true, false)
	_check(confirm != null and not confirm.disabled, "upper role can confirm after selecting exactly the required cards")
	flow.free()

func _test_server_trade_authority() -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	var peers: Array[int] = [7800, 7801, 7802, 7803, 7804, 7805, 7806]
	service.handle_message(peers[0], {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":7}})
	var code := ""
	for message in messages_by_peer.get(peers[0], []):
		if message.type == Protocol.ROOM_CREATED:
			code = str(message.payload.room_code)
	for i in range(1, peers.size()):
		service.handle_message(peers[i], {"type":Protocol.JOIN_ROOM, "payload":{"name":"Guest %d" % i, "room_code":code}})
	_ready_peers(service, peers)
	service.handle_message(peers[0], {"type":Protocol.START_GAME, "payload":{"fill_bots":false}})
	var room: Dictionary = service.rooms[code]
	room.phase = "results"
	room.round_number = 1
	room.roles_by_player = {0:"King", 1:"Queen", 2:"Seven", 3:"4th", 4:"Slave 3", 5:"Slave 2", 6:"Slave 1"}
	service._start_round(room)
	var game: GameState = room.game_state
	_check(room.phase == "card_exchange" and not room.exchange.is_complete(), "server holds the room in exchange until human role participants respond")
	var initial_sizes: Array[int] = []
	for player in game.players:
		initial_sizes.append(player.hand.size())
	var incorrect_slave_ids: Array[String] = []
	for card: CardData in game.players[6].hand:
		if not room.exchange.mandatory_ids_for(6).has(card.card_id()):
			incorrect_slave_ids.append(card.card_id())
			if incorrect_slave_ids.size() == 3:
				break
	service.handle_message(peers[6], {"type":Protocol.SELECT_CARDS, "payload":{"card_ids":incorrect_slave_ids}})
	_check(room.phase == "card_exchange" and bool(room.exchange.ready_by_player[6]) and initial_sizes[6] == game.players[6].hand.size(), "slave readiness is automatic and invalid selection cannot change hands")
	for player_index in [0, 1, 2]:
		var ids: Array[String] = []
		var amount: int = room.exchange.pending_amount_for(player_index)
		for card: CardData in game.players[player_index].hand:
			ids.append(card.card_id())
			if ids.size() == amount:
				break
		service.handle_message(peers[player_index], {"type":Protocol.SELECT_CARDS, "payload":{"card_ids":ids}})
		if player_index != 2:
			_check(room.phase == "card_exchange", "server waits for the remaining participants after player %d confirms" % (player_index + 1))
	var final_sizes: Array[int] = []
	for player in game.players:
		final_sizes.append(player.hand.size())
	_check(room.phase == "playing" and room.exchange.is_complete(), "server commits trade after all upper roles confirm")
	_check(initial_sizes == final_sizes, "server-authoritative trade preserves hand sizes")
	_check(room.exchange.readiness_by_role().size() == 6, "server publishes ready state for all six trade roles")

func _test_turn_flow() -> void:
	var game = GameStateScript.new()
	game.start(4, 99)
	game.players[0].hand = [_card("3"), _card("7")]
	game.players[1].hand = [_card("4")]
	game.players[2].hand = [_card("5"), _card("8")]
	game.players[3].hand = [_card("6")]
	game.players[1].finished = true
	game.finishing_order.append(1)
	game.current_player = 0
	game.turns.start_at(0, 4)
	_check(game.play_card(0, game.players[0].hand[0]) and game.current_player == 2, "turn order skips a finished player")
	_check(game.play_card(2, game.players[2].hand[0]) and game.current_player == 3, "turn order advances after legal play")
	_check(game.pass_turn(3) and game.current_player == 0 and not game.current_cards.is_empty(), "first pass advances without prematurely resetting the trick")
	_check(game.pass_turn(0) and game.current_cards.is_empty() and game.current_player == 2 and game.last_player == -1, "trick resets to last active player only after all others pass")
	_check(not game.passed[0] and not game.passed[1] and not game.passed[2] and not game.passed[3], "pass flags clear between tricks")
	game.players[2].finished = true
	game.finishing_order.append(2)
	game.current_player = 0
	game.last_player = 2
	game.current_cards.assign([_card("7")])
	game.passed[0] = false
	game.passed[3] = true
	_check(game.pass_turn(0) and game.current_player == 3 and game.current_cards.is_empty(), "finished last player is skipped when a trick resets")

func _test_local_combo_flow() -> void:
	var straight_game = GameStateScript.new()
	straight_game.start(2, 109, 0)
	var straight: Array = [_card("4", "Clubs"), _card("5", "Diamonds"), _card("6", "Hearts"), _card("7", "Spades"), _card("8", "Clubs")]
	straight_game.players[0].hand = straight + [_card("Q", "Diamonds")]
	straight_game.players[1].hand = [_card("9", "Clubs"), _card("9", "Hearts")]
	_check(straight_game.play_cards(0, straight) and straight_game.current_combination.type == "Straight" and straight_game.current_player == 1, "local game accepts a five-card Straight lead and advances turn")
	_check(not straight_game.play_cards(1, straight_game.players[1].hand) and straight_game.current_player == 1, "local game rejects an even-family Pair against an odd-family Straight")
	_check(straight_game.pass_turn(1) and straight_game.current_cards.is_empty() and straight_game.current_player == 0, "passing resets the local trick to its Straight leader")
	var switch_game = GameStateScript.new()
	switch_game.start(2, 110, 0)
	switch_game.players[0].hand = [_card("6", "Clubs"), _card("Q", "Hearts")]
	var triple: Array = [_card("7", "Clubs"), _card("7", "Diamonds"), _card("7", "Hearts")]
	switch_game.players[1].hand = triple + [_card("K", "Spades")]
	_check(switch_game.play_card(0, switch_game.players[0].hand[0]) and switch_game.current_player == 1, "local game begins a Single trick and advances turn")
	_check(switch_game.play_cards(1, triple) and switch_game.current_combination.type == "Triple" and switch_game.current_player == 0, "local game accepts a legal Triple response to a Single")
	_check(switch_game.pass_turn(0) and switch_game.current_cards.is_empty() and switch_game.current_player == 1, "pass after a cross-type response resets to the last player")

func _test_round_starter() -> void:
	var game = GameStateScript.new()
	game.start(4, 11, 2)
	_check(game.current_player == 2 and game.turns.current_player == 2, "specified previous-round winner starts the next round")
	game.start(4, 12, -1)
	_check(game.current_player >= 0 and game.current_player < 4, "first round still chooses a valid random starter")

func _test_pass_regressions() -> void:
	var two_player = GameStateScript.new()
	two_player.start(2, 201)
	two_player.players[0].hand = [_card("8"), _card("9"), _card("10")]
	two_player.players[1].hand = [_card("J")]
	two_player.current_player = 0
	two_player.turns.start_at(0, 2)
	_check(two_player.play_card(0, two_player.players[0].hand[0]) and two_player.current_player == 1, "two-player lead advances to the other player")
	_check(two_player.pass_turn(1) and two_player.current_cards.is_empty() and two_player.current_player == 0, "two-player pass resets to the last successful player")
	_check(not two_player.passed[0] and not two_player.passed[1], "two-player reset clears both pass flags")
	_check(two_player.play_card(0, two_player.players[0].hand[0]) and two_player.current_player == 1, "leader plays once after reset and gives the next turn to the opponent")

	var mixed = GameStateScript.new()
	mixed.start(4, 202)
	mixed.players[0].hand = [_card("3"), _card("8")]
	mixed.players[1].hand = [_card("4"), _card("9")]
	mixed.players[2].hand = [_card("5"), _card("10")]
	mixed.players[3].hand = [_card("6"), _card("J")]
	mixed.current_player = 0
	mixed.turns.start_at(0, 4)
	_check(mixed.play_card(0, mixed.players[0].hand[0]) and mixed.current_player == 1, "four-player sequence starts at A then B")
	_check(mixed.pass_turn(1) and mixed.current_player == 2, "B's pass advances to C without ending the trick")
	_check(mixed.play_card(2, mixed.players[2].hand[0]) and mixed.current_player == 3, "C's higher play advances to D")
	_check(mixed.pass_turn(3) and mixed.current_player == 0, "D's pass advances to A")
	_check(mixed.pass_turn(0) and mixed.current_cards.is_empty() and mixed.current_player == 2, "trick resets only after A passes while B is already passed")
	_check(not mixed.passed[0] and not mixed.passed[1] and not mixed.passed[2] and not mixed.passed[3], "mixed sequence clears all passes for the next trick")
	_check(mixed.play_card(2, mixed.players[2].hand[0]) and mixed.current_player == 3, "C leads the new trick once and advances normally")

func _test_bot_pass_turn_regression() -> void:
	var game = GameStateScript.new()
	game.start(2, 203)
	game.players[0].hand = [_card("8")]
	game.players[1].hand = [_card("9"), _card("J"), _card("Q")]
	game.current_player = 1
	game.turns.start_at(1, 2)
	var bot = BotBrainScript.new()
	var opening: Array = bot.choose_play(game.players[1].hand, [], game.rules)
	_check(game.play_cards(1, opening) and game.current_player == 0, "bot's active play advances to its human opponent")
	_check(game.pass_turn(0) and game.current_player == 1 and game.current_cards.is_empty(), "human pass resets the trick and gives the bot a new lead")
	var next_lead: Array = bot.choose_play(game.players[1].hand, [], game.rules)
	_check(game.play_cards(1, next_lead) and game.current_player == 0, "bot leads once after reset and advances back to the human")
	var hand_size: int = game.players[1].hand.size()
	_check(not game.play_cards(1, [_card("Q")]) and game.players[1].hand.size() == hand_size, "bot cannot take a consecutive turn after the human has received it")

func _test_combinations() -> void:
	var rules = GameRulesScript.new()
	_check(rules.classify([_card("9")]).type == "Single", "recognizes Single")
	_check(rules.classify([_card("9"), _card("9", "Hearts")]).type == "Pair", "recognizes Pair")
	_check(rules.classify([_card("9"), _card("9", "Hearts"), _card("9", "Spades")]).type == "Triple", "recognizes Triple")
	_check(rules.classify([_card("9"), _card("9", "Hearts"), _card("9", "Spades"), _card("9", "Diamonds")]).type == "Four of a Kind", "recognizes Four of a Kind")
	_check(rules.classify([_card("5", "Clubs"), _card("6", "Diamonds"), _card("7", "Hearts"), _card("8", "Spades"), _card("9", "Clubs")]).type == "Straight", "recognizes mixed-suit five-card Straight")
	_check(rules.classify([_card("5", "Spades"), _card("6", "Spades"), _card("7", "Spades"), _card("8", "Spades"), _card("9", "Spades")]).type == "Straight Flush", "recognizes Straight Flush before ordinary Straight")
	_check(not rules.classify([]).valid and not rules.classify([_card("9"), _card("10")]).valid, "rejects empty and wrong-count plays")
	_check(not rules.classify([_card("9"), _card("9", "Hearts"), _card("10")]).valid, "rejects mixed-rank invalid combination")
	_check(not rules.classify([_card("5"), _card("6"), _card("8"), _card("9"), _card("10")]).valid, "rejects nonconsecutive Straight")
	_check(not rules.classify([_card("A"), _card("2"), _card("3"), _card("4"), _card("5")]).valid, "Straight does not wrap rank order")
	_check(rules.can_beat([_card("10")], [_card("9")]), "higher Single beats lower Single")
	_check(rules.can_beat([_card("10"), _card("10", "Hearts")], [_card("9"), _card("9", "Hearts")]), "higher Pair beats lower Pair")
	_check(rules.can_beat([_card("10"), _card("10", "Hearts"), _card("10", "Spades")], [_card("9"), _card("9", "Hearts"), _card("9", "Spades")]), "higher Triple beats lower Triple")
	_check(rules.can_beat([_card("10"), _card("10", "Hearts"), _card("10", "Spades"), _card("10", "Diamonds")], [_card("9"), _card("9", "Hearts"), _card("9", "Spades"), _card("9", "Diamonds")]), "higher Four beats lower Four")
	_check(rules.can_beat([_card("6"), _card("7"), _card("8"), _card("9"), _card("10")], [_card("5"), _card("6", "Hearts"), _card("7", "Spades"), _card("8"), _card("9")]), "higher Straight beats lower Straight")
	_check(not rules.can_beat([_card("9"), _card("9", "Hearts")], [_card("9", "Spades"), _card("9", "Diamonds")]), "rejects equal rank")
	_check(not rules.can_beat([_card("8")], [_card("9")]), "rejects lower rank")
	_check(not rules.can_beat([_card("4"), _card("4", "Hearts"), _card("4", "Spades")], [_card("8"), _card("8", "Hearts")]), "Pair cannot be answered by a Triple")
	_check(rules.can_beat([_card("5"), _card("6"), _card("7"), _card("8"), _card("9")], [_card("8"), _card("8", "Hearts"), _card("8", "Spades")]), "Straight can answer a Triple in the odd family")
	_check(not rules.can_beat([_card("8")], [_card("7"), _card("7", "Hearts"), _card("7", "Spades")]), "Triple cannot be answered by a Single")
	_check(not rules.can_beat([_card("8"), _card("8", "Hearts")], [_card("7"), _card("7", "Hearts"), _card("7", "Spades")]), "Triple cannot be answered by a Pair")
	_check(not rules.classify([_card("3"), _card("4"), _card("5")]).valid, "rejects three-card Straight")
	_check(not rules.classify([_card("3"), _card("4"), _card("5"), _card("6")]).valid, "rejects four-card Straight")
	_check(not rules.classify([_card("5", "Clubs"), _card("6", "Clubs"), _card("7", "Clubs")]).valid, "rejects three-card Straight Flush")
	_check(not rules.classify([_card("5", "Clubs"), _card("6", "Clubs"), _card("7", "Clubs"), _card("8", "Clubs")]).valid, "rejects four-card Straight Flush")
	_check(rules.can_beat([_card("5"), _card("6"), _card("7"), _card("8"), _card("9")], [_card("3"), _card("3", "Hearts"), _card("3", "Spades")]), "Straight can answer a Triple")
	_check(not rules.can_beat([_card("5"), _card("5", "Hearts"), _card("5", "Spades")], [_card("3"), _card("4"), _card("5"), _card("6"), _card("7")]), "three-card Triple does not outrank the existing five-card Straight tier")
	_check(rules.can_beat([_card("8"), _card("8", "Hearts"), _card("8", "Spades")], [_card("7"), _card("7", "Hearts"), _card("7", "Spades")]), "higher Triple beats lower Triple")
	_check(rules.can_beat([_card("6"), _card("7"), _card("8"), _card("9"), _card("10")], [_card("5"), _card("6"), _card("7"), _card("8"), _card("9")]), "higher five-card Straight beats lower Straight")
	_check(not rules.can_beat([_card("5"), _card("5", "Hearts")], [_card("3")]), "Pair cannot be answered by a Single because even and odd counts cannot mix")
	_check(not rules.can_beat([_card("3")], [_card("5"), _card("5", "Hearts")]), "Single cannot be answered by a Pair because odd and even counts cannot mix")
	_check(not rules.can_beat([_card("8"), _card("8", "Hearts")], [_card("J"), _card("J", "Hearts")]), "same-type lower Pair is rejected")
	_check(not rules.can_beat([_card("9"), _card("9", "Hearts")], [_card("9", "Spades"), _card("9", "Hearts")]), "same-type equal-strength Pair is rejected")
	_check(not rules.can_beat([_card("9"), _card("9", "Hearts")], [_card("8")]), "Single cannot be answered by a Pair")
	_check(not rules.can_beat([_card("9"), _card("10"), _card("J"), _card("Q")], [_card("8"), _card("9", "Hearts"), _card("10", "Spades"), _card("J"), _card("Q")]), "rejects four-card plays against a Straight")
	_check(rules.can_beat([_card("3")], [],), "a new trick accepts a Single lead")
	_check(rules.can_beat([_card("3"), _card("3", "Hearts")], [],), "a new trick accepts a Pair lead")
	_check(rules.can_beat([_card("3"), _card("3", "Hearts"), _card("3", "Spades")], [],), "a new trick accepts a Triple lead")
	_check(rules.can_beat([_card("5", "Clubs"), _card("6", "Diamonds"), _card("7", "Hearts"), _card("8", "Spades"), _card("9", "Clubs")], []), "a new trick accepts a Straight lead")
	_check(rules.can_beat([_card("5", "Hearts"), _card("6", "Hearts"), _card("7", "Hearts"), _card("8", "Hearts"), _card("9", "Hearts")], []), "a new trick accepts a Straight Flush lead")
	_check(not rules.can_beat([_card("3"), _card("3", "Hearts")], [_card("3")]), "Single cannot be answered by Pair")
	_check(not rules.can_beat([_card("4"), _card("4", "Hearts"), _card("4", "Spades")], [_card("3"), _card("3", "Hearts")]), "Pair cannot be answered by Triple")
	_check(rules.can_beat([_card("4"), _card("4", "Hearts"), _card("4", "Spades")], [_card("3")]), "Single can be answered by a stronger Triple in the odd family")
	_check(rules.can_beat([_card("4", "Clubs"), _card("4", "Diamonds"), _card("4", "Hearts"), _card("4", "Spades")], [_card("3"), _card("3", "Hearts")]), "Pair can be answered by a stronger Four in the even family")
	_check(rules.can_beat([_card("5", "Clubs"), _card("6", "Clubs"), _card("7", "Clubs"), _card("8", "Clubs"), _card("9", "Clubs")], [_card("10", "Clubs"), _card("J", "Diamonds"), _card("Q", "Hearts"), _card("K", "Spades"), _card("A", "Clubs")]), "Straight Flush beats higher-ranked ordinary Straight")
	_check(not rules.can_beat([_card("10", "Clubs"), _card("J", "Diamonds"), _card("Q", "Hearts"), _card("K", "Spades"), _card("A", "Clubs")], [_card("5", "Clubs"), _card("6", "Clubs"), _card("7", "Clubs"), _card("8", "Clubs"), _card("9", "Clubs")]), "ordinary Straight cannot beat Straight Flush")
	var generated_flush_plays: Array = rules.list_legal_combinations([_card("5", "Clubs"), _card("6", "Clubs"), _card("7", "Clubs"), _card("8", "Clubs"), _card("9", "Clubs")])
	var generated_straight_flush := false
	for generated_play: Array in generated_flush_plays:
		var generated_type: String = str(rules.classify(generated_play).type)
		if generated_type == "Straight Flush":
			generated_straight_flush = true
		_check(generated_play.size() != 3 and generated_play.size() != 4, "move generation never emits three- or four-card pseudo-Straights")
	_check(generated_straight_flush, "lead move generation includes Straight Flush")
	var configurable = GameRulesScript.new()
	configurable.straight_allow_two = false
	_check(not configurable.classify([_card("J"), _card("Q"), _card("K"), _card("A"), _card("2")]).valid, "straight configuration can exclude Two")

func _test_suit_comparisons() -> void:
	var rules = GameRulesScript.new()
	_check(rules.compare_suit_strength("Clubs", "Diamonds") < 0 and rules.compare_suit_strength("Diamonds", "Hearts") < 0 and rules.compare_suit_strength("Hearts", "Spades") < 0, "shared suit order is Clubs < Diamonds < Hearts < Spades")
	_check(not rules.can_beat([_card("3", "Clubs", 1)], [_card("3", "Clubs", 0)]), "equal Single rank and suit from another deck does not win")
	_check(rules.can_beat([_card("3", "Diamonds")], [_card("3", "Clubs")]), "3 Diamonds beats 3 Clubs")
	_check(rules.can_beat([_card("3", "Hearts")], [_card("3", "Diamonds")]), "3 Hearts beats 3 Diamonds")
	_check(rules.can_beat([_card("3", "Spades")], [_card("3", "Hearts")]), "3 Spades beats 3 Hearts")
	_check(rules.can_beat([_card("4", "Clubs")], [_card("3", "Spades")]), "higher Single rank beats any lower suit")
	var pair_center: Array = [_card("5", "Spades"), _card("5", "Diamonds")]
	var pair_winner: Array = [_card("5", "Spades", 1), _card("5", "Hearts")]
	_check(rules.can_beat(pair_winner, pair_center), "equal-rank Pair compares strongest suit then second suit")
	var pair_second_loses: Array = [_card("5", "Spades", 1), _card("5", "Diamonds", 1)]
	var pair_second_center: Array = [_card("5", "Spades"), _card("5", "Hearts")]
	_check(not rules.can_beat(pair_second_loses, pair_second_center), "Pair uses the second suit when strongest suits tie")
	var pair_equal_decks: Array = [_card("5", "Spades", 1), _card("5", "Diamonds", 0)]
	_check(not rules.can_beat(pair_equal_decks, pair_center), "identical Pair suit composition across decks is equal")
	var triple_center: Array = [_card("7", "Spades"), _card("7", "Diamonds"), _card("7", "Clubs")]
	var triple_winner: Array = [_card("7", "Spades", 1), _card("7", "Hearts"), _card("7", "Clubs", 1)]
	_check(rules.can_beat(triple_winner, triple_center), "equal-rank Triple compares its complete suit sequence")
	var triple_equal: Array = [_card("7", "Spades", 1), _card("7", "Diamonds", 1), _card("7", "Clubs", 1)]
	_check(not rules.can_beat(triple_equal, triple_center), "identical Triple suit composition does not win")
	var four_center: Array = [_card("8", "Spades"), _card("8", "Diamonds"), _card("8", "Diamonds", 1), _card("8", "Clubs")]
	var four_winner: Array = [_card("8", "Spades", 1), _card("8", "Hearts"), _card("8", "Diamonds"), _card("8", "Clubs", 1)]
	_check(rules.can_beat(four_winner, four_center), "equal-rank Four of a Kind compares the complete suit sequence")
	_check(not rules.can_beat(four_center.duplicate(), four_center), "identical Four of a Kind suit composition does not win")
	var straight_top_center: Array = [_card("5", "Clubs"), _card("6", "Diamonds"), _card("7", "Hearts"), _card("8", "Clubs"), _card("9", "Clubs")]
	var straight_top_winner: Array = [_card("5", "Diamonds"), _card("6", "Clubs"), _card("7", "Spades"), _card("8", "Diamonds"), _card("9", "Spades")]
	_check(rules.can_beat(straight_top_winner, straight_top_center), "equal-top-rank Straight uses the highest card suit")
	var straight_lower_center: Array = [_card("5", "Clubs"), _card("6", "Diamonds"), _card("7", "Hearts"), _card("8", "Clubs"), _card("9", "Spades")]
	var straight_lower_play: Array = [_card("5", "Hearts"), _card("6", "Clubs"), _card("7", "Spades", 1), _card("8", "Spades"), _card("9", "Hearts")]
	_check(not rules.can_beat(straight_lower_play, straight_lower_center), "Straight tie-break uses only the highest card suit")
	var straight_equal_decks: Array = [_card("5", "Clubs", 1), _card("6", "Diamonds", 1), _card("7", "Spades", 1), _card("8", "Hearts", 1), _card("9", "Spades", 1)]
	_check(not rules.can_beat(straight_equal_decks, [_card("5", "Clubs"), _card("6", "Diamonds"), _card("7", "Spades"), _card("8", "Hearts"), _card("9", "Spades")]), "identical Straight rank and suit sequence across decks is equal")
	_check(not rules.classify([_card("5"), _card("6"), _card("7"), _card("8")]).valid, "four-card sequence is not a Straight")
	var straight_flush_low: Array = [_card("5", "Clubs"), _card("6", "Clubs"), _card("7", "Clubs"), _card("8", "Clubs"), _card("9", "Clubs")]
	var straight_flush_high: Array = [_card("6", "Clubs"), _card("7", "Clubs"), _card("8", "Clubs"), _card("9", "Clubs"), _card("10", "Clubs")]
	_check(rules.classify(straight_flush_low).type == "Straight Flush" and rules.can_beat(straight_flush_high, straight_flush_low), "Straight Flush is explicit and higher sequence wins")
	var straight_flush_duplicate_deck: Array = [_card("5", "Clubs", 1), _card("6", "Clubs", 1), _card("7", "Clubs", 1), _card("8", "Clubs", 1), _card("9", "Clubs", 1)]
	_check(not rules.can_beat(straight_flush_duplicate_deck, straight_flush_low), "identical duplicate-deck Straight Flush is equal")
	var straight_flush_other_suit: Array = [_card("5", "Spades"), _card("6", "Spades"), _card("7", "Spades"), _card("8", "Spades"), _card("9", "Spades")]
	_check(rules.can_beat(straight_flush_other_suit, straight_flush_low), "equal-rank Straight Flush uses Clubs < Diamonds < Hearts < Spades")
	_check(rules.compare_combinations(pair_winner, pair_center) > 0 and rules.compare_combinations(pair_center, pair_winner) < 0, "shared combination comparator returns consistent ordering")
	_check(rules.list_legal_combinations_for_type([_card("3", "Diamonds"), _card("3", "Hearts")], [_card("3", "Clubs")], GameRulesScript.TYPE_SINGLE).size() == 2, "type-filtered legal-combination API supports future hints")

func _test_suit_selection_helpers() -> void:
	var rules = GameRulesScript.new()
	var single_hand: Array = [_card("3", "Clubs"), _card("3", "Diamonds"), _card("3", "Hearts"), _card("3", "Spades"), _card("4", "Clubs")]
	var singles: Dictionary = rules.selectable_card_ids(single_hand, [_card("3", "Diamonds")], [])
	_check(singles.size() == 5, "Single assistance includes cards in higher Singles and larger odd-count combinations")
	var pair_hand: Array = [_card("5", "Clubs"), _card("5", "Diamonds", 1), _card("5", "Spades", 1), _card("5", "Hearts")]
	var pair_selectable: Dictionary = rules.selectable_card_ids(pair_hand, [_card("5", "Spades"), _card("5", "Diamonds")], [])
	_check(pair_selectable.size() == 4, "Pair assistance includes cards in winning Pairs and larger even-count combinations")
	var triple_hand: Array = [_card("7", "Spades", 1), _card("7", "Hearts", 1), _card("7", "Clubs", 1)]
	var triple_selectable: Dictionary = rules.selectable_card_ids(triple_hand, [_card("7", "Spades"), _card("7", "Diamonds"), _card("7", "Clubs")], [])
	_check(triple_selectable.size() == 3, "Triple helper recognizes a legal equal-rank suit-sequence win")
	var straight_hand: Array = [_card("5", "Clubs", 1), _card("6", "Clubs"), _card("6", "Hearts"), _card("7", "Spades", 1), _card("8", "Diamonds"), _card("9", "Hearts")]
	var straight_selectable: Dictionary = rules.selectable_card_ids(straight_hand, [_card("4"), _card("5", "Diamonds"), _card("6", "Hearts"), _card("7", "Spades"), _card("8")], [])
	_check(straight_selectable.has(_card("5", "Clubs", 1).card_id()) and straight_selectable.has(_card("9", "Hearts").card_id()), "Straight assistance includes cards in a legal five-card response")
	var four_hand: Array = [_card("8", "Spades", 1), _card("8", "Hearts"), _card("8", "Diamonds"), _card("8", "Clubs", 1)]
	var four_selectable: Dictionary = rules.selectable_card_ids(four_hand, [_card("8", "Spades"), _card("8", "Diamonds"), _card("8", "Diamonds", 1), _card("8", "Clubs")], [])
	_check(four_selectable.size() == 4, "Four of a Kind helper uses suit-sequence comparison")

func _test_selection_helpers() -> void:
	var rules = GameRulesScript.new()
	var hand: Array = [_card("8"), _card("9", "Hearts"), _card("10"), _card("J"), _card("J", "Hearts"), _card("Q"), _card("Q", "Hearts"), _card("Q", "Spades"), _card("K"), _card("K", "Hearts"), _card("K", "Spades"), _card("K", "Diamonds"), _card("9", "Spades"), _card("10", "Hearts"), _card("J", "Spades")]
	var single_only_hand: Array = [_card("8"), _card("10")]
	var single_only: Dictionary = rules.selectable_card_ids(single_only_hand, [_card("9", "Hearts")], [])
	_check(not single_only.has(_card("8").card_id()) and single_only.has(_card("10").card_id()), "Single response assistance blocks lower Singles and enables a higher Single")
	var pair_only_hand: Array = [_card("8"), _card("8", "Hearts"), _card("10"), _card("10", "Hearts")]
	var pair_only: Dictionary = rules.selectable_card_ids(pair_only_hand, [_card("9"), _card("9", "Diamonds")], [])
	_check(pair_only.has(_card("10").card_id()) and pair_only.has(_card("10", "Hearts").card_id()) and not pair_only.has(_card("8").card_id()), "Pair response assistance enables higher Pairs and blocks lower Pairs")
	var triples: Dictionary = rules.selectable_card_ids(hand, [_card("9"), _card("9", "Diamonds"), _card("9", "Spades")], [])
	_check(triples.has(_card("Q").card_id()) and triples.has(_card("Q", "Hearts").card_id()), "Triple assist finds higher rank cards")
	var fours: Dictionary = rules.selectable_card_ids(hand, [_card("9"), _card("9", "Diamonds"), _card("9", "Spades"), _card("9", "Hearts")], [])
	_check(fours.has(_card("K").card_id()) and fours.has(_card("K", "Diamonds").card_id()), "Four assist finds higher rank cards")
	var straights: Dictionary = rules.selectable_card_ids(hand, [_card("6"), _card("7", "Hearts"), _card("8", "Diamonds"), _card("9"), _card("10")], [])
	_check(straights.has(_card("J").card_id()) and straights.has(_card("Q").card_id()), "Straight assist finds cards in higher five-card sequences")
	var odd_switch_hand: Array = [_card("4"), _card("5"), _card("6"), _card("7"), _card("8")]
	var odd_switch: Dictionary = rules.selectable_card_ids(odd_switch_hand, [_card("2", "Spades")], [])
	_check(odd_switch.size() == 5, "UI assistance allows a higher five-card Straight against a Single")
	var even_switch_hand: Array = [_card("3", "Clubs"), _card("3", "Diamonds"), _card("3", "Hearts"), _card("3", "Spades")]
	var even_switch: Dictionary = rules.selectable_card_ids(even_switch_hand, [_card("2", "Spades"), _card("2", "Diamonds")], [])
	_check(even_switch.size() == 4, "UI assistance preserves even-family Four against Pair")
	_check(rules.selectable_card_ids([_card("3"), _card("3", "Hearts")], [_card("2", "Spades")], []).is_empty(), "UI assistance blocks Pair cards against a Single")
	_check(rules.selectable_card_ids([_card("8")], [_card("7"), _card("7", "Hearts"), _card("7", "Spades")], []).is_empty(), "UI assistance blocks a Single against a Triple")
	var partial: Dictionary = rules.selectable_card_ids(hand, [_card("9"), _card("9", "Diamonds")], [_card("J").card_id()])
	_check(partial.has(_card("J", "Hearts").card_id()) and partial.has(_card("J", "Spades").card_id()), "partial Pair selection keeps cards completing a higher Pair")
	var partial_straight: Dictionary = rules.selectable_card_ids(hand, [_card("6"), _card("7", "Hearts"), _card("8", "Diamonds"), _card("9"), _card("10")], [_card("J").card_id()])
	_check(partial_straight.has(_card("Q").card_id()), "partial Straight selection retains cards completing a higher five-card combination")

func _test_card_hover_visuals() -> void:
	var card_view: CardView = CardViewScript.new()
	card_view.setup(_card("9", "Hearts"))
	var normal: StyleBoxFlat = card_view.get_theme_stylebox("normal")
	var hover: StyleBoxFlat = card_view.get_theme_stylebox("hover")
	_check(normal.bg_color == hover.bg_color and normal.border_color == hover.border_color, "hover keeps the card face and border unchanged")
	_check(card_view.get_theme_color("font_color") == card_view.get_theme_color("font_hover_color"), "hover keeps rank and suit ink unchanged")
	var unselected_face: StyleBoxFlat = card_view.get_theme_stylebox("normal")
	card_view.setup(_card("9", "Hearts"), true)
	var selected_normal: StyleBoxFlat = card_view.get_theme_stylebox("normal")
	var selected_hover: StyleBoxFlat = card_view.get_theme_stylebox("hover")
	_check(selected_normal.bg_color == selected_hover.bg_color and selected_normal.bg_color == unselected_face.bg_color, "selected card face stays unchanged during selection and hover")
	var hand_row := HBoxContainer.new()
	CardViewScript.add_hand_slot(hand_row, card_view, true)
	_check(card_view.position.y == 0.0, "selected card lift is vertical only")
	hand_row.free()

func _test_table_presentation() -> void:
	for count in range(2, 13):
		for local_index in range(count):
			var positions: Array[Vector2] = TablePresentationScript.normalized_seat_positions(count, false, local_index)
			var south := positions[local_index]
			var local_is_south := is_equal_approx(south.x, 0.5) and is_equal_approx(south.y, 0.9)
			var unique_positions := {}
			for position in positions:
				unique_positions["%.4f,%.4f" % [position.x, position.y]] = true
			var all_unique := unique_positions.size() == count
			var next_index := (local_index + 1) % count
			var next_position := positions[next_index]
			var next_moves_left := count == 2 or next_position.x < 0.5
			_check(local_is_south and all_unique and next_moves_left, "%d-player visual seats keep local South and deterministic next-player-left mapping (local %d)" % [count, local_index])
		var panel_size := TablePresentationScript.seat_panel_size(count)
		_check(panel_size.x >= 118.0 and panel_size.y >= 68.0, "%d-player seat panel remains readable" % count)
	for viewport_size in [Vector2(1920, 1080), Vector2(1600, 900), Vector2(1366, 768), Vector2(1280, 720), Vector2(800, 450), Vector2(2560, 1440), Vector2(3840, 2160)]:
		var layout: Dictionary = TableLayoutScript.layout_for_viewport(viewport_size)
		var table_rect: Rect2 = layout.table_zone
		_check(table_rect.size.x == table_rect.size.y and table_rect.position.x >= layout.canvas_origin.x, "square table fits centered at viewport %s" % viewport_size)
	var presentation = TablePresentationScript.new()
	add_child(presentation)
	_check(not presentation.table_artwork.visible, "table presentation avoids a second cropped square copy over the full-screen room artwork")
	presentation.free()
	var two_seats := TablePresentationScript.normalized_seat_positions(2)
	_check(two_seats[0].is_equal_approx(Vector2(0.5, 0.9)) and two_seats[1].is_equal_approx(Vector2(0.5, 0.1)), "two-player seating places the opponent North of local South")
	var three_seats := TablePresentationScript.normalized_seat_positions(3)
	_check(three_seats[1].x < 0.5 and three_seats[2].x > 0.5 and is_equal_approx(three_seats[1].y, three_seats[2].y), "three-player opponents occupy symmetric upper-left and upper-right seats")
	var four_seats := TablePresentationScript.normalized_seat_positions(4)
	_check(four_seats[1].x < 0.5 and is_equal_approx(four_seats[1].y, 0.5) and is_equal_approx(four_seats[2].x, 0.5) and four_seats[2].y < 0.5 and four_seats[3].x > 0.5, "four-player turn order proceeds South, West, North, East")
	var eight_seats := TablePresentationScript.normalized_seat_positions(8)
	_check(eight_seats.size() == 8 and eight_seats[1].x < 0.5 and eight_seats[1].y > 0.5 and eight_seats[7].x > 0.5 and eight_seats[7].y > 0.5, "eight-player seating fills the compass ring with next player to local left")
	var red_card: CardView = CardViewScript.new()
	red_card.setup(_card("Q", "Hearts"), false, true)
	_check(red_card.top_rank.text == "Q" and red_card.center_suit.texture != null and red_card.get_node("FaceMarks").get_child_count() == 2, "card face shows one top-left rank and one centered suit texture")
	_check(red_card.top_rank.get_theme_font_size("font_size") >= 16, "card rank text never falls below 16 px")
	red_card.set_available(false)
	_check(red_card.top_rank.visible and red_card.center_suit.visible and red_card.top_rank.text == "Q" and red_card.center_suit.texture != null and red_card.top_rank.get_theme_color("font_color") == Color("#111111"), "disabled card face retains readable black rank and center suit texture")
	var flow = MultiplayerFlowScript.new()
	flow.guest_name = "Ari"
	_check(flow.get_display_name() == "Ari", "entered display name is available to single-player and room flows")
	flow.guest_name = "   "
	_check(flow.get_display_name() == "Guest", "empty display name falls back to Guest")
	flow.free()
	var table: Control = TablePresentationScript.new()
	add_child(table)
	table.configure([{"name":"Ari", "card_count":5, "role":"King"}], 0, 0, [], [], "Lead a combination", false)
	_check("Ari" in table.name_labels[0].text and table.name_labels[0].get_theme_font_size("font_size") >= 16 and table.detail_labels[0].get_theme_font_size("font_size") >= 16 and table.status_labels[0].get_theme_font_size("font_size") >= 16, "table shows the player's name with readable text at or above 16 px")
	_check(table.role_icons[0].get_parent() == table.detail_labels[0].get_parent(), "role badge aligns with the card-count row")
	table.configure([{"name":"Bank", "card_count":5, "disconnected":true, "forfeited":true}], 0, 0, [], [], "Lead a combination", false)
	_check(table.status_labels[0].text == "LEFT", "disconnected seat shows LEFT instead of WAITING or TURN")
	table.free()
	var action_assets_loaded := true
	for asset_path in ["res://assets/gadget/bottom-play.png", "res://assets/gadget/bottom-pass.png", "res://assets/gadget/bottom-leave.png"]:
		action_assets_loaded = action_assets_loaded and load(asset_path) is Texture2D
	_check(action_assets_loaded, "all three gameplay image-button assets import as textures")
	var suit_checks := [
		{"suit":"Hearts", "symbol":"♥", "color":Color("#111111")},
		{"suit":"Diamonds", "symbol":"♦", "color":Color("#111111")},
		{"suit":"Spades", "symbol":"♠", "color":Color("#111111")},
		{"suit":"Clubs", "symbol":"♣", "color":Color("#111111")}
	]
	for item in suit_checks:
		var suit_view: CardView = CardViewScript.new()
		suit_view.setup(_card("A", item.suit), false, true)
		var expected_texture_path := "res://assets/suits/%s.png" % str(item.suit).to_lower()
		_check(suit_view.center_suit.texture != null and suit_view.center_suit.texture.resource_path == expected_texture_path and suit_view.top_rank.get_theme_color("font_color") == item.color, "%s suit icon renders and card rank uses black ink" % item.suit)
		suit_view.free()
	var combinations: Array = [
		{"name":"Single", "cards":[_card("3")]},
		{"name":"Pair", "cards":[_card("4"), _card("4", "Hearts")]},
		{"name":"Triple", "cards":[_card("5"), _card("5", "Hearts"), _card("5", "Spades")]},
		{"name":"Four of a Kind", "cards":[_card("6"), _card("6", "Hearts"), _card("6", "Spades"), _card("6", "Diamonds")]},
		{"name":"Straight", "cards":[_card("7"), _card("8"), _card("9"), _card("10"), _card("J")]}
	]
	for combination in combinations:
		var pile: Control = CardViewScript.make_pile(combination.cards, true)
		var cluster: Control = pile.get_child(0)
		var overlapped := true
		for i in range(cluster.get_child_count()):
			var view: CardView = cluster.get_child(i)
			if absf(view.rotation_degrees) < 0.1:
				overlapped = false
			if i > 0:
				var previous: CardView = cluster.get_child(i - 1)
				if view.position.x - previous.position.x >= view.size.x:
					overlapped = false
		_check(cluster.get_child_count() == combination.cards.size() and overlapped, "%s renders as a rotated overlapping center cluster" % combination.name)
		pile.free()

func _test_play_animation_pile() -> void:
	var animated_table: Control = TablePresentationScript.new()
	add_child(animated_table)
	var seats := [{"name":"Player A"}, {"name":"Player B"}]
	var pile_cards: Array = [_card("9", "Spades"), _card("10", "Diamonds")]
	animated_table.configure(seats, 0, 1, [], pile_cards, "Single", true)
	await get_tree().process_frame
	var play_groups: Array = [
		[_card("J", "Hearts")],
		[_card("4", "Hearts"), _card("4", "Clubs")],
		[_card("5", "Spades"), _card("5", "Clubs"), _card("5", "Hearts")],
		[_card("10", "Clubs"), _card("7", "Hearts"), _card("9", "Diamonds"), _card("6", "Clubs"), _card("8", "Spades")],
		[_card("Q", "Spades"), _card("Q", "Clubs"), _card("Q", "Diamonds"), _card("Q", "Hearts")],
		[_card("7", "Diamonds"), _card("3", "Diamonds"), _card("6", "Diamonds"), _card("4", "Diamonds"), _card("5", "Diamonds")],
		[_card("A", "Diamonds"), _card("K", "Spades"), _card("2", "Clubs"), _card("K", "Clubs"), _card("A", "Clubs"), _card("2", "Diamonds")]
	]
	var expected_types := ["Single", "Pair", "Triple", "Straight", "Four of a Kind", "Straight Flush", "Pair Sequence"]
	for group_index in range(play_groups.size()):
		var play_group: Array = play_groups[group_index]
		var next_pile := pile_cards.duplicate()
		next_pile.append_array(play_group)
		animated_table.configure(seats, 0, 1, [], next_pile, "Play", true, 1, play_group)
		var pile_layer: Control = animated_table.center_pile.get_child(0)
		var factor: float = animated_table.layout_scale * 1.6
		var landing: Dictionary = CardViewScript.get_play_landing_layout(play_group, true, factor)
		var targets_by_id := {}
		for target_card in pile_layer.get_children():
			targets_by_id[target_card.card.card_id()] = target_card
		var type_matches: bool = str(landing.combo_type) == expected_types[group_index]
		var existing_pile_visible := true
		for card: CardData in pile_cards:
			existing_pile_visible = existing_pile_visible and is_equal_approx(float(targets_by_id[card.card_id()].modulate.a), 1.0)
		var incoming_cards_hidden := true
		for card: CardData in play_group:
			incoming_cards_hidden = incoming_cards_hidden and is_zero_approx(float(targets_by_id[card.card_id()].modulate.a))
		var ordered_positions_match := true
		var layout_width := float(pile_layer.custom_minimum_size.x)
		var layout_height := float(pile_layer.custom_minimum_size.y)
		var card_width: float = 42.0 * factor
		var card_height: float = 64.0 * factor
		var center := Vector2((layout_width - card_width) * 0.5, (layout_height - card_height) * 0.5)
		for i in range(landing.cards.size()):
			var card: CardData = landing.cards[i]
			var target_card: Control = targets_by_id[card.card_id()]
			var expected_position: Vector2 = center + landing.offsets[i]
			ordered_positions_match = ordered_positions_match and target_card.position.is_equal_approx(expected_position)
			if i > 0:
				var previous: CardData = landing.cards[i - 1]
				ordered_positions_match = ordered_positions_match and targets_by_id[previous.card_id()].position.x < target_card.position.x
		_check(type_matches and ordered_positions_match, "%s uses sorted, distinct shared landing positions" % expected_types[group_index])
		_check(existing_pile_visible, "all earlier plays remain visible underneath the newest %d-card play" % play_group.size())
		_check(incoming_cards_hidden, "newly played targets remain hidden while their flight cards animate")
		_check(is_equal_approx(animated_table.center_pile.modulate.a, 1.0), "center pile container remains fully visible during card flight")
		while animated_table.play_animation_tween == null:
			await get_tree().process_frame
		var flight_cards_match_order: bool = animated_table.play_flight_layer.get_child_count() == landing.cards.size()
		for i in range(landing.cards.size()):
			var flight_card: CardView = animated_table.play_flight_layer.get_child(i)
			flight_cards_match_order = flight_cards_match_order and flight_card.card.card_id() == landing.cards[i].card_id()
		_check(flight_cards_match_order, "flight layer animates each card in its deterministic landing order")
		var saved_positions := {}
		for card: CardData in landing.cards:
			saved_positions[card.card_id()] = targets_by_id[card.card_id()].position
		var flight_tween: Tween = animated_table.play_animation_tween
		await flight_tween.finished
		await get_tree().process_frame
		var pile_committed: bool = animated_table.play_flight_layer.get_child_count() == 0
		for card: CardData in landing.cards:
			var target: Control = targets_by_id[card.card_id()]
			pile_committed = pile_committed and is_equal_approx(float(target.modulate.a), 1.0) and target.position.is_equal_approx(saved_positions[card.card_id()])
		_check(pile_committed, "animation finishes at the same positions as the persistent pile")
		pile_cards = next_pile
	animated_table.configure(seats, 0, 1, [], [], "Lead a combination", true)
	_check(animated_table.center_pile == null and animated_table.center_title.visible, "trick reset clears the persistent center pile")
	animated_table.free()

func _test_lobby_visual_styles() -> void:
	var flow: Control = MultiplayerFlowScript.new()
	flow.page = "lobby"
	flow.is_host = true
	flow.local_player_index = 0
	flow.room_code = "ABC123"
	flow.match_round_limit = 8
	flow.room_max_players = 4
	flow.lobby_human_count = 1
	flow.lobby_ready_count = 1
	flow.lobby_all_ready = false
	flow.room_players = [{"peer_id": 100, "player_index": 0, "name": "Host", "is_host": true, "ready": true}]
	add_child(flow)
	flow._show_lobby()
	var heading := flow.find_children("*", "Label", true, false)
	var heading_is_dark := false
	for item in heading:
		if item is Label and (item as Label).text == "Room Lobby":
			heading_is_dark = (item as Label).get_theme_color("font_color") == Color("#111111")
	_check(heading_is_dark, "lobby heading uses near-black text")
	var ready_button := flow.find_child("Action_Ready", true, false) as Button
	var ready_style := ready_button.get_theme_stylebox("normal") as StyleBoxFlat
	_check(ready_style.bg_color == Color.WHITE and ready_button.get_theme_color("font_color") == Color.BLACK, "Ready button uses white background and black text")
	var start_button := flow.find_child("Action_StartGame", true, false) as Button
	var disabled_style := start_button.get_theme_stylebox("disabled") as StyleBoxFlat
	_check(start_button.disabled and disabled_style.bg_color == Color("#777777") and start_button.get_theme_color("font_disabled_color") == Color("#f1f1ee"), "disabled Start Game remains readable on muted gray")
	start_button.disabled = false
	flow._style_lobby_controls(flow)
	var start_style := start_button.get_theme_stylebox("normal") as StyleBoxFlat
	_check(start_style.bg_color == Color("#176b3a") and start_button.get_theme_color("font_color") == Color.WHITE, "enabled Start Game uses dark green and white text")
	var copy_button := flow.find_child("CopyRoomCodeButton", true, false) as Button
	var copy_style := copy_button.get_theme_stylebox("normal") as StyleBoxFlat
	_check(copy_style.bg_color == Color("#30343a") and copy_button.text == "Copy", "Copy button stays charcoal without changing its label")
	var leave_button := flow.find_child("Action_LeaveRoom", true, false) as Button
	var leave_style := leave_button.get_theme_stylebox("normal") as StyleBoxFlat
	_check(leave_style.bg_color == Color("#791e1e") and leave_button.get_theme_color("font_color") == Color.WHITE, "Leave Room uses dark red and white text")
	var ready_icon := flow.find_child("LobbyReadyState", true, false) as TextureRect
	_check(ready_icon != null and ready_icon.texture != null and ready_icon.texture.resource_path.ends_with("check.png"), "Ready player state uses the check icon")
	flow.free()

func _test_bot_combinations() -> void:
	var rules = GameRulesScript.new()
	var bot = BotBrainScript.new()
	var hand: Array = [_card("3"), _card("3", "Hearts"), _card("4"), _card("4", "Hearts"), _card("5"), _card("6"), _card("7")]
	var lead: Array = bot.choose_play(hand, [], rules)
	_check(not lead.is_empty() and rules.classify(lead).valid and int(rules.classify(lead).high_rank) == 0, "bot leads with a legal lowest-value combination")
	_check(rules.classify(bot.choose_play([_card("7"), _card("7", "Hearts"), _card("7", "Spades")], [], rules)).type == "Triple", "bot can lead with a Triple to empty its hand")
	_check(rules.classify(bot.choose_play([_card("5", "Clubs"), _card("6", "Diamonds"), _card("7", "Hearts"), _card("8", "Spades"), _card("9", "Clubs")], [], rules)).type == "Straight", "bot can lead with a Straight to empty its hand")
	_check(rules.classify(bot.choose_play([_card("5", "Clubs"), _card("6", "Clubs"), _card("7", "Clubs"), _card("8", "Clubs"), _card("9", "Clubs")], [], rules)).type == "Straight Flush", "bot can lead with a Straight Flush to empty its hand")
	var pair_hand: Array = [_card("3"), _card("10"), _card("10", "Hearts"), _card("J"), _card("J", "Hearts"), _card("Q"), _card("Q", "Hearts")]
	var response: Array = bot.choose_play(pair_hand, [_card("9"), _card("9", "Hearts")], rules)
	_check(rules.classify(response).type == "Pair" and int(rules.classify(response).high_rank) == 7, "bot prefers the lowest same-type Pair to a lower Single")
	var triple_hand: Array = [_card("10"), _card("10", "Hearts"), _card("10", "Spades"), _card("J"), _card("J", "Hearts"), _card("J", "Spades")]
	var triple_play: Array = bot.choose_play(triple_hand, [_card("9"), _card("9", "Hearts"), _card("9", "Spades")], rules)
	_check(rules.classify(triple_play).type == "Triple" and int(rules.classify(triple_play).high_rank) == 7, "bot responds with the lowest valid Triple")
	var four_hand: Array = [_card("10"), _card("10", "Hearts"), _card("10", "Spades"), _card("10", "Diamonds"), _card("J"), _card("J", "Hearts"), _card("J", "Spades"), _card("J", "Diamonds")]
	var four_play: Array = bot.choose_play(four_hand, [_card("9"), _card("9", "Hearts"), _card("9", "Spades"), _card("9", "Diamonds")], rules)
	_check(rules.classify(four_play).type == "Four of a Kind" and int(rules.classify(four_play).high_rank) == 7, "bot responds with the lowest valid Four")
	var straight_hand: Array = [_card("7", "Clubs"), _card("8", "Diamonds"), _card("9", "Hearts"), _card("10", "Spades"), _card("J", "Clubs")]
	var straight_play: Array = bot.choose_play(straight_hand, [_card("5", "Clubs"), _card("6", "Diamonds"), _card("7", "Hearts"), _card("8", "Spades"), _card("9", "Clubs")], rules)
	_check(rules.classify(straight_play).type == "Straight" and int(rules.classify(straight_play).high_rank) == 8, "bot responds with the lowest valid five-card Straight")
	var cross_type: Array = bot.choose_play([_card("4"), _card("5"), _card("6")], [_card("Q"), _card("Q", "Hearts")], rules)
	_check(cross_type.is_empty(), "bot passes when it has no legal response in the same family")
	var no_response: Array = bot.choose_play([_card("3"), _card("4")], [_card("A")], rules)
	_check(no_response.is_empty(), "bot passes when it cannot respond")
	var parity_switch: Array = bot.choose_play([_card("3", "Clubs"), _card("4", "Diamonds"), _card("5", "Hearts"), _card("6", "Spades"), _card("7", "Clubs")], [_card("2", "Spades")], rules)
	_check(rules.classify(parity_switch).type == "Straight", "bot can switch from a Single to a five-card Straight")
	var multi_card_single: Array = bot.choose_play([_card("5", "Clubs"), _card("6", "Diamonds"), _card("7", "Hearts"), _card("8", "Spades"), _card("9", "Clubs")], [_card("3"), _card("3", "Hearts"), _card("3", "Spades")], rules)
	_check(rules.classify(multi_card_single).type == "Straight" and multi_card_single.size() == 5, "bot can respond to a Triple with a legal Straight")
	var straight_single: Array = bot.choose_play([_card("8", "Clubs"), _card("9", "Diamonds"), _card("10", "Hearts"), _card("J", "Spades"), _card("Q", "Clubs")], [_card("4", "Clubs"), _card("5", "Diamonds"), _card("6", "Hearts"), _card("7", "Spades"), _card("8", "Clubs", 1)], rules)
	_check(rules.classify(straight_single).type == "Straight" and straight_single.size() == 5, "bot can answer a Straight with a stronger five-card Straight")
	var suit_response_hand: Array = [_card("8", "Clubs"), _card("8", "Hearts"), _card("9", "Clubs")]
	var suit_response: Array = bot.choose_play(suit_response_hand, [_card("8", "Diamonds")], rules)
	_check(suit_response.size() == 1 and suit_response[0].rank == "8" and suit_response[0].suit == "Hearts", "bot uses suit strength and chooses 8 Hearts over 9 Clubs")
	var pair_suit_hand: Array = [_card("8", "Spades", 1), _card("8", "Hearts"), _card("9", "Clubs"), _card("9", "Diamonds")]
	var pair_suit_response: Array = bot.choose_play(pair_suit_hand, [_card("8", "Spades"), _card("8", "Diamonds")], rules)
	_check(rules.classify(pair_suit_response).type == "Pair" and int(rules.classify(pair_suit_response).high_rank) == 5, "bot chooses the lowest rank pair whose suit sequence beats the center")

func _test_room_round(count: int) -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	var peer := 600 + count
	service.handle_message(peer, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":count}})
	var code := ""
	for message in messages_by_peer.get(peer, []):
		if message.type == Protocol.ROOM_CREATED:
			code = str(message.payload.room_code)
	_ready_peers(service, [peer])
	service.handle_message(peer, {"type":Protocol.START_GAME, "payload":{"fill_bots":true}})
	var room: Dictionary = service.rooms[code]
	for member in room.members:
		member.is_bot = true
		member.peer_id = 0
	while room.phase in ["rps_tiebreak", "rps_result"]:
		if room.phase == "rps_result":
			_check(room.game_state.current_player == int(room.rps_winner) if int(room.rps_winner) >= 0 else room.game_state.current_player >= 0, "RPS result holds the authoritative starter until continue")
			service.handle_message(peer, {"type":Protocol.CONTINUE_RPS, "payload":{}})
		else:
			for player_index in room.rps_players:
				var choice_key := str(player_index)
				if not room.rps_choices.has(choice_key):
					room.rps_choices[choice_key] = 0
			service._resolve_rps(room)
	var guard := 0
	while room.phase == "playing" and guard < 10000:
		service.tick(0.5)
		guard += 1
	_check(room.phase == "results" and room.game_state.finishing_order.size() == count, "%d-player bot game completes with finishing order" % count)
	_check(str(room.roles_by_player[room.game_state.finishing_order[0]]) == "King" and str(room.roles_by_player[room.game_state.finishing_order[count - 1]]) == "Slave 1", "%d-player round assigns King and Slave 1" % count)
	var expected_next_starter: int = room.game_state.finishing_order[0]
	if count >= 7:
		var slaves := {}
		for role in room.roles_by_player.values():
			if str(role).begins_with("Slave"):
				slaves[str(role)] = true
		_check(slaves.size() == 3, "%d-player results include all three Slave roles" % count)
		service.handle_message(peer, {"type":Protocol.START_NEXT_ROUND, "payload":{}})
		_check(room.phase == "playing" and room.round_number == 2 and room.exchange.is_complete(), "%d-player room starts next round and completes exchange" % count)
		var amounts := {}
		for transfer in room.exchange.completed_transfers:
			amounts[str(transfer.amount)] = true
		_check(amounts.has("3") and amounts.has("2") and amounts.has("1"), "%d-player second round applies 3/2/1 exchanges" % count)
	else:
		service.handle_message(peer, {"type":Protocol.START_NEXT_ROUND, "payload":{}})
		_check(room.phase == "playing" and room.round_number == 2, "six-player room starts another round")
	_check(room.game_state.current_player == expected_next_starter, "%d-player next round starts with the previous round winner" % count)

func _test_server_multi_card_validation() -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	service.handle_message(501, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":2}})
	var code := ""
	for message in messages_by_peer.get(501, []):
		if message.type == Protocol.ROOM_CREATED:
			code = str(message.payload.room_code)
	service.handle_message(502, {"type":Protocol.JOIN_ROOM, "payload":{"name":"Friend", "room_code":code}})
	_ready_peers(service, [501, 502])
	service.handle_message(501, {"type":Protocol.START_GAME, "payload":{"fill_bots":false}})
	var room: Dictionary = service.rooms[code]
	_check(room.members.size() == 2 and room.phase == "playing", "host creates room, second player joins, and host starts the game")
	var game: GameState = room.game_state
	game.current_player = 0
	game.turns.start_at(0, 2)
	game.players[0].hand = [_card("9"), _card("9", "Hearts"), _card("J"), _card("J", "Hearts"), _card("Q"), _card("Q", "Hearts")]
	game.players[1].hand = [_card("4"), _card("4", "Hearts"), _card("4", "Spades"), _card("10"), _card("10", "Hearts"), _card("7", "Diamonds")]
	service.handle_message(501, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":_ids([game.players[0].hand[0], game.players[0].hand[1]])}})
	_check(game.players[0].hand.size() == 4 and game.current_cards.size() == 2, "server accepts an owned Pair lead")
	service.handle_message(502, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":_ids([_card("4"), _card("4", "Hearts"), _card("4", "Spades")])}})
	_check(game.current_player == 1 and game.players[1].hand.size() == 6 and game.current_combination.type == "Pair", "server rejects a cross-type Triple against the active Pair")
	service.handle_message(502, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":_ids([_card("10"), _card("10", "Hearts")])}})
	_check(game.current_player == 0 and game.players[1].hand.size() == 4 and game.current_combination.type == "Pair", "server accepts a higher same-type Pair")
	service.handle_message(501, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":_ids([_card("J"), _card("J", "Hearts")])}})
	_check(game.current_player == 1 and game.current_combination.type == "Pair", "server accepts the next higher same-type Pair")
	var before: int = game.players[1].hand.size()
	service.handle_message(502, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":_ids([_card("4"), _card("4", "Hearts"), _card("4", "Spades")])}})
	_check(game.players[1].hand.size() == before and game.current_player == 1 and game.current_combination.type == "Pair", "server rejects a cross-type Triple without mutating state")
	service.handle_message(502, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":_ids([_card("4"), _card("7", "Diamonds")])}})
	_check(game.players[1].hand.size() == before, "server rejects an invalid mixed-rank submission")
	service.handle_message(502, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":_ids([_card("4"), _card("4")])}})
	_check(game.players[1].hand.size() == before, "server rejects duplicate card IDs without state mutation")
	service.handle_message(502, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":"malformed"}})
	_check(game.players[1].hand.size() == before, "server rejects malformed card list without state mutation")

func _test_server_suit_validation() -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	service.handle_message(881, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":2}})
	var code := ""
	for message in messages_by_peer.get(881, []):
		if message.type == Protocol.ROOM_CREATED:
			code = str(message.payload.room_code)
	service.handle_message(882, {"type":Protocol.JOIN_ROOM, "payload":{"name":"Friend", "room_code":code}})
	_ready_peers(service, [881, 882])
	service.handle_message(881, {"type":Protocol.START_GAME, "payload":{"fill_bots":false}})
	var room: Dictionary = service.rooms[code]
	var game: GameState = room.game_state
	game.players[0].hand = [_card("3", "Clubs"), _card("4", "Clubs")]
	game.players[1].hand = [_card("3", "Clubs", 1), _card("3", "Diamonds"), _card("4", "Clubs")]
	game.current_player = 0
	game.turns.start_at(0, 2)
	service.handle_message(881, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":[_card("3", "Clubs").card_id()]}})
	var before_size: int = game.players[1].hand.size()
	service.handle_message(882, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":[_card("3", "Clubs", 1).card_id()]}})
	_check(game.current_player == 1 and game.players[1].hand.size() == before_size and game.current_cards[0].suit == "Clubs", "server rejects an equal-strength duplicate card from the other deck without changing state")
	service.handle_message(882, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":[_card("3", "Diamonds").card_id()]}})
	_check(game.players[1].hand.size() == before_size - 1 and game.current_cards[0].suit == "Diamonds", "server accepts a same-rank higher-suit Single")

func _test_server_parity_validation() -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	service.handle_message(883, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":2}})
	var code := ""
	for message in messages_by_peer.get(883, []):
		if message.type == Protocol.ROOM_CREATED:
			code = str(message.payload.room_code)
	service.handle_message(884, {"type":Protocol.JOIN_ROOM, "payload":{"name":"Friend", "room_code":code}})
	_ready_peers(service, [883, 884])
	service.handle_message(883, {"type":Protocol.START_GAME, "payload":{"fill_bots":false}})
	var room: Dictionary = service.rooms[code]
	var game: GameState = room.game_state
	game.players[1].hand = [_card("7", "Spades"), _card("10")]
	game.current_cards = [_card("4", "Clubs"), _card("5", "Diamonds"), _card("6", "Hearts"), _card("7", "Spades"), _card("8", "Clubs")]
	game.current_combination = game.rules.classify(game.current_cards)
	game.current_player = 1
	game.turns.start_at(1, 2)
	var before_size: int = game.players[1].hand.size()
	service.handle_message(884, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":[_card("7", "Spades").card_id()]}})
	_check(game.players[1].hand.size() == before_size and str(game.current_combination.get("type", "")) == "Straight" and game.current_cards.size() == 5, "server rejects a malicious Single against an active Straight without mutating state")

func _test_server_cross_type_combo() -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	service.handle_message(887, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":2}})
	var code := ""
	for message in messages_by_peer.get(887, []):
		if message.type == Protocol.ROOM_CREATED:
			code = str(message.payload.room_code)
	service.handle_message(888, {"type":Protocol.JOIN_ROOM, "payload":{"name":"Friend", "room_code":code}})
	_ready_peers(service, [887, 888])
	service.handle_message(887, {"type":Protocol.START_GAME, "payload":{"fill_bots":false}})
	var room: Dictionary = service.rooms[code]
	var game: GameState = room.game_state
	var flush: Array = [_card("5", "Clubs"), _card("6", "Clubs"), _card("7", "Clubs"), _card("8", "Clubs"), _card("9", "Clubs")]
	game.players[1].hand = flush + [_card("2", "Spades")]
	game.current_cards = [_card("10", "Clubs"), _card("J", "Diamonds"), _card("Q", "Hearts"), _card("K", "Spades"), _card("A", "Clubs")]
	game.current_combination = game.rules.classify(game.current_cards)
	game.current_player = 1
	game.turns.start_at(1, 2)
	service.handle_message(888, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":_ids(flush)}})
	_check(game.players[1].hand.size() == 1 and game.current_combination.type == "Straight Flush", "server accepts a legal Straight Flush response to an ordinary Straight")

func _test_server_single_against_multi_card_server_validation() -> void:
	var service = RoomServiceScript.new()
	service.send_to_peer.connect(_capture_message)
	service.handle_message(885, {"type":Protocol.CREATE_ROOM, "payload":{"name":"Host", "max_players":2}})
	var code := ""
	for message in messages_by_peer.get(885, []):
		if message.type == Protocol.ROOM_CREATED:
			code = str(message.payload.room_code)
	service.handle_message(886, {"type":Protocol.JOIN_ROOM, "payload":{"name":"Friend", "room_code":code}})
	_ready_peers(service, [885, 886])
	service.handle_message(885, {"type":Protocol.START_GAME, "payload":{"fill_bots":false}})
	var room: Dictionary = service.rooms[code]
	var game: GameState = room.game_state
	game.players[1].hand = [_card("8"), _card("10")]
	game.current_cards = [_card("7"), _card("7", "Hearts"), _card("7", "Spades")]
	game.current_combination = game.rules.classify(game.current_cards)
	game.current_player = 1
	game.turns.start_at(1, 2)
	var before_size: int = game.players[1].hand.size()
	service.handle_message(886, {"type":Protocol.PLAY_CARDS, "payload":{"card_ids":[_card("8").card_id()]}})
	_check(game.players[1].hand.size() == before_size and str(game.current_combination.get("type", "")) == "Triple" and game.current_cards.size() == 3, "server rejects a malicious Single against an active Triple without mutating state")

func _capture_message(peer_id: int, message: Dictionary) -> void:
	if not messages_by_peer.has(peer_id):
		messages_by_peer[peer_id] = []
	messages_by_peer[peer_id].append(message)
