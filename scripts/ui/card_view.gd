class_name CardView
extends Button

var card: CardData
var selected := false
var playable := true
var compact_view := false
var card_scale_factor := 1.0
var face_overlay: Control
var top_rank: Label
var center_suit: TextureRect

const GameRulesScript = preload("res://scripts/game/game_rules.gd")

const SUIT_TEXTURES := {
	"Clubs": preload("res://assets/suits/clubs.png"),
	"Diamonds": preload("res://assets/suits/diamonds.png"),
	"Hearts": preload("res://assets/suits/hearts.png"),
	"Spades": preload("res://assets/suits/spades.png"),
}

func setup(card_data: CardData, is_selected: bool = false, compact: bool = false, scale_factor: float = 1.0) -> void:
	card = card_data
	selected = is_selected
	compact_view = compact
	card_scale_factor = maxf(0.35, scale_factor)
	text = ""
	var card_width := 42.0 if compact_view else 58.0
	var card_height := 64.0 if compact_view else 92.0
	custom_minimum_size = Vector2(card_width, card_height) * card_scale_factor
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	focus_mode = Control.FOCUS_NONE
	_create_face_marks()
	_apply_styles()

func set_available(can_select: bool) -> void:
	playable = can_select
	_apply_styles()

func _create_face_marks() -> void:
	if is_instance_valid(face_overlay):
		face_overlay.queue_free()
	face_overlay = Control.new()
	face_overlay.name = "FaceMarks"
	face_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	face_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(face_overlay)
	var width := (42.0 if compact_view else 58.0) * card_scale_factor
	var height := (64.0 if compact_view else 92.0) * card_scale_factor
	top_rank = Label.new()
	top_rank.name = "TopLeftRank"
	top_rank.text = card.rank
	top_rank.position = Vector2(4, 2) * card_scale_factor
	top_rank.custom_minimum_size = Vector2(width * 0.65, 24.0 * card_scale_factor)
	top_rank.add_theme_font_size_override("font_size", maxi(16, roundi((17.0 if compact_view else 20.0) * card_scale_factor)))
	top_rank.add_theme_color_override("font_color", _suit_ink())
	top_rank.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face_overlay.add_child(top_rank)
	center_suit = TextureRect.new()
	center_suit.name = "CenterSuit"
	center_suit.texture = _suit_texture()
	center_suit.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	center_suit.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var suit_size := Vector2(40.0, 40.0) if compact_view else Vector2(52.0, 52.0)
	center_suit.size = suit_size * card_scale_factor
	center_suit.position = (Vector2(width, height) - center_suit.size) * 0.5 + Vector2(0.0, 6.0 * card_scale_factor)
	center_suit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face_overlay.add_child(center_suit)
	face_overlay.custom_minimum_size = Vector2(width, height)

func _suit_texture() -> Texture2D:
	return SUIT_TEXTURES.get(card.suit) as Texture2D

func _suit_ink() -> Color:
	return Color("#111111")

func _apply_styles() -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("#fffdf7") if playable else Color("#e7e8e2")
	normal.border_color = Color("#44564f") if playable else Color("#a3aaa3")
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(5)
	var hover := normal.duplicate() as StyleBoxFlat
	var pressed_style := normal.duplicate() as StyleBoxFlat
	var disabled_style := normal.duplicate() as StyleBoxFlat
	add_theme_stylebox_override("normal", normal)
	add_theme_stylebox_override("hover", hover)
	add_theme_stylebox_override("pressed", pressed_style)
	add_theme_stylebox_override("disabled", disabled_style)
	var ink := _suit_ink()
	var dim_ink := Color("#626d68")
	add_theme_color_override("font_color", ink)
	add_theme_color_override("font_hover_color", ink)
	add_theme_color_override("font_disabled_color", dim_ink)
	if is_instance_valid(top_rank):
		top_rank.add_theme_color_override("font_color", ink)
		center_suit.modulate = Color.WHITE if playable else dim_ink
	modulate = Color.WHITE

static func display_scale(viewport_size: Vector2) -> float:
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return 1.0
	return clampf(minf(viewport_size.x / 1920.0, viewport_size.y / 1080.0), 0.35, 2.25)

static func hand_separation(card_count: int, available_width: float, compact: bool = false, scale_factor: float = 1.0) -> float:
	var factor := maxf(0.35, scale_factor)
	var card_width := (42.0 if compact else 58.0) * factor
	var preferred_overlap := (21.0 if compact else 29.0) * factor
	var minimum_overlap := 18.0 * factor
	var required_width := float(card_count) * card_width - float(maxi(0, card_count - 1)) * preferred_overlap
	if required_width <= available_width or card_count <= 1:
		return -preferred_overlap
	var fitted_overlap := card_width - (available_width - card_width) / float(card_count - 1)
	return -clampf(fitted_overlap, minimum_overlap, card_width - 1.0 * factor)

static func add_hand_slot(container: Container, view: CardView, compact: bool = false, scale_factor: float = 1.0) -> void:
	var card_height := (64.0 if compact else 92.0) * maxf(0.35, scale_factor)
	var lift := (13.0 if compact else 17.0) * maxf(0.35, scale_factor)
	var slot := Control.new()
	slot.custom_minimum_size = Vector2(view.custom_minimum_size.x, card_height + lift)
	view.position = Vector2(0.0, 0.0 if view.selected else lift)
	slot.add_child(view)
	container.add_child(slot)

