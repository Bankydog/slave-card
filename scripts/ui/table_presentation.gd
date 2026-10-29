extends Control

const CardViewScript = preload("res://scripts/ui/card_view.gd")
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
var center_pile: Control
var center_layer: CenterContainer
var center_group: VBoxContainer
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
	resized.connect(_layout_seats)
	_build_center_layer()
	play_flight_layer = Control.new()
	play_flight_layer.name = "PlayFlightLayer"
	play_flight_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	play_flight_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	play_flight_layer.z_index = 100
	add_child(play_flight_layer)

func configure(players: Array, local_index: int, current_player: int, passed: Array, cards: Array, center_text: String, compact: bool, played_by: int = -1) -> void:
	compact_view = compact
	local_seat_index = clampi(local_index, 0, maxi(0, players.size() - 1))
	layout_scale = CardViewScript.display_scale(get_viewport_rect().size)
	_ensure_seats(players.size())
	center_group.add_theme_constant_override("separation", roundi((2.0 if compact_view else 6.0) * layout_scale))
	center_group.custom_minimum_size.y = (104.0 if compact_view else 132.0) * layout_scale
	for i in range(players.size()):
		var player: Dictionary = players[i]
		var player_name := str(player.get("name", "Player %d" % (i + 1)))
		var role := str(player.get("role", ""))
		var card_count := int(player.get("card_count", player.get("hand", []).size()))
		name_labels[i].text = "%d · %s" % [i + 1, player_name]
		var details := "%d cards" % card_count
		role_icons[i].texture = role_texture(role)
		role_icons[i].visible = role_icons[i].texture != null; role_icons[i].custom_minimum_size = (Vector2(24, 20) if compact_view else Vector2(28, 24)) * layout_scale
		detail_labels[i].text = details
		var status := "WAITING"
		if bool(player.get("finished", false)):
			status = "FINISHED"
		elif i < passed.size() and bool(passed[i]):
			status = "PASSED"
		elif i == current_player:
			status = "YOUR TURN" if i == local_index else "TURN"
		status_labels[i].text = status
		_style_seat(seat_widgets[i], i == current_player and not bool(player.get("finished", false)), i == local_index)
	center_title.text = center_text
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
			center_pile = CardViewScript.make_pile(cards, compact_view, layout_scale)
			center_group.add_child(center_pile)
			center_pile.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if played_by >= 0 and played_by < players.size():
				if had_center_snapshot:
					SfxManager.play_card_play()
				if seats_can_animate():
					_start_card_flight(cards, played_by)
		center_title.add_theme_font_size_override("font_size", maxi(16, roundi(16.0 * layout_scale)))
	call_deferred("_layout_seats")

func seats_can_animate() -> bool:
	return not seat_widgets.is_empty() and is_instance_valid(play_flight_layer)

func _start_card_flight(cards: Array, played_by: int) -> void:
	if cards.is_empty() or played_by < 0 or played_by >= seat_widgets.size():
		return
	var animation_token := play_animation_id
	center_pile.modulate = Color(1.0, 1.0, 1.0, 0.0)
	await get_tree().process_frame
	if animation_token != play_animation_id or not is_inside_tree() or not is_instance_valid(center_pile):
		return
	var source_global := seat_widgets[played_by].get_global_rect().get_center()
	var source := play_flight_layer.get_global_transform().affine_inverse() * source_global
	
	var card_width := (42.0 if compact_view else 58.0) * layout_scale
	var card_height := (64.0 if compact_view else 92.0) * layout_scale
	var pile_cards: Control = center_pile.get_child(0)
	var stagger := 0.035
	var sound_duration := CARD_FLIP_SOUND.get_length()
	var flight_duration := maxf(0.1, sound_duration - stagger * float(cards.size() - 1))
	play_animation_tween = create_tween()
	play_animation_tween.set_parallel(true)
	for i in range(cards.size()):
		var flight_card = CardViewScript.new()
		flight_card.setup(cards[i], false, compact_view, layout_scale)
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
	center_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center_layer)
	center_group = VBoxContainer.new()
	center_group.name = "CenterGroup"
	center_group.alignment = BoxContainer.ALIGNMENT_CENTER
	center_group.add_theme_constant_override("separation", 4)
	center_group.custom_minimum_size.y = 132
	center_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center_layer.add_child(center_group)
	center_title = Label.new()
	center_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center_title.add_theme_color_override("font_color", Color("#f3e9cc"))
	center_title.add_theme_font_size_override("font_size", 16)
	center_group.add_child(center_title)

