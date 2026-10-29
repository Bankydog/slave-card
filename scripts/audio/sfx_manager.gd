extends Node

const CARD_FLIP_SOUND: AudioStream = preload("res://assets/sound/flip-card.mp3")

var players: Array[AudioStreamPlayer] = []

func _ready() -> void:
	_add_player()

func play_ui_click() -> void:
	pass

func play_card_select() -> void:
	_play_card_flip()

func play_card_play() -> void:
	_play_card_flip()

func play_shuffle() -> void:
	pass

func play_sfx(name: String) -> void:
	match name:
		"card_select", "card_play":
			_play_card_flip()
		_:
			pass

func _play_card_flip() -> void:
	var player := _available_player()
	player.stream = CARD_FLIP_SOUND
	player.play()

func _available_player() -> AudioStreamPlayer:
	for player in players:
		if not player.playing:
			return player
	return _add_player()

func _add_player() -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = "SfxVoice%d" % players.size()
	add_child(player)
	players.append(player)
	return player
