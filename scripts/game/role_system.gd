class_name RoleSystem
extends RefCounted

const TOP_ROLES_7_PLUS: Array[String] = ["King", "Queen", "Seven"]
const BOTTOM_ROLES_BY_FINISH: Array[String] = ["Slave 3", "Slave 2", "Slave 1"]
const TOP_ROLES_SMALL: Array[String] = ["King"]
const BOTTOM_ROLES_SMALL: Array[String] = ["Slave 1"]

static func role_order_for_count(player_count: int) -> Array[String]:
	var roles: Array[String] = []
	if player_count >= 7:
		roles.append_array(TOP_ROLES_7_PLUS)
		var normal_count := player_count - TOP_ROLES_7_PLUS.size() - BOTTOM_ROLES_BY_FINISH.size()
		for place in range(TOP_ROLES_7_PLUS.size() + 1, TOP_ROLES_7_PLUS.size() + normal_count + 1):
			roles.append(_ordinal(place))
		roles.append_array(BOTTOM_ROLES_BY_FINISH)
	else:
		roles.append_array(TOP_ROLES_SMALL)
		if player_count == 3:
			roles.append("Queen")
			roles.append("Slave 1")
		elif player_count >= 4:
			roles.append("Queen")
			var normal_count := player_count - 4
			for place in range(3, 3 + normal_count):
				roles.append(_ordinal(place))
			roles.append("Slave 2")
			roles.append("Slave 1")
		else:
			var normal_count := player_count - TOP_ROLES_SMALL.size() - BOTTOM_ROLES_SMALL.size()
			for place in range(TOP_ROLES_SMALL.size() + 1, TOP_ROLES_SMALL.size() + normal_count + 1):
				roles.append(_ordinal(place))
			roles.append_array(BOTTOM_ROLES_SMALL)
	return roles

static func resolve(finishing_order: Array[int], player_count: int, previous_roles: Dictionary) -> Dictionary:
	if finishing_order.size() != player_count:
		return {"ok": false, "error": "Finishing order must contain every player."}
	var role_order := role_order_for_count(player_count)
	var roles_by_player: Dictionary = {}
	for place in range(player_count):
		roles_by_player[finishing_order[place]] = role_order[place]

	var previous_king := -1
	for player_index in previous_roles:
		if str(previous_roles[player_index]) == "King":
			previous_king = int(player_index)
			break

	var demoted := false
	var displaced_player := -1
	if previous_king >= 0 and finishing_order[0] != previous_king:
		var displaced_role_holder := -1
		for player_index in roles_by_player:
			if str(roles_by_player[player_index]) == "Slave 1":
				displaced_role_holder = int(player_index)
				break
		if displaced_role_holder >= 0:
			var previous_king_role: String = roles_by_player[previous_king]
			roles_by_player[previous_king] = "Slave 1"
			roles_by_player[displaced_role_holder] = previous_king_role
			displaced_player = displaced_role_holder
			demoted = true

	return {
		"ok": true,
		"roles_by_player": roles_by_player,
		"previous_king_demoted": demoted,
		"previous_king_player": previous_king if demoted else -1,
		"displaced_player": displaced_player
	}

static func _ordinal(place: int) -> String:
	var suffix := "th"
	if place % 100 not in [11, 12, 13]:
		match place % 10:
			1: suffix = "st"
			2: suffix = "nd"
			3: suffix = "rd"
	return "%d%s" % [place, suffix]