func _ensure_seats(count: int) -> void:
	if seat_widgets.size() == count and built_compact == compact_view:
		return
	built_compact = compact_view
	for child in get_children():
		if child != center_layer and child != play_flight_layer:
			remove_child(child)
			child.queue_free()
	seat_widgets.clear()
	name_labels.clear(); role_icons.clear()
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
		var name_row := HBoxContainer.new(); name_row.add_theme_constant_override("separation", 4); content.add_child(name_row); var player_name := Label.new()
		player_name.clip_text = true; player_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			
		player_name.add_theme_font_size_override("font_size", 16)
		player_name.add_theme_color_override("font_color", Color("#fff8e8"))
		player_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_row.add_child(player_name)
		var details_row := HBoxContainer.new()
		details_row.add_theme_constant_override("separation", 4)
		content.add_child(details_row)
		var details := Label.new()
		details.clip_text = true
		details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		details.add_theme_font_size_override("font_size", 16)
		details.add_theme_color_override("font_color", Color("#cbd9cb"))
		details.mouse_filter = Control.MOUSE_FILTER_IGNORE
		details_row.add_child(details)
		var role_icon := TextureRect.new()
		role_icon.name = "RoleIcon"
		role_icon.custom_minimum_size = Vector2(28, 24)
		role_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		role_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		role_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		role_icon.hide()
		details_row.add_child(role_icon)
		var status := Label.new()
		status.clip_text = true
		status.add_theme_font_size_override("font_size", 16)
		status.add_theme_color_override("font_color", Color("#f3d78b"))
		status.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(status)
		add_child(panel)
		seat_widgets.append(panel)
		name_labels.append(player_name); role_icons.append(role_icon)
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
	if seat_widgets.is_empty() or size.x <= 0.0 or size.y <= 0.0:
		return
	layout_scale = CardViewScript.display_scale(get_viewport_rect().size)
	var count := seat_widgets.size()
	var positions := normalized_seat_positions(count, compact_view, local_seat_index)
	var viewport_size := get_viewport_rect().size
	var global_origin := global_position
	if is_instance_valid(center_layer):
		var center_offset_y := viewport_size.y * 0.5 - global_origin.y - size.y * 0.5
		if count <= 4:
			center_offset_y -= viewport_size.y * 0.04
			if compact_view:
				center_offset_y -= viewport_size.y * 0.03
		center_layer.offset_top = center_offset_y
		center_layer.offset_bottom = center_offset_y
	var seat_width := (112.0 if compact_view else 144.0) * layout_scale if count == 4 else (112.0 if compact_view else 152.0) * layout_scale
	var seat_height := (66.0 if compact_view else 64.0) * layout_scale if count == 4 else (66.0 if compact_view else 78.0) * layout_scale
	var font_size := maxi(16, roundi(16.0 * layout_scale))
	for label in name_labels + detail_labels + status_labels:
		label.add_theme_font_size_override("font_size", font_size)
	for i in range(count):
		var panel := seat_widgets[i]
		var seat_size := Vector2(seat_width, seat_height)
		panel.custom_minimum_size = seat_size
		panel.size = seat_size
		var anchor: Vector2 = positions[i]
		var viewport_position := Vector2(anchor.x * viewport_size.x, anchor.y * viewport_size.y)
		panel.position = get_global_transform().affine_inverse() * viewport_position - seat_size * 0.5

