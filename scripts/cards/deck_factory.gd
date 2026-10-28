class_name DeckFactory
extends RefCounted

const HandSorterScript = preload("res://scripts/cards/hand_sorter.gd")
const CardDataScript = preload("res://scripts/cards/card_data.gd")

static func deck_count_for_players(player_count: int) -> int:
	return 1 if player_count <= 6 else 2

static func create_deck(player_count: int, rng: RandomNumberGenerator = null) -> Array:
	var deck: Array = []
	var count := deck_count_for_players(player_count)
	for deck_index in range(count):
		for suit in CardDataScript.SUITS:
			for rank in CardDataScript.RANKS:
				deck.append(CardDataScript.new(rank, suit, deck_index))
	var randomizer := rng if rng != null else RandomNumberGenerator.new()
	if rng == null:
		randomizer.randomize()
	for i in range(deck.size() - 1, 0, -1):
		var j := randomizer.randi_range(0, i)
		var temp: Variant = deck[i]
		deck[i] = deck[j]
		deck[j] = temp
	return deck

static func deal(deck: Array, player_count: int) -> Array:
	var hands: Array = []
	hands.resize(player_count)
	for i in range(player_count):
		hands[i] = []
	for i in range(deck.size()):
		hands[i % player_count].append(deck[i])
	for hand in hands:
		HandSorterScript.sort_hand(hand)
	return hands
