class_name CardData
extends RefCounted

const CardDataScript = preload("res://scripts/cards/card_data.gd")

const SUITS := ["Clubs", "Diamonds", "Hearts", "Spades"]
const RANKS := ["3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A", "2"]
const SUIT_SYMBOLS := {"Clubs": "♣", "Diamonds": "♦", "Hearts": "♥", "Spades": "♠"}

var rank: String
var suit: String
var deck_index: int

func _init(p_rank: String, p_suit: String, p_deck_index: int = 0) -> void:
	rank = p_rank
	suit = p_suit
	deck_index = p_deck_index

func strength() -> int:
	return RANKS.find(rank)

func display_name() -> String:
	return "%s%s" % [rank, SUIT_SYMBOLS.get(suit, suit)]

func card_id() -> String:
	return "%s:%s:%d" % [rank, suit, deck_index]

func to_dict() -> Dictionary:
	return {"rank": rank, "suit": suit, "deck_index": deck_index, "id": card_id()}

static func from_dict(data: Dictionary):
	return CardDataScript.new(str(data.get("rank", "3")), str(data.get("suit", "Clubs")), int(data.get("deck_index", 0)))
