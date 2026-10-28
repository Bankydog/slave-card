class_name TurnManager
extends RefCounted

var current_player := 0

func start_at(player_index: int, player_count: int) -> void:
	current_player = posmod(player_index, player_count)

func next_active(players: Array, after_index: int) -> int:
	if players.is_empty():
		return -1
	for step in range(1, players.size() + 1):
		var candidate := posmod(after_index + step, players.size())
		if not players[candidate].finished:
			return candidate
	return -1
