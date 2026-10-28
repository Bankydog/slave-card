class_name HandSorter
extends RefCounted

const GameRulesScript = preload("res://scripts/game/game_rules.gd")

static func sort_hand(hand: Array) -> void:
	var rules = GameRulesScript.new()
	hand.sort_custom(func(a: CardData, b: CardData) -> bool:
		var strength_comparison: int = rules.compare_card_strength(a, b)
		if strength_comparison != 0:
			return strength_comparison < 0
		if a.deck_index != b.deck_index:
			return a.deck_index < b.deck_index
		return a.card_id() < b.card_id()
	)
