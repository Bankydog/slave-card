class_name BotBrain
extends RefCounted

func choose_play(hand: Array, current_cards: Array, rules) -> Array:
	var legal_plays: Array = rules.list_legal_combinations(hand, current_cards)
	if legal_plays.is_empty():
		return []
	var candidate_pool: Array = legal_plays
	if not current_cards.is_empty():
		var current_info: Dictionary = rules.classify(current_cards)
		var matching_plays: Array = []
		for candidate: Array in legal_plays:
			var candidate_info: Dictionary = rules.classify(candidate)
			if str(candidate_info.type) == str(current_info.type) and int(candidate_info.card_count) == int(current_info.card_count):
				matching_plays.append(candidate)
		if not matching_plays.is_empty():
			candidate_pool = matching_plays
	var best: Array = candidate_pool[0]
	for candidate: Array in candidate_pool:
		var candidate_info: Dictionary = rules.classify(candidate)
		var best_info: Dictionary = rules.classify(best)
		var same_shape := str(candidate_info.type) == str(best_info.type) and int(candidate_info.card_count) == int(best_info.card_count)
		if same_shape:
			var strength_comparison: int = rules.compare_combinations(candidate, best)
			if strength_comparison < 0 or (strength_comparison == 0 and _cards_before(candidate, best)):
				best = candidate
		elif int(candidate_info.high_rank) < int(best_info.high_rank):
			best = candidate
		elif int(candidate_info.high_rank) == int(best_info.high_rank):
			if candidate.size() < best.size():
				best = candidate
			elif candidate.size() == best.size() and _cards_before(candidate, best):
				best = candidate
	return best.duplicate()

# Compatibility helper for callers that still present a single center card.
func choose_card(hand: Array, current_card, is_lead: bool, rules):
	var current_cards: Array = [] if is_lead or current_card == null else [current_card]
	var play := choose_play(hand, current_cards, rules)
	return play[0] if not play.is_empty() else null

func _cards_before(a: Array, b: Array) -> bool:
	var a_sorted: Array[String] = []
	var b_sorted: Array[String] = []
	for card in a:
		a_sorted.append(card.card_id())
	for card in b:
		b_sorted.append(card.card_id())
	a_sorted.sort()
	b_sorted.sort()
	return "\n".join(a_sorted) < "\n".join(b_sorted)
