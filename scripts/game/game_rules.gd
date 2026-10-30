class_name GameRules
extends RefCounted

const CardDataScript = preload("res://scripts/cards/card_data.gd")

const RANKS := ["3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A", "2"]
const SUIT_ORDER := ["Clubs", "Diamonds", "Hearts", "Spades"]
const MIN_STRAIGHT_LENGTH := 3
const MAX_STRAIGHT_LENGTH := 5
const TYPE_SINGLE := "Single"
const TYPE_PAIR := "Pair"
const TYPE_TRIPLE := "Triple"
const TYPE_FOUR_OF_A_KIND := "Four of a Kind"
const TYPE_STRAIGHT := "Straight"
const TYPE_STRAIGHT_FLUSH := "Straight Flush"

# Two is the natural high endpoint in RANKS. Toggle this independently if a
# later house-rule set should exclude it from straight sequences.
var straight_allow_two := true

func classify(cards: Array) -> Dictionary:
	if cards.is_empty():
		return _invalid("A play must contain at least one card.")
	var seen_ids := {}
	var rank_counts := {}
	var rank_values: Array[int] = []
	for card in cards:
		if not card is CardDataScript:
			return _invalid("The play contains an invalid card.")
		var rank: int = card.strength()
		if rank < 0:
			return _invalid("The play contains an unknown rank.")
		var card_id: String = card.card_id()
		if seen_ids.has(card_id):
			return _invalid("The same card was submitted more than once.")
		seen_ids[card_id] = true
		rank_counts[rank] = int(rank_counts.get(rank, 0)) + 1
		if not rank_values.has(rank):
			rank_values.append(rank)

	var card_count := cards.size()
	if card_count == 1:
		return _valid(TYPE_SINGLE, card_count, rank_values[0])
	if card_count in [2, 3, 4] and rank_counts.size() == 1:
		var group_type := TYPE_PAIR if card_count == 2 else TYPE_TRIPLE if card_count == 3 else TYPE_FOUR_OF_A_KIND
		return _valid(group_type, card_count, rank_values[0])
	if card_count < MIN_STRAIGHT_LENGTH or card_count > MAX_STRAIGHT_LENGTH:
		return _invalid("A straight must contain three to five cards.")
	if rank_values.size() != card_count:
		return _invalid("A straight cannot repeat a rank.")
	if not straight_allow_two and rank_values.has(RANKS.size() - 1):
		return _invalid("Two is not enabled inside straights.")
	rank_values.sort()
	for i in range(1, rank_values.size()):
		if rank_values[i] != rank_values[i - 1] + 1:
			return _invalid("Straight ranks must be consecutive.")
	var first_suit: String = cards[0].suit
	var is_flush := true
	for card in cards:
		if card.suit != first_suit:
			is_flush = false
			break
	return _valid(TYPE_STRAIGHT_FLUSH if is_flush else TYPE_STRAIGHT, card_count, rank_values.back())

func can_beat(cards: Array, current_cards: Array) -> bool:
	var play := classify(cards)
	if not bool(play.valid):
		return false
	if current_cards.is_empty():
		return true
	var current := classify(current_cards)
	if not bool(current.valid):
		return false
	if _family_for_type(str(play.type)) != _family_for_type(str(current.type)):
		return false
	return compare_combinations(cards, current_cards) > 0

func compare_card_strength(card_a, card_b) -> int:
	if card_a == null or card_b == null:
		return 0
	var rank_difference: int = card_a.strength() - card_b.strength()
	if rank_difference != 0:
		return 1 if rank_difference > 0 else -1
	return compare_suit_strength(card_a.suit, card_b.suit)

func compare_suit_strength(suit_a: String, suit_b: String) -> int:
	var strength_a := SUIT_ORDER.find(suit_a)
	var strength_b := SUIT_ORDER.find(suit_b)
	if strength_a == strength_b:
		return 0
	return 1 if strength_a > strength_b else -1

func compare_same_rank_suit_sequences(cards_a: Array, cards_b: Array) -> int:
	if cards_a.size() != cards_b.size():
		return 0
	var sorted_a: Array = cards_a.duplicate()
	var sorted_b: Array = cards_b.duplicate()
	sorted_a.sort_custom(func(a, b) -> bool: return compare_suit_strength(a.suit, b.suit) > 0)
	sorted_b.sort_custom(func(a, b) -> bool: return compare_suit_strength(a.suit, b.suit) > 0)
	for i in range(sorted_a.size()):
		var suit_comparison := compare_suit_strength(sorted_a[i].suit, sorted_b[i].suit)
		if suit_comparison != 0:
			return suit_comparison
	return 0

