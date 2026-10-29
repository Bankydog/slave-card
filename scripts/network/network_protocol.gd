class_name NetworkProtocol
extends RefCounted

const CardDataScript = preload("res://scripts/cards/card_data.gd")

const CREATE_ROOM := "create_room"
const JOIN_ROOM := "join_room"
const PLAYER_JOINED := "player_joined"
const PLAYER_LEFT := "player_left"
const START_GAME := "start_game"
const SET_READY := "set_ready"
const DEAL := "deal"
const SELECT_CARDS := "select_cards"
const SELECT_RPS := "select_rps"
const RPS_STATE := "rps_state"
const PLAY_CARDS := "play_cards"
const PASS := "pass"
const TURN_CHANGED := "turn_changed"
const PLAYER_FINISHED := "player_finished"
const ROLES_ASSIGNED := "roles_assigned"
const CARD_EXCHANGE := "card_exchange"
const ROUND_FINISHED := "round_finished"
const ROOM_CREATED := "room_created"
const LOBBY_STATE := "lobby_state"
const ACTION_REJECTED := "action_rejected"
const CONNECTED := "connected"
const LEAVE_ROOM := "leave_room"
const START_NEXT_ROUND := "start_next_round"
const REMATCH := "rematch"
const MATCH_FINISHED := "match_finished"

static func message(message_type: String, payload: Dictionary = {}) -> Dictionary:
	return {"type": message_type, "payload": payload.duplicate(true)}

static func card_ids(cards: Array) -> Array[String]:
	var result: Array[String] = []
	for card in cards:
		if card is CardDataScript:
			result.append(card.card_id())
	return result
