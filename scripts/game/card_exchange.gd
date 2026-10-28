class_name CardExchangeSystem
extends RefCounted

const HandSorterScript = preload("res://scripts/cards/hand_sorter.gd")

const EXCHANGE_PAIRS_7_PLUS := [
	{"upper_role": "King", "slave_role": "Slave 1", "amount": 3},
	{"upper_role": "Queen", "slave_role": "Slave 2", "amount": 2},
	{"upper_role": "Seven", "slave_role": "Slave 3", "amount": 1}
]
const EXCHANGE_PAIRS_4_TO_6 := [
	{"upper_role": "King", "slave_role": "Slave 1", "amount": 2},
	{"upper_role": "Queen", "slave_role": "Slave 2", "amount": 1}
]
const EXCHANGE_PAIRS_2_TO_3 := [
	{"upper_role": "King", "slave_role": "Slave 1", "amount": 2}
]
const EXCHANGE_PAIRS_3_PLAYERS := [
	{"upper_role": "King", "slave_role": "Slave 1", "amount": 2},
	{"upper_role": "Queen", "slave_role": "Slave 1", "amount": 1}
]

var pending_returns: Array[Dictionary] = []
var completed_transfers: Array[Dictionary] = []
var exchanges: Array[Dictionary] = []
var roles_by_player: Dictionary = {}
var ready_by_player: Dictionary = {}
var bot_by_player: Array[bool] = []
var hands_by_player: Array = []

func begin(players: Array[Dictionary], role_map: Dictionary, bot_flags: Array[bool]) -> Dictionary:
	pending_returns.clear()
	completed_transfers.clear()
	exchanges.clear()
	roles_by_player = role_map.duplicate(true)
	bot_by_player = bot_flags.duplicate()
	hands_by_player = []
	ready_by_player.clear()
	for i in range(players.size()):
		hands_by_player.append(players[i].hand)
		var role := str(role_map.get(i, role_map.get(str(i), "")))
		if role in ["King", "Queen", "Seven", "Slave 1", "Slave 2", "Slave 3"]:
			ready_by_player[i] = false

	var player_by_role: Dictionary = {}
	for player_index in role_map:
		player_by_role[str(role_map[player_index])] = int(player_index)

	var exchange_pairs: Array = EXCHANGE_PAIRS_2_TO_3
	if players.size() >= 7:
		exchange_pairs = EXCHANGE_PAIRS_7_PLUS
	elif players.size() >= 4:
		exchange_pairs = EXCHANGE_PAIRS_4_TO_6
	elif players.size() == 3:
		exchange_pairs = EXCHANGE_PAIRS_3_PLAYERS
	var slave_cards_reserved: Dictionary = {}
	for pair in exchange_pairs:
		if not player_by_role.has(pair.upper_role) or not player_by_role.has(pair.slave_role):
			continue
		var upper_index: int = player_by_role[pair.upper_role]
		var slave_index: int = player_by_role[pair.slave_role]
		var amount: int = int(pair.amount)
		var slave_hand: Array = players[slave_index].hand
		var upper_hand: Array = players[upper_index].hand
		HandSorterScript.sort_hand(slave_hand)
		HandSorterScript.sort_hand(upper_hand)
		var reserved_count := int(slave_cards_reserved.get(slave_index, 0))
		if slave_hand.size() < reserved_count + amount or upper_hand.size() < amount:
			return {"ok": false, "error": "Not enough cards for %s / %s exchange." % [pair.upper_role, pair.slave_role]}
		var forced_end := slave_hand.size() - reserved_count
		var forced_start := forced_end - amount
		var forced_cards: Array = slave_hand.slice(forced_start, forced_end)
		slave_cards_reserved[slave_index] = reserved_count + amount
		var bot_upper_cards: Array = upper_hand.slice(0, amount)
		var transfer := {
			"upper_role": pair.upper_role,
			"slave_role": pair.slave_role,
			"upper_player": upper_index,
			"slave_player": slave_index,
			"amount": amount,
			"slave_card_ids": _card_ids(forced_cards),
			"upper_return_ids": _card_ids(bot_upper_cards) if bot_flags[upper_index] else []
		}
		exchanges.append(transfer)
		var upper_ready := bool(bot_flags[upper_index])
		# Slaves return their mandatory highest cards automatically and wait for the upper role.
		var slave_ready := true
		ready_by_player[upper_index] = upper_ready
		ready_by_player[slave_index] = slave_ready
		if not upper_ready:
			pending_returns.append({
				"player_index": upper_index,
				"role": pair.upper_role,
				"kind": "upper",
				"amount": amount,
				"mandatory_ids": []
			})

	if _all_ready():
		_apply_exchanges(players)
	return {"ok": true, "pending_count": pending_returns.size(), "ready": readiness_by_role()}