static func _spread_x_positions(count: int, left: float, right: float) -> Array[float]:
	var result: Array[float] = []
	for i in range(count):
		result.append(0.5 if count == 1 else lerpf(left, right, float(i) / float(count - 1)))
	return result

static func normalized_seat_positions(player_count: int, compact: bool = false, local_index: int = 0) -> Array[Vector2]:
	var count := clampi(player_count, 0, 12)
	var result: Array[Vector2] = []
	if count == 0:
		return result
	result.resize(count)
	result[0] = Vector2(0.5, 0.86)
	var opponents := count - 1
	if count >= 2 and count <= 4:
		var top_seat_y := 0.14 if compact else 0.09
		var chair_positions: Array[Vector2] = [Vector2(0.5, 0.88), Vector2(0.1, 0.47), Vector2(0.5, top_seat_y), Vector2(0.9, 0.47)]
		var normalized_local_index := posmod(local_index, count)
		for i in range(count):
			var seat_offset := posmod(i - normalized_local_index, count)
			result[i] = chair_positions[seat_offset]
		return result
	if opponents == 0:
		return result
	if count <= 4:
		for i in range(opponents):
			var x := 0.5 if opponents == 1 else lerpf(0.22, 0.78, float(i) / float(opponents - 1))
			result[i + 1] = Vector2(x, 0.12)
		return result
	if compact and count >= 7:
		var side_count := 2 if count >= 10 else 0
		var compact_top_count := opponents - side_count - mini(3, opponents - side_count - 1)
		var compact_bottom_count := opponents - side_count - compact_top_count
		var top_xs := _spread_x_positions(compact_top_count, 0.08, 0.92)
		for i in range(compact_top_count):
			result[i + 1] = Vector2(top_xs[i], 0.12)
		var compact_slot_index := compact_top_count + 1
		if side_count == 2:
			result[compact_slot_index] = Vector2(0.03, 0.56)
			result[compact_slot_index + 1] = Vector2(0.97, 0.56)
			compact_slot_index += 2
		var bottom_xs: Array[float] = []
		match compact_bottom_count:
			1: bottom_xs = [0.86]
			2: bottom_xs = [0.15, 0.85]
			3:
					if side_count == 2:
						bottom_xs.append(0.21)
					else:
						bottom_xs.append(0.15)
					bottom_xs.append(0.36)
					bottom_xs.append(0.64)
			_: bottom_xs = _spread_x_positions(compact_bottom_count, 0.08, 0.92)
		for i in range(compact_bottom_count):
			result[compact_slot_index + i] = Vector2(bottom_xs[i], 0.70)
		return result
	if count <= 8:
		var gap := 0.82
		var start := PI * 0.5 + gap * 0.5
		for i in range(opponents):
			var angle := start + float(i) * (TAU - gap) / float(opponents - 1)
			result[i + 1] = Vector2(0.5 + 0.45 * cos(angle), 0.5 + 0.34 * sin(angle))
		return result
	var side_slots: Array[Vector2] = [Vector2(0.045, 0.47), Vector2(0.955, 0.47)]
	var top_count := mini(5, opponents - 4)
	var top_slots: Array[Vector2] = []
	for i in range(top_count):
		top_slots.append(Vector2(lerpf(0.10, 0.90, float(i) / float(maxi(1, top_count - 1))), 0.09))
	var bottom_count := opponents - top_count - side_slots.size()
	var bottom_slots: Array[Vector2] = []
	for i in range(bottom_count):
		bottom_slots.append(Vector2(lerpf(0.15, 0.85, float(i) / float(maxi(1, bottom_count - 1))), 0.75))
	var slot_index := 1
	for slot in top_slots:
		result[slot_index] = slot
		slot_index += 1
	for slot in side_slots:
		result[slot_index] = slot
		slot_index += 1
	for slot in bottom_slots:
		result[slot_index] = slot
		slot_index += 1
	return result
