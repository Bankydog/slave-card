extends Node

const CARD_FLIP_SOUND: AudioStream = preload("res://assets/sound/flip-card.mp3")
const VOLUMES_DB := {
	"ui_click": -20.0,
	"card_select": -16.0,
	"card_play": -8.0,
	"shuffle": -10.0,
}

var players: Array[AudioStreamPlayer] = []
var audio_unlocked := false
var pending_sfx: Array[String] = []

func _ready() -> void:
	_add_player()

func play_ui_click() -> void:
	audio_unlocked = true
	play_sfx("ui_click")
	var queued := pending_sfx.duplicate()
	pending_sfx.clear()
	for sfx_name in queued:
		play_sfx(sfx_name)

func play_card_select() -> void:
	play_sfx("card_select")

func play_card_play() -> void:
	play_sfx("card_play")

func play_shuffle() -> void:
	play_sfx("shuffle")

func play_sfx(name: String) -> void:
	if not audio_unlocked:
		if not pending_sfx.has(name):
			pending_sfx.append(name)
		return
	var player := _available_player()
	player.stream = CARD_FLIP_SOUND
	player.volume_db = float(VOLUMES_DB.get(name, -12.0))
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