static func get_play_landing_layout(cards: Array, compact: bool = false, scale_factor: float = 1.0) -> Dictionary:
	var ordered_cards: Array = cards.duplicate()
	ordered_cards.sort_custom(_visual_card_less)
	var factor := maxf(0.35, scale_factor)
	var card_width := (42.0 if compact else 58.0) * factor
	var rules = GameRulesScript.new()
	var classification: Dictionary = rules.classify(ordered_cards)
	var combo_type := str(classification.get("type", ""))
	var pair_sequence := _is_visual_pair_sequence(ordered_cards)
	if pair_sequence:
		combo_type = "Pair Sequence"

	var advances: Array[float] = []
	var total_advance := 0.0
	for i in range(1, ordered_cards.size()):
		var step := 0.5
		if pair_sequence:
			var previous: CardData = ordered_cards[i - 1]
			var current: CardData = ordered_cards[i]
			step = 0.38 if previous.strength() == current.strength() else 0.66
		else:
			match combo_type:
				"Single":
					step = 0.0
				"Pair":
					step = 0.50
				"Triple":
					step = 0.52
				"Four of a Kind":
					step = 0.54
				"Straight", "Straight Flush":
					step = 0.58
		var step_pixels := card_width * step
		advances.append(step_pixels)
		total_advance += step_pixels

	var offsets: Array[Vector2] = []
	var rotations: Array[float] = []
	var cursor := 0.0
	for i in range(ordered_cards.size()):
		var vertical_offset := 0.0
		if pair_sequence:
			vertical_offset = (-1.0 if i % 2 == 0 else 1.0) * card_width * 0.015
		offsets.append(Vector2(cursor - total_advance * 0.5, vertical_offset))
		rotations.append(0.0)
		if i < advances.size():
			cursor += advances[i]

	return {
		"cards": ordered_cards,
		"offsets": offsets,
		"rotations": rotations,
		"combo_type": combo_type,
		"width": card_width + total_advance
	}

static func _visual_card_less(card_a: CardData, card_b: CardData) -> bool:
	if card_a.strength() != card_b.strength():
		return card_a.strength() < card_b.strength()
	var suit_a := CardData.SUITS.find(card_a.suit)
	var suit_b := CardData.SUITS.find(card_b.suit)
	if suit_a != suit_b:
		return suit_a < suit_b
	if card_a.deck_index != card_b.deck_index:
		return card_a.deck_index < card_b.deck_index
	return card_a.card_id() < card_b.card_id()

static func _is_visual_pair_sequence(cards: Array) -> bool:
	if cards.size() < 4 or cards.size() % 2 != 0:
		return false
	var rank_counts := {}
	for card: CardData in cards:
		var rank := card.strength()
		rank_counts[rank] = int(rank_counts.get(rank, 0)) + 1
	if rank_counts.size() * 2 != cards.size():
		return false
	var ranks: Array = rank_counts.keys()
	ranks.sort()
	for rank in ranks:
		if int(rank_counts[rank]) != 2:
			return false
	for i in range(1, ranks.size()):
		if int(ranks[i]) != int(ranks[i - 1]) + 1:
			return false
	return true

static func make_pile(cards: Array, compact: bool = false, scale_factor: float = 1.0, latest_play_cards: Array = []) -> Control:
	var factor := maxf(0.35, scale_factor)
	var card_width := (42.0 if compact else 58.0) * factor
	var card_height := (64.0 if compact else 92.0) * factor
	var layout := get_play_landing_layout(latest_play_cards, compact, factor) if not latest_play_cards.is_empty() else {}
	var latest_offsets: Dictionary = {}
	var latest_rotations: Dictionary = {}
	var latest_order: Dictionary = {}
	for i in range(layout.get("cards", []).size()):
		var card: CardData = layout.cards[i]
		latest_offsets[card.card_id()] = layout.offsets[i]
		latest_rotations[card.card_id()] = layout.rotations[i]
		latest_order[card.card_id()] = i
	var base_width := card_width + (86.0 if compact else 112.0) * factor
	var pile_width := maxf(base_width, float(layout.get("width", 0.0)) + 16.0 * factor)
	var pile_height := card_height + (62.0 if compact else 82.0) * factor
	var frame := CenterContainer.new()
	frame.name = "CenterCardPile"
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.custom_minimum_size = Vector2(pile_width, pile_height)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pile := Control.new()
	pile.custom_minimum_size = Vector2(pile_width, pile_height)
	pile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(pile)
	var rotations := [-8.0, 5.5, -2.0, 9.0, -5.0, 2.0, 7.0, -10.0, 3.5, -4.0, 11.0, -6.5]
	var x_offsets := [-30.0, 8.0, 24.0, -17.0, 35.0, -4.0, -36.0, 16.0, 29.0, -25.0, 2.0, 38.0]
	var y_offsets := [-13.0, 10.0, -5.0, 20.0, -18.0, 4.0, 16.0, -22.0, 7.0, 23.0, -10.0, 1.0]
	var center := Vector2((pile_width - card_width) * 0.5, (pile_height - card_height) * 0.5)
	for i in range(cards.size()):
		var card: CardData = cards[i]
		var view: CardView = CardView.new()
		view.setup(card, false, compact, factor)
		view.size = Vector2(card_width, card_height)
		view.pivot_offset = Vector2(card_width * 0.5, card_height * 0.5)
		var card_id := card.card_id()
		if latest_offsets.has(card_id):
			view.position = center + latest_offsets[card_id]
			view.rotation_degrees = float(latest_rotations[card_id])
			view.z_index = cards.size() + int(latest_order[card_id])
		else:
			var pattern_index := i % rotations.size()
			view.position = center + Vector2(x_offsets[pattern_index], y_offsets[pattern_index]) * factor
			view.rotation_degrees = rotations[pattern_index]
			view.z_index = i
		pile.add_child(view)
	return frame
