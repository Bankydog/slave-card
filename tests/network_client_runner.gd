extends Node

const Protocol = preload("res://scripts/network/network_protocol.gd")
const CardDataScript = preload("res://scripts/cards/card_data.gd")
const GameRulesScript = preload("res://scripts/game/game_rules.gd")

@export var room_code := "Y5PM7S"
@onready var endpoint = $MultiplayerFlow/NetworkEndpoint
var mode := "join"
var server_url := "ws://127.0.0.1:9080"
var host_room_code := ""
var start_requested := false
var received_lobby := false
var ready_sent := false
var start_sent := false
var got_start := false
var got_deal := false
var got_turn := false
var local_player_index := -1
var latest_hand: Array = []
var latest_turn: Dictionary = {}
var deal_generation := 0
var acted_deal_generation := 0
var actions_seen := 0
var awaiting_turn := false
var exit_reported := false
var state_history: Array[String] = []
var sent_pass := false

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
	if mode.begins_with("host"):
		endpoint.send_intent(Protocol.CREATE_ROOM, {"name":"Proxy Host", "max_players":3 if mode == "host_bots" else 2})
	else:
		endpoint.send_intent(Protocol.JOIN_ROOM, {"name":"Proxy Guest", "room_code":room_code})

func _on_message(message: Dictionary) -> void:
	if message.type == Protocol.ROOM_CREATED and mode.begins_with("host"):
		host_room_code = str(message.payload.get("room_code", ""))
		print("PROXY TEST ROOM CODE: ", host_room_code)
	elif message.type == Protocol.LOBBY_STATE:
		var payload: Dictionary = message.payload
		if mode == "join" and int(payload.players.size()) >= 2 and int(payload.your_player_index) == 1:
			received_lobby = true
		if int(payload.players.size()) >= 2 and not ready_sent:
			ready_sent = true
			endpoint.send_intent(Protocol.SET_READY, {"ready":true})
		if mode.begins_with("host") and bool(payload.get("all_ready", false)) and not start_sent:
			start_sent = true
			start_requested = true
			_start_game()
	elif message.type == Protocol.START_GAME:
		got_start = true
	elif message.type == Protocol.DEAL:
		got_deal = true
		local_player_index = int(message.payload.get("player_index", local_player_index))
		latest_hand = message.payload.get("hand", []).duplicate(true)
		deal_generation += 1
		_maybe_act()
	elif message.type == Protocol.TURN_CHANGED:
		got_turn = true
		latest_turn = message.payload.duplicate(true)
		awaiting_turn = false
		actions_seen += 1
		if not _turn_snapshot_valid():
			push_error("Public turn snapshot was incomplete or invalid for " + mode)
			get_tree().quit(1)
			return
		state_history.append(_turn_signature())
		_maybe_act()
	elif message.type == Protocol.ACTION_REJECTED:
		push_error("Proxy network action rejected: " + str(message.payload.get("reason", "unknown")))
		get_tree().quit(1)

func _start_game() -> void:
	endpoint.send_intent(Protocol.START_GAME, {"fill_bots":mode == "host_bots"})

func _turn_snapshot_valid() -> bool:
	return int(latest_turn.get("round_number", 0)) > 0 and int(latest_turn.get("players", []).size()) >= 2 and int(latest_turn.get("current_player", -1)) >= 0 and latest_turn.has("current_cards") and latest_turn.has("combination") and latest_turn.has("last_player") and latest_turn.has("players")

func _maybe_act() -> void:
	if not got_start or not got_deal or not got_turn or latest_turn.is_empty() or awaiting_turn:
		return
	if actions_seen >= 6:
		if exit_reported:
			return
		exit_reported = true
		print("NETWORK TWO-CLIENT SYNC PASS: ", mode, " pass_test=", sent_pass, " players=", latest_turn.players.size(), " snapshots=", JSON.stringify(state_history))
		endpoint.send_intent(Protocol.LEAVE_ROOM)
		get_tree().create_timer(0.25).timeout.connect(func() -> void: get_tree().quit(0))
		return
	if int(latest_turn.get("current_player", -1)) != local_player_index or acted_deal_generation == deal_generation:
		return
	acted_deal_generation = deal_generation
	awaiting_turn = true
	var hand: Array[CardData] = []
	for item in latest_hand:
		hand.append(CardDataScript.from_dict(item))
	var current_cards: Array[CardData] = []
	for item in latest_turn.get("current_cards", []):
		current_cards.append(CardDataScript.from_dict(item))
	if actions_seen == 2 and not current_cards.is_empty():
		sent_pass = true
		endpoint.send_intent(Protocol.PASS, {})
		return
	var rules = GameRulesScript.new()
	var legal_card: CardData
	for card in hand:
		if rules.can_beat([card], current_cards):
			legal_card = card
			break
	if legal_card == null:
		endpoint.send_intent(Protocol.PASS, {})
	else:
		endpoint.send_intent(Protocol.PLAY_CARDS, {"card_ids":[legal_card.card_id()]})

func _turn_signature() -> String:
	var center: Array[String] = []
	for card in latest_turn.get("current_cards", []):
		center.append(str(card.get("id", "")))
	var counts: Array[String] = []
	var passed: Array[String] = []
	for player in latest_turn.get("players", []):
		counts.append(str(player.get("card_count", -1)))
		passed.append("1" if bool(player.get("passed", false)) else "0")
	return "%s|%s|%s|%s|%s|%s" % [str(latest_turn.get("round_number", 0)), str(latest_turn.get("current_player", -1)), str(latest_turn.get("last_player", -1)), ",".join(center), str(latest_turn.get("combination", {}).get("type", "")), ",".join(counts) + ";" + ",".join(passed)]

func _on_timeout() -> void:
	if mode == "join" and not received_lobby:
		push_error("Network client timed out waiting for lobby state.")
	elif mode.begins_with("host") and not start_requested:
		push_error("Network test host timed out waiting for the guest to join.")
	elif mode.begins_with("host"):
		push_error("Network test host timed out waiting for the game to start.")
	get_tree().quit(1)
