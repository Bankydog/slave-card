class_name MatchState
extends RefCounted

const ALLOWED_ROUND_LIMITS: Array[int] = [4, 8, 12]

var match_round_limit := 4
var current_round := 0
var match_scores: Array[int] = []
var first_place_counts: Array[int] = []
var second_place_counts: Array[int] = []
var final_positions: Array[int] = []
var round_history: Array[Dictionary] = []

func begin(player_count: int, round_limit: int = 4) -> bool:
	if player_count < 2 or player_count > 12 or not ALLOWED_ROUND_LIMITS.has(round_limit):
		return false
	match_round_limit = round_limit
	current_round = 0
	match_scores.resize(player_count)
	match_scores.fill(0)
	first_place_counts.resize(player_count)
	first_place_counts.fill(0)
	second_place_counts.resize(player_count)
	second_place_counts.fill(0)
	final_positions.resize(player_count)
	final_positions.fill(0)
	round_history.clear()
	return true

func advance_round() -> bool:
	if current_round >= match_round_limit:
		return false
	current_round += 1
	return true

func record_round(finishing_order: Array) -> Dictionary:
	var player_count := match_scores.size()
	if player_count < 2 or finishing_order.size() != player_count or round_history.size() >= current_round:
		return {"ok": false, "error": "The round result is incomplete or already recorded."}
	var seen: Dictionary = {}
	var round_points: Array[int] = []
	round_points.resize(player_count)
	round_points.fill(0)
	for place in range(finishing_order.size()):
		var player_index := int(finishing_order[place])
		if player_index < 0 or player_index >= player_count or seen.has(player_index):
			return {"ok": false, "error": "The finishing order is invalid."}
		seen[player_index] = true
		var points := player_count - place - 1
		round_points[player_index] = points
		match_scores[player_index] += points
		final_positions[player_index] = place + 1
		if place == 0:
			first_place_counts[player_index] += 1
		elif place == 1:
			second_place_counts[player_index] += 1
	round_history.append({
		"round": current_round,
		"finishing_order": finishing_order.duplicate(),
		"round_points": round_points.duplicate()
	})
	return {
		"ok": true,
		"round_points": round_points,
		"match_scores": match_scores.duplicate(),
		"first_place_counts": first_place_counts.duplicate(),
		"second_place_counts": second_place_counts.duplicate()
	}

func ranked_player_indices() -> Array[int]:
	var result: Array[int] = []
	for i in range(match_scores.size()):
		result.append(i)
	result.sort_custom(func(a: int, b: int) -> bool:
		if match_scores[a] != match_scores[b]:
			return match_scores[a] > match_scores[b]
		if first_place_counts[a] != first_place_counts[b]:
			return first_place_counts[a] > first_place_counts[b]
		if second_place_counts[a] != second_place_counts[b]:
			return second_place_counts[a] > second_place_counts[b]
		if final_positions[a] != final_positions[b]:
			return final_positions[a] < final_positions[b]
		return a < b
	)
	return result
