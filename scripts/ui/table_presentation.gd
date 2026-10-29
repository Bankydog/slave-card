extends Control

const CardViewScript = preload("res://scripts/ui/card_view.gd")
const TableLayoutScript = preload("res://scripts/ui/table_layout.gd")
const KING_TEXTURE = preload("res://assets/gadget/king.png")
const QUEEN_TEXTURE = preload("res://assets/gadget/queen.png")
const SEVEN_TEXTURE = preload("res://assets/gadget/se7en.png")
const SLAVES_TEXTURE = preload("res://assets/gadget/slaves.png")
const RPS_ATLAS = preload("res://assets/suits/SPR.png")
const RPS_BACK = preload("res://assets/suits/back-card.png")
const CARD_FLIP_SOUND = preload("res://assets/sound/flip-card.mp3")

var seat_widgets: Array[PanelContainer] = []
var name_labels: Array[Label] = []
var role_icons: Array[TextureRect] = []
var detail_labels: Array[Label] = []
var status_labels: Array[Label] = []
var center_title: Label
var center_info: Label
var center_pile: Control
var center_layer: CenterContainer
var center_group: VBoxContainer
var table_artwork: Control
var seat_layer: Control
var compact_view := false
var built_compact := false
var layout_scale := 1.0
var local_seat_index := 0
var play_flight_layer: Control
var play_animation_tween: Tween
var play_animation_id := 0
var center_card_ids: Array[String] = []
var has_center_snapshot := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_layout_seats)
	_build_table_artwork()
	_build_center_layer()
	_build_seat_layer()
	play_flight_layer = Control.new()
	play_flight_layer.name = "PlayFlightLayer"
	play_flight_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	play_flight_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	play_flight_layer.z_index = 100
	add_child(play_flight_layer)

func _build_table_artwork() -> void:
	# The room and felt table are already composed in the full-screen background.
	# A second cropped copy creates the visible square seam seen in gameplay.
	table_artwork = Control.new()
	table_artwork.name = "TableArtwork"
	table_artwork.visible = false
	table_artwork.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(table_artwork)

func _build_seat_layer() -> void:
	seat_layer = Control.new()
	seat_layer.name = "SeatLayer"
	seat_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	seat_layer.clip_contents = false
	seat_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(seat_layer)

func configure(players: Array, local_index: int, current_player: int, passed: Array, cards: Array, center_text: String, compact: bool, played_by: int = -1) -> void:
	compact_view = compact
	local_seat_index = clampi(local_index, 0, maxi(0, players.size() - 1))
	var layout: Dictionary = TableLayoutScript.layout_for_viewport(get_viewport_rect().size)
	layout_scale = float(layout.scale)
	_ensure_seats(players.size())
	center_group.add_theme_constant_override("separation", roundi((2.0 if compact_view else 6.0) * layout_scale))
	for i in range(players.size()):
		var player: Dictionary = players[i]
		var player_name := str(player.get("name", "Player %d" % (i + 1)))
		var role := str(player.get("role", ""))
		var card_count := int(player.get("card_count", player.get("hand", []).size()))
		name_labels[i].text = player_name if players.size() > 8 else "%d · %s" % [i + 1, player_name]
		detail_labels[i].text = "%d cards" % card_count
		role_icons[i].texture = role_texture(role)
		role_icons[i].visible = role_icons[i].texture != null
		role_icons[i].custom_minimum_size = Vector2(24, 20) * layout_scale
		var status := "WAITING"
		if bool(player.get("disconnected", false)) or bool(player.get("forfeited", false)):
			status = "LEFT"
		elif bool(player.get("finished", false)):
			status = "FINISHED"
		elif i < passed.size() and bool(passed[i]):
			status = "PASSED"
		elif i == current_player:
			status = "YOUR TURN" if i == local_index else "TURN"
		status_labels[i].text = status
		_style_seat(seat_widgets[i], i == current_player and not bool(player.get("finished", false)), i == local_index)
	center_title.text = center_text
	var show_played_cards := not cards.is_empty()
	center_title.visible = not show_played_cards
	center_info.visible = not show_played_cards
	var next_ids: Array[String] = []
	for card: CardData in cards:
		next_ids.append(card.card_id())
	var had_center_snapshot := has_center_snapshot
	var cards_changed := not has_center_snapshot or next_ids != center_card_ids
	if cards_changed:
		play_animation_id += 1
		if is_instance_valid(play_animation_tween):
			play_animation_tween.kill()
			play_animation_tween = null
		for child in play_flight_layer.get_children():
			child.queue_free()
		center_card_ids = next_ids
		has_center_snapshot = true
		if is_instance_valid(center_pile):
			center_pile.queue_free()
			center_pile = null
		if not cards.is_empty():
			center_pile = CardViewScript.make_pile(cards, compact_view, layout_scale * 2.0)
			center_group.add_child(center_pile)
			center_pile.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if played_by >= 0 and played_by < players.size():
				if had_center_snapshot:
					SfxManager.play_card_play()
				if seats_can_animate():
					_start_card_flight(cards, played_by)
	center_title.add_theme_font_size_override("font_size", maxi(16, roundi(16.0 * layout_scale)))
	call_deferred("_layout_seats")