func compare_combinations(cards_a: Array, cards_b: Array) -> int:
	var combination_a := classify(cards_a)
	var combination_b := classify(cards_b)
	if not bool(combination_a.valid) or not bool(combination_b.valid):
		return 0
	if _family_for_type(str(combination_a.type)) != _family_for_type(str(combination_b.type)):
		return 0
	var count_comparison := int(combination_a.card_count) - int(combination_b.card_count)
	if count_comparison != 0:
		return 1 if count_comparison > 0 else -1
	# A Straight Flush is a categorical upgrade over an ordinary Straight.
	# Keep the existing rank-first comparison for all other cross-type plays.
	if str(combination_a.type) != str(combination_b.type):
		if str(combination_a.type) == TYPE_STRAIGHT_FLUSH:
			return 1
		if str(combination_b.type) == TYPE_STRAIGHT_FLUSH:
			return -1
	var rank_comparison := int(combination_a.high_rank) - int(combination_b.high_rank)
	if rank_comparison != 0:
		return 1 if rank_comparison > 0 else -1
	var type_comparison := _combination_type_priority(str(combination_a.type)) - _combination_type_priority(str(combination_b.type))
	if type_comparison != 0:
		return 1 if type_comparison > 0 else -1
	if str(combination_a.type) != str(combination_b.type):
		return 0
	if str(combination_a.type) not in [TYPE_STRAIGHT, TYPE_STRAIGHT_FLUSH]:
		return compare_same_rank_suit_sequences(cards_a, cards_b)
	var sorted_a: Array = cards_a.duplicate()
	var sorted_b: Array = cards_b.duplicate()
	sorted_a.sort_custom(func(a, b) -> bool: return a.strength() > b.strength())
	sorted_b.sort_custom(func(a, b) -> bool: return a.strength() > b.strength())
	return compare_suit_strength(sorted_a[0].suit, sorted_b[0].suit)

func list_legal_combinations(hand: Array, current_cards: Array = []) -> Array:
	var results: Array = []
	if hand.is_empty():
		return results
	var cards_by_rank := {}
	for card in hand:
		if not card is CardDataScript:
			continue
		var rank: int = card.strength()
		if rank < 0:
			continue
		if not cards_by_rank.has(rank):
			cards_by_rank[rank] = []
		cards_by_rank[rank].append(card)

	for card in hand:
		_append_if_legal([card], current_cards, results)
	for rank in cards_by_rank:
		var group: Array = cards_by_rank[rank]
		for group_size in [2, 3, 4]:
			if group.size() >= group_size:
				_choose_group(group, group_size, 0, [], current_cards, results)

	for length in range(MIN_STRAIGHT_LENGTH, mini(MAX_STRAIGHT_LENGTH, hand.size()) + 1):
		for start_rank in range(0, RANKS.size() - length + 1):
			var window: Array[int] = []
			var window_available := true
			for offset in range(length):
				var rank := start_rank + offset
				if not straight_allow_two and rank == RANKS.size() - 1:
					window_available = false
					break
				if not cards_by_rank.has(rank):
					window_available = false
					break
				window.append(rank)
			if window_available:
				_choose_straight(cards_by_rank, window, 0, [], current_cards, results)
	return results

func list_legal_combinations_for_type(hand: Array, current_cards: Array, combination_type: String) -> Array:
	var results: Array = []
	for cards in list_legal_combinations(hand, current_cards):
		if str(classify(cards).type) == combination_type:
			results.append(cards)
	return results

func selectable_card_ids(hand: Array, current_cards: Array, selected_card_ids: Array) -> Dictionary:
	var selected := {}
	for value in selected_card_ids:
		selected[str(value)] = true
	var selectable := {}
	for combination in list_legal_combinations(hand, current_cards):
		var contains_selection := true
		var combination_ids := {}
		for card in combination:
			combination_ids[card.card_id()] = true
		for selected_id in selected:
			if not combination_ids.has(selected_id):
				contains_selection = false
				break
		if not contains_selection:
			continue
		for card in combination:
			selectable[card.card_id()] = true
	return selectable

func can_pass() -> bool:
	return true

func _choose_group(pool: Array, target_size: int, start: int, chosen: Array, current_cards: Array, results: Array) -> void:
	if chosen.size() == target_size:
		_append_if_legal(chosen, current_cards, results)
		return
	var needed := target_size - chosen.size()
	for i in range(start, pool.size() - needed + 1):
		chosen.append(pool[i])
		_choose_group(pool, target_size, i + 1, chosen, current_cards, results)
		chosen.pop_back()

func _choose_straight(cards_by_rank: Dictionary, ranks: Array[int], index: int, chosen: Array, current_cards: Array, results: Array) -> void:
	if index == ranks.size():
		_append_if_legal(chosen, current_cards, results)
		return
	for card in cards_by_rank[ranks[index]]:
		chosen.append(card)
		_choose_straight(cards_by_rank, ranks, index + 1, chosen, current_cards, results)
		chosen.pop_back()

func _append_if_legal(cards: Array, current_cards: Array, results: Array) -> void:
	if can_beat(cards, current_cards):
		results.append(cards.duplicate())

func _combination_type_priority(combination_type: String) -> int:
	match combination_type:
		TYPE_TRIPLE, TYPE_FOUR_OF_A_KIND:
			return 1
		TYPE_STRAIGHT:
			return 0
		_:
			return 0

func _valid(combination_type: String, card_count: int, high_rank: int) -> Dictionary:
	return {
		"valid": true,
		"type": combination_type,
		"card_count": card_count,
		"high_rank": high_rank
	}

func _invalid(reason: String) -> Dictionary:
	return {"valid": false, "type": "", "card_count": 0, "high_rank": -1, "error": reason}

func _family_for_type(combination_type: String) -> String:
	match combination_type:
		TYPE_SINGLE, TYPE_TRIPLE, TYPE_STRAIGHT, TYPE_STRAIGHT_FLUSH:
			return "Odd"
		TYPE_PAIR, TYPE_FOUR_OF_A_KIND:
			return "Even"
		_:
			return ""
