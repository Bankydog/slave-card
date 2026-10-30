class_name GameState
extends RefCounted

signal changed

const HandSorterScript = preload("res://scripts/cards/hand_sorter.gd")
const GameRulesScript = preload("res://scripts/game/game_rules.gd")
const TurnManagerScript = preload("res://scripts/game/turn_manager.gd")
const DeckFactoryScript = preload("res://scripts/cards/deck_factory.gd")
const CardDataScript = preload("res://scripts/cards/card_data.gd")

var players: Array[Dictionary] = []
var current_player := 0
var current_cards: Array = []
var trick_pile_cards: Array = []
var current_combination: Dictionary = {}
# Kept for compatibility with single-card displays and older callers.
var current_card
var last_player := -1
var passed: Array[bool] = []
var finishing_order: Array[int] = []
var forfeited_order: Array[int] = []
var rules = GameRulesScript.new()
var turns = TurnManagerScript.new()
var rng := RandomNumberGenerator.new()

func start(player_count: int, seed_value: int = 0, starting_player: int = -1) -> void:
	if seed_value == 0:
		rng.randomize()
	else:
		rng.seed = seed_value
	var deck := DeckFactoryScript.create_deck(player_count, rng)
	var hands := DeckFactoryScript.deal(deck, player_count)
	players.clear()
	finishing_order.clear()
	forfeited_order.clear()
	for i in range(player_count):
		HandSorterScript.sort_hand(hands[i])
		players.append({"name": "You" if i == 0 else "Player %d" % (i + 1), "hand": hands[i], "finished": false, "is_human": i == 0})
	passed.resize(player_count)
	passed.fill(false)
	current_cards.clear()
	trick_pile_cards.clear()
	current_combination.clear()
	current_card = null
	last_player = -1
	var first_player := starting_player if starting_player >= 0 and starting_player < player_count else first_player_by_three_clubs()
	turns.start_at(first_player, player_count)
	current_player = turns.current_player
	changed.emit()

func first_player_by_three_clubs() -> int:
	var holders := three_clubs_holders()
	return int(holders[0]) if holders.size() == 1 else rng.randi_range(0, players.size() - 1)

func three_clubs_holders() -> Array[int]:
	var result: Array[int] = []
	for player_index in range(players.size()):
		for card: CardData in players[player_index].hand:
			if card.rank == "3" and card.suit == "Clubs":
				result.append(player_index)
				break
	return result

func active_eligible_count() -> int:
	var count := 0
	for i in range(players.size()):
		if not players[i].finished and not passed[i]:
			count += 1
	return count

func play_card(player_index: int, card) -> bool:
	return play_cards(player_index, [card])

func play_cards(player_index: int, requested_cards: Array) -> bool:
	if player_index < 0 or player_index >= players.size():
		return false
	if player_index != current_player or players[player_index].finished or passed[player_index]:
		return false
	var hand: Array = players[player_index].hand
	var chosen: Array = []
	var requested_ids := {}
	for requested in requested_cards:
		if not requested is CardDataScript:
			return false
		var card_id: String = requested.card_id()
		if requested_ids.has(card_id):
			return false
		requested_ids[card_id] = true
		var owned_card
		for item in hand:
			if item.card_id() == card_id:
				owned_card = item
				break
		if owned_card == null:
			return false
		chosen.append(owned_card)
	if chosen.size() != requested_cards.size() or not rules.can_beat(chosen, current_cards):
		return false

	for card in chosen:
		hand.erase(card)
	players[player_index].hand = hand
	HandSorterScript.sort_hand(players[player_index].hand)
	current_cards = chosen.duplicate()
	trick_pile_cards.append_array(chosen)
	current_combination = rules.classify(current_cards)
	current_card = current_cards[0] if current_cards.size() == 1 else null
	last_player = player_index
	if hand.is_empty():
		players[player_index].finished = true
		finishing_order.append(player_index)
		if _active_player_count() <= 1:
			for i in range(players.size()):
				if not players[i].finished:
					players[i].finished = true
					finishing_order.append(i)
			finishing_order.append_array(forfeited_order)
			changed.emit()
			return true
	advance_turn()
	changed.emit()
	return true

func forfeit_player(player_index: int) -> bool:
	if player_index < 0 or player_index >= players.size() or players[player_index].finished:
		return false
	players[player_index].finished = true
	passed[player_index] = true
	forfeited_order.append(player_index)
	if _active_player_count() <= 1:
		for i in range(players.size()):
			if not players[i].finished:
				players[i].finished = true
				finishing_order.append(i)
		finishing_order.append_array(forfeited_order)
	else:
		if current_player == player_index:
			advance_turn()
	changed.emit()
	return true

func _active_player_count() -> int:
	var count := 0
	for player in players:
		if not bool(player.get("finished", false)):
			count += 1
	return count

func pass_turn(player_index: int) -> bool:
	if player_index < 0 or player_index >= players.size():
		return false
	if player_index != current_player or players[player_index].finished or passed[player_index] or not rules.can_pass():
		return false
	passed[player_index] = true
	advance_turn()
	changed.emit()
	return true

func advance_turn() -> void:
	if current_cards.is_empty():
		var next_leader := _next_unpassed_player(current_player)
		if next_leader < 0:
			passed.fill(false)
			next_leader = turns.next_active(players, current_player)
		if next_leader >= 0:
			current_player = next_leader
		return

	var next_responder := _next_unpassed_player(current_player)
	if next_responder < 0 or next_responder == last_player:
		reset_trick()
		return
	current_player = next_responder

func _next_unpassed_player(after_index: int) -> int:
	if players.is_empty():
		return -1
	for step in range(1, players.size() + 1):
		var candidate := posmod(after_index + step, players.size())
		if not players[candidate].finished and not passed[candidate]:
			return candidate
	return -1

func reset_trick() -> void:
	var previous_leader := last_player
	current_cards.clear()
	trick_pile_cards.clear()
	current_combination.clear()
	current_card = null
	passed.fill(false)
	last_player = -1
	if previous_leader >= 0 and not players[previous_leader].finished:
		current_player = previous_leader
	else:
		var after_index := previous_leader if previous_leader >= 0 else current_player
		var next := turns.next_active(players, after_index)
		if next >= 0:
			current_player = next
