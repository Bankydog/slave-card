extends RefCounted

const GameStateResource: Script = preload("res://scripts/game/game_state.gd")

static func create() -> RefCounted:
	return GameStateResource.new()