func set_center_info(message: String) -> void:
	center_info.text = message

func seats_can_animate() -> bool:
	return not seat_widgets.is_empty() and is_instance_valid(play_flight_layer)

func _start_card_flight(cards: Array, played_by: int) -> void:
	if cards.is_empty() or played_by < 0 or played_by >= seat_widgets.size() or not is_instance_valid(center_pile):
		return
	var animation_token := play_animation_id
	center_pile.modulate = Color(1.0, 1.0, 1.0, 0.0)
	await get_tree().process_frame
	if animation_token != play_animation_id or not is_inside_tree() or not is_instance_valid(center_pile):
		return
	var source_global := seat_widgets[played_by].get_global_rect().get_center()
	var source := play_flight_layer.get_global_transform().affine_inverse() * source_global
	var flight_scale := layout_scale * 2.0
	var card_width := (42.0 if compact_view else 58.0) * flight_scale
	var card_height := (64.0 if compact_view else 92.0) * flight_scale
	var pile_cards: Control = center_pile.get_child(0)
	var stagger := 0.035
	var sound_duration := CARD_FLIP_SOUND.get_length()
	var flight_duration := maxf(0.1, sound_duration - stagger * float(cards.size() - 1))
	play_animation_tween = create_tween()
	play_animation_tween.set_parallel(true)
	for i in range(cards.size()):
		var flight_card = CardViewScript.new()
		flight_card.setup(cards[i], false, compact_view, flight_scale)
		flight_card.set_available(true)
		flight_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		flight_card.size = Vector2(card_width, card_height)
		flight_card.pivot_offset = Vector2(card_width, card_height) * 0.5
		flight_card.position = source - Vector2(card_width, card_height) * 0.5
		flight_card.scale = Vector2(0.58, 0.58)
		play_flight_layer.add_child(flight_card)
		var target_card := pile_cards.get_child(i) as Control
		var destination := play_flight_layer.get_global_transform().affine_inverse() * target_card.global_position
		var delay := float(i) * stagger
		play_animation_tween.tween_property(flight_card, "position", destination, flight_duration).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		play_animation_tween.tween_property(flight_card, "scale", Vector2.ONE, flight_duration).set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		play_animation_tween.tween_property(flight_card, "rotation", target_card.rotation, flight_duration).set_delay(delay)
	play_animation_tween.finished.connect(_finish_card_flight.bind(animation_token))

func _finish_card_flight(animation_token: int) -> void:
	if animation_token != play_animation_id:
		return
	for child in play_flight_layer.get_children():
		child.queue_free()
	if is_instance_valid(center_pile):
		center_pile.modulate = Color.WHITE
	play_animation_tween = null

func set_center_message(message: String) -> void:
	center_title.text = message
	if is_instance_valid(center_pile):
		center_pile.queue_free()
		center_pile = null

func _build_center_layer() -> void:
	center_layer = CenterContainer.new()
	center_layer.name = "CenterPileLayer"
	center_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center_layer)
	center_group = VBoxContainer.new()
	center_group.name = "CenterGroup"
	center_group.alignment = BoxContainer.ALIGNMENT_CENTER
	center_group.add_theme_constant_override("separation", 4)
	center_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center_layer.add_child(center_group)
	center_title = Label.new()
	center_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center_title.add_theme_color_override("font_color", Color("#f3e9cc"))
	center_title.add_theme_font_size_override("font_size", 16)
	center_group.add_child(center_title)
	center_info = Label.new()
	center_info.name = "CardsTurnInfo"
	center_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center_info.add_theme_color_override("font_color", Color("#f3e9cc"))
	center_info.add_theme_font_size_override("font_size", 16)
	center_group.add_child(center_info)

func _ensure_seats(count: int) -> void:
	if seat_widgets.size() == count and built_compact == compact_view:
		return
	built_compact = compact_view
	for child in seat_layer.get_children():
		child.queue_free()
	seat_widgets.clear()
	name_labels.clear()
	role_icons.clear()
	detail_labels.clear()
	status_labels.clear()
	for i in range(count):
		var panel := PanelContainer.new()
		panel.name = "Seat%d" % (i + 1)
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var content := VBoxContainer.new()
		content.add_theme_constant_override("separation", 0)
		content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(content)
		var name_row := HBoxContainer.new()
		name_row.add_theme_constant_override("separation", 4)
		content.add_child(name_row)
		var player_name := Label.new()
		player_name.clip_text = true
		player_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		player_name.add_theme_color_override("font_color", Color("#fff8e8"))
		player_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_row.add_child(player_name)
		var details_row := HBoxContainer.new()
		details_row.add_theme_constant_override("separation", 4)
		content.add_child(details_row)
		var details := Label.new()
		details.clip_text = true
		details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		details.add_theme_color_override("font_color", Color("#cbd9cb"))
		details.mouse_filter = Control.MOUSE_FILTER_IGNORE
		details_row.add_child(details)
		var role_icon := TextureRect.new()
		role_icon.name = "RoleIcon"
		role_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		role_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		role_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		role_icon.hide()
		details_row.add_child(role_icon)
		var status := Label.new()
		status.clip_text = true
		status.add_theme_color_override("font_color", Color("#f3d78b"))
		status.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(status)
		seat_layer.add_child(panel)
		seat_widgets.append(panel)
		name_labels.append(player_name)
		role_icons.append(role_icon)
		detail_labels.append(details)
		status_labels.append(status)
	_layout_seats()

