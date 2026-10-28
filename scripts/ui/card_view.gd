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
	card_scale_factor = maxf(1.0, scale_factor)
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
	return Color("#b51f36") if card.suit in ["Hearts", "Diamonds"] else Color("#17212b")

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
	var dim_ink := Color("#985d66") if card.suit in ["Hearts", "Diamonds"] else Color("#626d68")
	add_theme_color_override("font_color", ink)
	add_theme_color_override("font_hover_color", ink)
	add_theme_color_override("font_disabled_color", dim_ink)
	if is_instance_valid(top_rank):
		var mark_ink := ink if playable else dim_ink
		top_rank.add_theme_color_override("font_color", mark_ink)
		center_suit.modulate = Color.WHITE if playable else dim_ink
	modulate = Color.WHITE

static func display_scale(viewport_size: Vector2) -> float:
	var physical_size := DisplayServer.window_get_size()
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return 1.0
	if physical_size.x <= 0 or physical_size.y <= 0:
		var fallback_ratio := minf(viewport_size.x / 1152.0, viewport_size.y / 648.0)
		return clampf(fallback_ratio, 1.0, 2.25)
	var output_scale := minf(float(physical_size.x) / viewport_size.x, float(physical_size.y) / viewport_size.y)
	var mobile_compensation := 1.0 / maxf(0.25, output_scale) if output_scale < 1.0 else 1.0
	return clampf(mobile_compensation, 1.0, 2.25)

static func add_hand_slot(container: Container, view: CardView, compact: bool = false, scale_factor: float = 1.0) -> void:
	var card_height := (64.0 if compact else 92.0) * maxf(1.0, scale_factor)
	var lift := (13.0 if compact else 17.0) * maxf(1.0, scale_factor)
	var slot := Control.new()
	slot.custom_minimum_size = Vector2(view.custom_minimum_size.x, card_height + lift)
	view.position = Vector2(0.0, 0.0 if view.selected else lift)
	slot.add_child(view)
	container.add_child(slot)

static func make_pile(cards: Array, compact: bool = false, scale_factor: float = 1.0) -> Control:
	var factor := maxf(1.0, scale_factor)
	var card_width := (42.0 if compact else 58.0) * factor
	var card_height := (64.0 if compact else 92.0) * factor
	var step := (17.0 if compact else 22.0) * factor
	var pile_width := card_width + maxi(0, cards.size() - 1) * step + 12.0 * factor
	var pile_height := card_height + (8.0 if compact else 16.0) * factor
	var frame := CenterContainer.new()
	frame.name = "CenterCardPile"
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.custom_minimum_size = Vector2(pile_width, pile_height)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pile := Control.new()
	pile.custom_minimum_size = Vector2(pile_width, pile_height)
	pile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(pile)
	var rotations := [-4.0, 2.5, -1.2, 3.6, -2.8, 1.1, 4.1]
	var vertical_offsets := [3.0, -4.0, 1.0, -2.0, 4.0, -3.0, 0.0]
	for i in range(cards.size()):
		var view: CardView = CardView.new()
		view.setup(cards[i], false, compact, factor)
		view.size = Vector2(card_width, card_height)
		view.pivot_offset = Vector2(card_width * 0.5, card_height * 0.5)
		var center_x := (pile_width - card_width) * 0.5
		var x := center_x + (float(i) - float(cards.size() - 1) * 0.5) * step
		view.position = Vector2(x, (pile_height - card_height) * 0.5 + vertical_offsets[i % vertical_offsets.size()] * factor)
		view.rotation_degrees = rotations[i % rotations.size()]
		view.z_index = i
		pile.add_child(view)
	return frame