func select_return_cards(player_index: int, card_ids: Array, players: Array[Dictionary]) -> Dictionary:
	var pending_index := -1
	for i in range(pending_returns.size()):
		if int(pending_returns[i].player_index) == player_index:
			pending_index = i
			break
	if pending_index < 0:
		return {"ok": false, "error": "This player has no pending trade action."}

	var action: Dictionary = pending_returns[pending_index]
	var amount := int(action.amount)
	if card_ids.size() != amount:
		return {"ok": false, "error": "Select exactly %d cards." % amount}
	var seen := {}
	var normalized_ids: Array[String] = []
	for value in card_ids:
		var id := str(value)
		if seen.has(id):
			return {"ok": false, "error": "A card was selected more than once."}
		seen[id] = true
		normalized_ids.append(id)

	if str(action.kind) == "slave":
		if not _same_ids(normalized_ids, action.mandatory_ids):
			return {"ok": false, "error": "%s must give the highest %d cards." % [str(action.role), amount]}
	else:
		var owned := {}
		for card in players[player_index].hand:
			owned[card.card_id()] = true
		for id in normalized_ids:
			if not owned.has(id):
				return {"ok": false, "error": "A selected card is not in this player's hand."}
		for exchange in exchanges:
			if int(exchange.upper_player) == player_index:
				exchange.upper_return_ids = normalized_ids.duplicate()
				break

	ready_by_player[player_index] = true
	pending_returns.remove_at(pending_index)
	if _all_ready():
		_apply_exchanges(players)
	return {"ok": true, "remaining": pending_returns.size(), "ready": readiness_by_role(), "complete": is_complete()}

func _apply_exchanges(players: Array[Dictionary]) -> void:
	if completed_transfers.size() == exchanges.size() and is_complete():
		return
	for exchange in exchanges:
		var upper_index := int(exchange.upper_player)
		var slave_index := int(exchange.slave_player)
		var upper_hand: Array = players[upper_index].hand
		var slave_hand: Array = players[slave_index].hand
		var outgoing_upper: Array = []
		var outgoing_slave: Array = []
		for id in exchange.upper_return_ids:
			var card: Variant = _find_card(upper_hand, str(id))
			if card == null:
				return
			outgoing_upper.append(card)
		for id in exchange.slave_card_ids:
			var card: Variant = _find_card(slave_hand, str(id))
			if card == null:
				return
			outgoing_slave.append(card)
		if outgoing_upper.size() != int(exchange.amount) or outgoing_slave.size() != int(exchange.amount):
			return
		for card in outgoing_upper:
			upper_hand.erase(card)
		for card in outgoing_slave:
			slave_hand.erase(card)
		upper_hand.append_array(outgoing_slave)
		slave_hand.append_array(outgoing_upper)
		HandSorterScript.sort_hand(upper_hand)
		HandSorterScript.sort_hand(slave_hand)
		players[upper_index].hand = upper_hand
		players[slave_index].hand = slave_hand
		completed_transfers.append({
			"upper_player": upper_index,
			"slave_player": slave_index,
			"amount": int(exchange.amount),
			"given_card_ids": exchange.slave_card_ids.duplicate(),
			"returned_card_ids": exchange.upper_return_ids.duplicate()
		})

func _all_ready() -> bool:
	for player_index in ready_by_player:
		if not bool(ready_by_player[player_index]):
			return false
	return true

func is_complete() -> bool:
	return _all_ready() and completed_transfers.size() == exchanges.size()

func pending_amount_for(player_index: int) -> int:
	for action in pending_returns:
		if int(action.player_index) == player_index:
			return int(action.amount)
	return 0

func role_for_player(player_index: int) -> String:
	var value = roles_by_player.get(player_index, roles_by_player.get(str(player_index), ""))
	return str(value)

func mandatory_ids_for(player_index: int) -> Array[String]:
	for action in pending_returns:
		if int(action.player_index) == player_index and str(action.kind) == "slave":
			var result: Array[String] = []
			for id in action.mandatory_ids:
				result.append(str(id))
			return result
	var ids: Array[String] = []
	for exchange in exchanges:
		if int(exchange.slave_player) == player_index:
			for id in exchange.slave_card_ids:
				ids.append(str(id))
	return ids

func is_slave_participant(player_index: int) -> bool:
	return role_for_player(player_index).begins_with("Slave ")

func has_pending_action(player_index: int) -> bool:
	return pending_amount_for(player_index) > 0

func is_participant(player_index: int) -> bool:
	return role_for_player(player_index) in ["King", "Queen", "Seven", "Slave 1", "Slave 2", "Slave 3"]

func readiness_by_role() -> Dictionary:
	var statuses := {}
	for player_index in ready_by_player:
		var role := role_for_player(int(player_index))
		statuses[role] = "Ready" if bool(ready_by_player[player_index]) else "Selecting"
	return statuses

func transfers_for_player(player_index: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for transfer in completed_transfers:
		if int(transfer.upper_player) == player_index or int(transfer.slave_player) == player_index:
			result.append(transfer.duplicate(true))
	return result

func _find_card(hand: Array, id: String):
	for card in hand:
		if card.card_id() == id:
			return card
	return null

func _same_ids(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var a_set := {}
	for value in a:
		a_set[str(value)] = true
	for value in b:
		if not a_set.has(str(value)):
			return false
	return true

static func _card_ids(cards: Array) -> Array[String]:
	var ids: Array[String] = []
	for card in cards:
		ids.append(card.card_id())
	return ids