static func rps_texture(choice: int) -> AtlasTexture:
	var cropped := AtlasTexture.new()
	cropped.atlas = RPS_ATLAS
	var cell_width := float(RPS_ATLAS.get_width()) / 3.0
	cropped.region = Rect2(cell_width * clampi(choice, 0, 2), 0.0, cell_width, float(RPS_ATLAS.get_height()))
	return cropped

static func rps_back_texture() -> Texture2D:
	return RPS_BACK

static func make_role_summary_row(role: String, line: Label, scale: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var role_icon := TextureRect.new()
	role_icon.texture = role_texture(role)
	if role_icon.texture != null:
		role_icon.custom_minimum_size = Vector2(36, 36) * scale
	role_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	role_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	role_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(role_icon)
	row.add_child(line)
	return row

static func role_texture(role: String) -> Texture2D:
	var normalized := role.to_lower()
	match normalized:
		"king": return KING_TEXTURE
		"queen": return QUEEN_TEXTURE
		"seven", "se7en": return SEVEN_TEXTURE
		_:
			return SLAVES_TEXTURE if normalized.begins_with("slave") else null

func _style_seat(panel: PanelContainer, is_current: bool, is_local: bool) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#173b32")
	style.border_color = Color("#edc969") if is_current else (Color("#9bb9a7") if is_local else Color("#567768"))
	style.set_border_width_all(2 if is_current or is_local else 1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 6 * layout_scale
	style.content_margin_right = 6 * layout_scale
	style.content_margin_top = 3 * layout_scale
	style.content_margin_bottom = 3 * layout_scale
	panel.add_theme_stylebox_override("panel", style)

func _layout_seats() -> void:
	if not is_inside_tree() or size.x <= 0.0 or size.y <= 0.0:
		return
	var viewport_size := get_viewport_rect().size
	var layout: Dictionary = TableLayoutScript.layout_for_viewport(viewport_size)
	var scale := float(layout.scale)
	layout_scale = scale
	var table_rect: Rect2 = layout.table_zone
	table_artwork.position = table_rect.position
	table_artwork.size = table_rect.size
	center_layer.position = table_rect.position
	center_layer.size = table_rect.size
	seat_layer.position = Vector2.ZERO
	var count := seat_widgets.size()
	if count == 0:
		return
	var positions := normalized_seat_positions(count, compact_view, local_seat_index)
	var panel_size := seat_panel_size(count, scale)
	var font_size := maxi(14, roundi((16.0 if count <= 8 else 14.0) * scale))
	for label in name_labels + detail_labels + status_labels:
		label.add_theme_font_size_override("font_size", font_size)
	var center := table_rect.position + table_rect.size * 0.5
	for i in range(count):
		var panel := seat_widgets[i]
		panel.custom_minimum_size = panel_size
		panel.size = panel_size
		var normalized: Vector2 = positions[i]
		var point := center + Vector2((normalized.x - 0.5) * table_rect.size.x, (normalized.y - 0.5) * table_rect.size.y)
		panel.position = point - panel_size * 0.5

static func seat_panel_size(player_count: int, scale: float = 1.0) -> Vector2:
	if player_count <= 4:
		return Vector2(maxf(152.0 * scale, 112.0), maxf(78.0 * scale, 68.0))
	if player_count <= 8:
		return Vector2(maxf(136.0 * scale, 96.0), maxf(72.0 * scale, 62.0))
	return Vector2(maxf(118.0 * scale, 82.0), maxf(68.0 * scale, 58.0))

static func normalized_seat_positions(player_count: int, compact: bool = false, local_index: int = 0) -> Array[Vector2]:
	var count := clampi(player_count, 0, 12)
	var result: Array[Vector2] = []
	if count == 0:
		return result
	result.resize(count)
	var local := posmod(local_index, count)
	var radius := 0.45
	for player_index in range(count):
		var visual_offset := posmod(player_index - local, count)
		var angle := PI * 0.5 + TAU * float(visual_offset) / float(count)
		result[player_index] = Vector2(0.5 + cos(angle) * radius, 0.5 + sin(angle) * radius)
	return result
