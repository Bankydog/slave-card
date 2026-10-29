extends Control

const CARD_VIEW = preload("res://scripts/ui/card_view.gd")
const GameStateScript = preload("res://scripts/game/game_state.gd")
const BotBrainScript = preload("res://scripts/ai/bot_brain.gd")
const MultiplayerFlowScript = preload("res://scripts/ui/multiplayer_flow.gd")
const RoleSystemScript = preload("res://scripts/game/role_system.gd")
const CardExchangeScript = preload("res://scripts/game/card_exchange.gd")
const MatchStateScript = preload("res://scripts/game/match_state.gd")
const HandSorterScript = preload("res://scripts/cards/hand_sorter.gd")
const TablePresentationScript = preload("res://scripts/ui/table_presentation.gd")
const TITLE_TEXTURE = preload("res://assets/idle/title.png")
const TABLE_FOUR_TEXTURE = preload("res://assets/background/table-4.png")
const TABLE_MANY_TEXTURE = preload("res://assets/background/table-12.png")

var state
var bot := BotBrainScript.new()
var selected_card_ids: Array[String] = []
var bot_timer: Timer
var title_label: Label
var info_label: Label
var table_presentation: Control
var hand_box: HBoxContainer
var center_box: VBoxContainer
var buttons_box: HBoxContainer
var deck_info_label: Label
var multiplayer_flow: Control
var local_roles_by_player: Dictionary = {}
var match_progress = MatchStateScript.new()
var selected_match_round_limit := 4
var local_exchange
var local_phase := "playing"
var local_round_number := 0
var selected_exchange_ids: Array[String] = []
var previous_king_demoted := false
var next_round_starter := -1
var local_rps_players: Array[int] = []
var local_rps_round := 1
var local_rps_message := ""
var player_count := 4
var local_player_name := "Player"
var table_background: TextureRect

func _ready() -> void:
	table_background = get_node("TableBackground") as TextureRect
	multiplayer_flow = MultiplayerFlowScript.new()
	multiplayer_flow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	multiplayer_flow.single_player_requested.connect(_open_single_player_setup)
	add_child(multiplayer_flow)
	resized.connect(_refresh)

func _clear() -> void:
	if is_instance_valid(table_background):
		set_title_screen_enabled(true)
	for child in get_children():
		if child == multiplayer_flow or child == table_background:
			continue
		remove_child(child)
		child.queue_free()

func _open_single_player_setup() -> void:
	local_player_name = multiplayer_flow.get_display_name()
	multiplayer_flow.hide()
	_build_menu()

func _return_to_main_menu() -> void:
	_clear()
	multiplayer_flow.show()

func _build_menu() -> void:
	_clear()
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.96, 0.94, 0.88, 0.86)
	panel_style.border_color = Color(0.24, 0.16, 0.10, 0.95)
	panel_style.set_border_width_all(roundi(3.0 * _display_scale()))
	panel_style.set_corner_radius_all(roundi(18.0 * _display_scale()))
	panel_style.content_margin_left = 24.0 * _display_scale()
	panel_style.content_margin_right = 24.0 * _display_scale()
	panel_style.content_margin_top = 18.0 * _display_scale()
	panel_style.content_margin_bottom = 18.0 * _display_scale()
	panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(panel)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", roundi(12.0 * _display_scale()))
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(root)
	var heading := Label.new()
	heading.text = "Single Player"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", roundi(26.0 * _display_scale()))
	root.add_child(heading)
	var count_row := HBoxContainer.new()
	count_row.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(count_row)
	var count_value := Label.new()
	count_value.name = "PlayerCount"
	count_value.custom_minimum_size = Vector2(96, 56)
	count_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count_value.add_theme_font_size_override("font_size", roundi(28.0 * _display_scale()))
	var minus := Button.new()
	minus.text = "−"
	minus.custom_minimum_size = Vector2(56, 56) * _display_scale()
	minus.pressed.connect(_adjust_player_count.bind(-1, count_value))
	count_row.add_child(minus)
	count_row.add_child(count_value)
	var plus := Button.new()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(56, 56) * _display_scale()
	plus.pressed.connect(_adjust_player_count.bind(1, count_value))
	count_row.add_child(plus)
	deck_info_label = Label.new()
	deck_info_label.name = "DeckInfo"
	deck_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(deck_info_label)
	var match_row := HBoxContainer.new()
	match_row.alignment = BoxContainer.ALIGNMENT_CENTER
	match_row.add_theme_constant_override("separation", roundi(8.0 * _display_scale()))
	var rounds_label := Label.new()
	rounds_label.text = "Rounds"
	rounds_label.custom_minimum_size.x = 76.0 * _display_scale()
	rounds_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	match_row.add_child(rounds_label)
	for round_limit in MatchStateScript.ALLOWED_ROUND_LIMITS:
		var round_button := Button.new()
		round_button.text = str(round_limit)
		round_button.toggle_mode = true
		round_button.button_pressed = round_limit == selected_match_round_limit
		round_button.custom_minimum_size = Vector2(64.0, 48.0) * _display_scale()
		_style_round_choice(round_button, round_limit == selected_match_round_limit)
		round_button.pressed.connect(_select_match_round_limit.bind(round_limit))
		match_row.add_child(round_button)
	root.add_child(match_row)
	var start := Button.new()
	start.text = "Start Match"
	start.custom_minimum_size = Vector2(200, 58) * _display_scale()
	start.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	start.pressed.connect(_start_game)
	root.add_child(start)
	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(150, 48) * _display_scale()
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(_return_to_main_menu)
	root.add_child(back)
	_update_menu_count(count_value)
	_enforce_text_minimum(root)
	_style_menu_labels(root)

func _style_menu_labels(node: Node) -> void:
	if node is Label:
		(node as Label).add_theme_color_override("font_color", Color(0.12, 0.09, 0.07))
	for child in node.get_children():
		_style_menu_labels(child)

func _style_round_choice(button: Button, selected: bool) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.96, 0.94, 0.88) if selected else Color(0.12, 0.13, 0.16)
	normal.border_color = Color(0.18, 0.14, 0.10) if selected else Color(0.78, 0.76, 0.68)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(8)
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(1.0, 0.98, 0.92) if selected else Color(0.24, 0.26, 0.30)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", normal.duplicate())
	button.add_theme_stylebox_override("focus", normal.duplicate())
	button.add_theme_color_override("font_color", Color(0.08, 0.07, 0.06) if selected else Color(0.96, 0.95, 0.90))
	button.add_theme_color_override("font_hover_color", Color(0.08, 0.07, 0.06) if selected else Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color(0.08, 0.07, 0.06))

func _select_match_round_limit(round_limit: int) -> void:
	if not MatchStateScript.ALLOWED_ROUND_LIMITS.has(round_limit):
		return
	selected_match_round_limit = round_limit
	_build_menu()

func _adjust_player_count(delta: int, value: Label) -> void:
	player_count = clampi(player_count + delta, 2, 12)
	_update_menu_count(value)

func _update_menu_count(value: Label) -> void:
	value.text = str(player_count)
	if is_instance_valid(deck_info_label):
		deck_info_label.text = "Using %d standard deck%s" % [DeckFactory.deck_count_for_players(player_count), "" if player_count <= 6 else "s"]

func _start_game() -> void:
	local_roles_by_player.clear()
	local_round_number = 0
	next_round_starter = -1
	previous_king_demoted = false
	match_progress.begin(player_count, selected_match_round_limit)
	_start_local_round()

func _start_local_round() -> void:
	if match_progress.current_round >= match_progress.match_round_limit:
		return
	if not match_progress.advance_round():
		return
	SfxManager.play_shuffle()
	_clear()
	local_round_number = match_progress.current_round
	state = GameStateScript.new()
	state.changed.connect(_refresh)
	var round_starter := next_round_starter
	next_round_starter = -1
	state.start(player_count, 0, round_starter)
	state.players[0].name = local_player_name
	selected_card_ids.clear()
	for i in range(state.players.size()):
		state.players[i]["role"] = str(local_roles_by_player.get(i, ""))
	bot_timer = Timer.new()
	bot_timer.one_shot = true
	bot_timer.timeout.connect(_bot_move)
	add_child(bot_timer)
	local_exchange = null
	local_phase = "playing"
	selected_exchange_ids.clear()
	if local_round_number > 1:
		local_exchange = CardExchangeScript.new()
		var bot_flags: Array[bool] = []
		for i in range(player_count):
			bot_flags.append(i != 0)
		var exchange_result: Dictionary = local_exchange.begin(state.players, local_roles_by_player, bot_flags)
		if exchange_result.ok and (local_exchange.pending_amount_for(0) > 0 or not local_exchange.is_complete()):
			local_phase = "card_exchange"
	else:
		local_rps_players = state.three_clubs_holders()
		if local_rps_players.size() > 1:
			local_rps_round = 1
			local_rps_message = ""
			if local_rps_players.has(0):
				_show_local_rps()
				return
			var bot_winner := _local_bot_rps_winner()
			state.current_player = bot_winner
			state.turns.start_at(bot_winner, player_count)
	_build_table()
	_refresh()

func _show_local_rps() -> void:
	_clear_preserving_timer()
	set_game_background(player_count)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", roundi(10.0 * _display_scale()))
	add_child(root)
	var heading := Label.new()
	heading.text = local_rps_message if not local_rps_message.is_empty() else "Two players hold 3♣. Choose a card:"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(heading)
	var held_cards := HBoxContainer.new()
	held_cards.alignment = BoxContainer.ALIGNMENT_CENTER
	held_cards.add_theme_constant_override("separation", roundi(30.0 * _display_scale()))
	root.add_child(held_cards)
	for player_index in local_rps_players:
		var holder := VBoxContainer.new()
		holder.alignment = BoxContainer.ALIGNMENT_CENTER
		held_cards.add_child(holder)
		var back := TextureRect.new()
		back.texture = TablePresentationScript.rps_back_texture()
		back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		back.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		back.custom_minimum_size = Vector2(56.0, 78.0) * _display_scale()
		holder.add_child(back)
		var holder_label := Label.new()
		holder_label.text = "You" if player_index == 0 else str(state.players[player_index].name)
		holder_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		holder.add_child(holder_label)
	var options := HBoxContainer.new()
	options.alignment = BoxContainer.ALIGNMENT_CENTER
	options.add_theme_constant_override("separation", roundi(8.0 * _display_scale()))
	root.add_child(options)
	var choice_names := ["Rock", "Paper", "Scissors"]
	for choice in range(choice_names.size()):
		var column := VBoxContainer.new()
		column.alignment = BoxContainer.ALIGNMENT_CENTER
		options.add_child(column)
		var pick := TextureButton.new()
		pick.texture_normal = TablePresentationScript.rps_texture(choice)
		pick.ignore_texture_size = true
		pick.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		pick.custom_minimum_size = Vector2(76.0, 106.0) * _display_scale()
		pick.pressed.connect(_choose_local_rps.bind(choice))
		column.add_child(pick)
		var caption := Label.new()
		caption.text = choice_names[choice]
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(caption)

func _clear_preserving_timer() -> void:
	for child in get_children():
		if child == multiplayer_flow or child == table_background or child == bot_timer:
			continue
		remove_child(child)
		child.queue_free()

func _choose_local_rps(human_choice: int) -> void:
	var opponent := int(local_rps_players[1]) if int(local_rps_players[0]) == 0 else int(local_rps_players[0])
	var bot_choice: int = state.rng.randi_range(0, 2)
	var result := _rps_winner(human_choice, bot_choice)
	await _animate_local_rps_reveal(human_choice, bot_choice)
	if result < 0:
		local_rps_round += 1
		local_rps_message = "Tie! Choose again (round %d)." % local_rps_round
		_show_local_rps()
		return
	_finish_local_rps(0 if result == 0 else opponent)

func _animate_local_rps_reveal(human_choice: int, bot_choice: int) -> void:
	_clear_preserving_timer()
	set_game_background(player_count)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", roundi(8.0 * _display_scale()))
	add_child(root)
	var heading := Label.new()
	heading.text = "Rock · Paper · Scissors"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(heading)
	var cards := HBoxContainer.new()
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override("separation", roundi(36.0 * _display_scale()))
	root.add_child(cards)
	var faces: Array[TextureRect] = []
	for player_index in local_rps_players:
		var holder := VBoxContainer.new()
		holder.alignment = BoxContainer.ALIGNMENT_CENTER
		cards.add_child(holder)
		var face := TextureRect.new()
		face.texture = TablePresentationScript.rps_back_texture()
		face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		face.custom_minimum_size = Vector2(92.0, 128.0) * _display_scale()
		face.pivot_offset = face.custom_minimum_size * 0.5
		holder.add_child(face)
		faces.append(face)
		var label := Label.new()
		label.text = "You" if player_index == 0 else str(state.players[player_index].name)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		holder.add_child(label)
	var first_choice := human_choice if local_rps_players[0] == 0 else bot_choice
	var second_choice := bot_choice if local_rps_players[1] != 0 else human_choice
	var tween := create_tween()
	tween.tween_interval(0.1)
	tween.set_parallel(true)
	for face in faces:
		tween.tween_property(face, "scale:x", 0.0, 0.1).set_trans(Tween.TRANS_CUBIC)
	tween.set_parallel(false)
	tween.tween_callback(func():
		faces[0].texture = TablePresentationScript.rps_texture(first_choice)
		faces[1].texture = TablePresentationScript.rps_texture(second_choice)
	)
	tween.set_parallel(true)
	for face in faces:
		tween.tween_property(face, "scale:x", 1.0, 0.15).set_trans(Tween.TRANS_CUBIC)
	await tween.finished
	if not is_inside_tree():
		return
	if _rps_winner(first_choice, second_choice) < 0:
		heading.text = "Tie"
		await get_tree().create_timer(0.35).timeout

func _local_bot_rps_winner() -> int:
	while true:
		var result := _rps_winner(state.rng.randi_range(0, 2), state.rng.randi_range(0, 2))
		if result >= 0:
			return int(local_rps_players[result])
	return int(local_rps_players[0])

func _rps_winner(first_choice: int, second_choice: int) -> int:
	if first_choice == second_choice:
		return -1
	if (first_choice == 0 and second_choice == 2) or (first_choice == 1 and second_choice == 0) or (first_choice == 2 and second_choice == 1):
		return 0
	return 1

func _finish_local_rps(winner: int) -> void:
	state.current_player = winner
	state.turns.start_at(winner, player_count)
	local_rps_players.clear()
	local_rps_message = ""
	_clear_preserving_timer()
	_build_table()
	_refresh()

func _build_table() -> void:
	set_game_background(player_count)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", roundi((4.0 if _is_compact_view() else 10.0) * _display_scale()))
	add_child(root)
	var status_panel := PanelContainer.new()
	status_panel.name = "RoundStatusPanel"
	status_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	var hud_scale := _display_scale()
	status_panel.position = Vector2(16.0, 10.0) * hud_scale
	status_panel.size = Vector2(get_viewport_rect().size.x * 0.36, 40.0 * hud_scale)
	var status_style := StyleBoxFlat.new()
	status_style.bg_color = Color(0.05, 0.12, 0.10, 0.90)
	status_style.border_color = Color("#c9a958")
	status_style.set_border_width_all(1)
	status_style.set_corner_radius_all(6)
	status_style.content_margin_left = 8.0 * hud_scale
	status_style.content_margin_right = 8.0 * hud_scale
	status_style.content_margin_top = 3.0 * hud_scale
	status_style.content_margin_bottom = 3.0 * hud_scale
	status_panel.add_theme_stylebox_override("panel", status_style)
	add_child(status_panel)
	title_label = Label.new()
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_label.clip_text = true
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.add_theme_font_size_override("font_size", maxi(16, roundi(18.0 * hud_scale)))
	status_panel.add_child(title_label)
	_layout_round_status_panel()
	table_presentation = TablePresentationScript.new()
	table_presentation.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	table_presentation.size_flags_vertical = Control.SIZE_EXPAND_FILL
	table_presentation.custom_minimum_size.y = 120.0 * _display_scale()
	root.add_child(table_presentation)
	info_label = Label.new()
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(info_label)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.custom_minimum_size.y = minf(360.0 * _display_scale(), maxf(78.0, size.y * (0.22 if _is_compact_view() else 0.25)))
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	var hand_center := CenterContainer.new()
	hand_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(hand_center)
	hand_box = HBoxContainer.new()
	hand_box.alignment = BoxContainer.ALIGNMENT_CENTER
	hand_box.add_theme_constant_override("separation", roundi((-21.0 if _is_compact_view() else -29.0) * _display_scale()))
	hand_center.add_child(hand_box)
	var action_margin := MarginContainer.new()
	action_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_margin.add_theme_constant_override("margin_right", roundi(18.0 * _display_scale()))
	action_margin.add_theme_constant_override("margin_bottom", roundi(10.0 * _display_scale()))
	root.add_child(action_margin)
	var action_row := HBoxContainer.new()
	action_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_margin.add_child(action_row)
	var action_spacer := Control.new()
	action_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_row.add_child(action_spacer)
	buttons_box = HBoxContainer.new()
	buttons_box.alignment = BoxContainer.ALIGNMENT_END
	buttons_box.add_theme_constant_override("separation", roundi((5.0 if _is_compact_view() else 10.0) * _display_scale()))
	action_row.add_child(buttons_box)
	var play := Button.new()
	play.name = "PlayButton"
	play.text = "Play"
	play.custom_minimum_size = Vector2(104 if _is_compact_view() else 150, 48 if _is_compact_view() else 56) * _display_scale()
	play.pressed.connect(_play_selected)
	buttons_box.add_child(play)
	var pass_button := Button.new()
	pass_button.name = "PassButton"
	pass_button.text = "Pass"
	pass_button.custom_minimum_size = Vector2(104 if _is_compact_view() else 150, 48 if _is_compact_view() else 56) * _display_scale()
	pass_button.pressed.connect(_pass)
	buttons_box.add_child(pass_button)
	var exchange_button := Button.new()
	exchange_button.name = "ExchangeButton"
	exchange_button.text = "Return selected"
	exchange_button.custom_minimum_size = Vector2(154 if _is_compact_view() else 190, 48 if _is_compact_view() else 56) * _display_scale()
	exchange_button.pressed.connect(_submit_local_exchange)
	exchange_button.hide()
	buttons_box.add_child(exchange_button)
	var menu := Button.new()
	menu.text = "Menu"
	menu.custom_minimum_size = Vector2(88 if _is_compact_view() else 100, 48 if _is_compact_view() else 56) * _display_scale()
	menu.pressed.connect(_return_to_main_menu)
	buttons_box.add_child(menu)

func _layout_round_status_panel() -> void:
	if not is_instance_valid(title_label):
		return
	var panel := title_label.get_parent() as Control
	if not is_instance_valid(panel):
		return
	var hud_scale := _display_scale()
	panel.position = Vector2(16.0, 10.0) * hud_scale
	panel.size = Vector2(get_viewport_rect().size.x * 0.36, 40.0 * hud_scale)

func _refresh() -> void:
	if state == null or not is_instance_valid(hand_box):
		return
	_layout_round_status_panel()
	if local_phase == "results":
		return
	if state.finishing_order.size() == state.players.size():
		_finish_local_round()
		return
	if local_phase == "card_exchange":
		_refresh_local_exchange()
		return
	buttons_box.get_node("PlayButton").show()
	buttons_box.get_node("PassButton").show()
	buttons_box.get_node("ExchangeButton").hide()
	var current = state.players[state.current_player]
	title_label.text = "Round %d / %d  ·  %s" % [match_progress.current_round, match_progress.match_round_limit, "YOUR TURN" if current.is_human else "%s is thinking…" % current.name]
	var center_text := "Lead a combination"
	if not state.current_cards.is_empty():
		center_text = "%s · %s" % [str(state.current_combination.get("type", "Play")), str(state.players[state.last_player].name)]
	table_presentation.configure(state.players, 0, state.current_player, state.passed, state.current_cards, center_text, _is_compact_view(), state.last_player)
	for child in hand_box.get_children():
		child.queue_free()
	var human_hand: Array = state.players[0].hand
	var selectable: Dictionary = state.rules.selectable_card_ids(human_hand, state.current_cards, selected_card_ids)
	for card: CardData in human_hand:
		var card_id := card.card_id()
		var view = CARD_VIEW.new()
		view.setup(card, selected_card_ids.has(card_id), _is_compact_view(), _display_scale())
		view.disabled = not selected_card_ids.has(card_id) and not selectable.has(card_id)
		view.set_available(not view.disabled)
		view.pressed.connect(_toggle_play_card.bind(card_id))
		CARD_VIEW.add_hand_slot(hand_box, view, _is_compact_view(), _display_scale())
	info_label.text = "Cards: %d   •   Turn %d of %d" % [state.players[0].hand.size(), state.current_player + 1, state.players.size()]
	_enforce_text_minimum(self)
	if current.is_human:
		bot_timer.stop()
	else:
		bot_timer.start(0.8)

func _refresh_local_exchange() -> void:
	title_label.text = "Round %d / %d  ·  Card Exchange" % [match_progress.current_round, match_progress.match_round_limit]
	var amount: int = local_exchange.pending_amount_for(0)
	var role: String = local_exchange.role_for_player(0)
	var is_slave: bool = local_exchange.is_slave_participant(0)
	if is_slave:
		selected_exchange_ids = local_exchange.mandatory_ids_for(0)
	var target_role: String = _exchange_target_for_role(role)
	var notice_text := "Role: %s · Choose %d cards to give to %s\nSelected: %d / %d" % [role, amount, target_role, selected_exchange_ids.size(), amount]
	if is_slave:
		notice_text = "%s must give the %d highest cards. They are selected automatically." % [role, amount]
	table_presentation.configure(state.players, 0, state.current_player, state.passed, [], notice_text, _is_compact_view())
	for child in hand_box.get_children():
		child.queue_free()
	for card in state.players[0].hand:
		var view = CARD_VIEW.new()
		var selected := selected_exchange_ids.has(card.card_id())
		view.setup(card, selected, _is_compact_view(), _display_scale())
		view.set_available(true)
		if not is_slave:
			view.pressed.connect(_toggle_local_exchange_card.bind(card))
		CARD_VIEW.add_hand_slot(hand_box, view, _is_compact_view(), _display_scale())
	info_label.text = "Select exactly %d cards to return." % amount if not is_slave else "Mandatory cards are highlighted. You cannot replace them."
	bot_timer.stop()
	buttons_box.get_node("PlayButton").hide()
	buttons_box.get_node("PassButton").hide()
	var exchange_button: Button = buttons_box.get_node("ExchangeButton")
	exchange_button.show()
	exchange_button.disabled = amount <= 0 or selected_exchange_ids.size() != amount
	exchange_button.text = "Confirm Trade (%d/%d)" % [selected_exchange_ids.size(), amount]
	_enforce_text_minimum(self)

func _toggle_local_exchange_card(card: CardData) -> void:
	if local_exchange.is_slave_participant(0):
		return
	var id := card.card_id()
	if selected_exchange_ids.has(id):
		selected_exchange_ids.erase(id)
	else:
		selected_exchange_ids.append(id)
	SfxManager.play_card_select()
	_refresh_local_exchange()

func _submit_local_exchange() -> void:
	var amount: int = local_exchange.pending_amount_for(0)
	if selected_exchange_ids.size() != amount:
		info_label.text = "Select exactly %d cards." % amount
		return
	var result: Dictionary = local_exchange.select_return_cards(0, selected_exchange_ids, state.players)
	if not result.ok:
		info_label.text = str(result.error)
		return
	selected_exchange_ids.clear()
	if local_exchange.is_complete():
		local_phase = "playing"
	_refresh()

func _finish_local_round() -> void:
	var score_result: Dictionary = match_progress.record_round(state.finishing_order)
	if not score_result.ok:
		return
	var result: Dictionary = RoleSystemScript.resolve(state.finishing_order, state.players.size(), local_roles_by_player)
	if not result.ok:
		return
	local_roles_by_player = result.roles_by_player
	next_round_starter = state.finishing_order[0]
	previous_king_demoted = bool(result.previous_king_demoted)
	for i in range(state.players.size()):
		state.players[i]["role"] = str(local_roles_by_player.get(i, ""))
	local_phase = "results"
	_show_results()

func _toggle_play_card(card_id: String) -> void:
	if selected_card_ids.has(card_id):
		selected_card_ids.erase(card_id)
	else:
		selected_card_ids.append(card_id)
	SfxManager.play_card_select()
	_refresh()

func _play_selected() -> void:
	if selected_card_ids.is_empty():
		return
	var chosen: Array[CardData] = []
	for wanted_id in selected_card_ids:
		for card: CardData in state.players[0].hand:
			if card.card_id() == wanted_id:
				chosen.append(card)
				break
	var previous_selection: Array[String] = selected_card_ids.duplicate()
	selected_card_ids.clear()
	if not state.play_cards(0, chosen):
		selected_card_ids = previous_selection
		_refresh()

func _pass() -> void:
	selected_card_ids.clear()
	state.pass_turn(0)

func _bot_move() -> void:
	if state == null or state.players[state.current_player].is_human:
		return
	var hand: Array = state.players[state.current_player].hand
	var cards: Array = bot.choose_play(hand, state.current_cards, state.rules)
	if cards.is_empty():
		state.pass_turn(state.current_player)
	else:
		state.play_cards(state.current_player, cards)

func _show_results() -> void:
	if match_progress.current_round >= match_progress.match_round_limit:
		_show_final_match_result()
		return
	_clear()
	set_game_background(player_count)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", roundi((4.0 if _is_compact_view() else 10.0) * _display_scale()))
	add_child(root)
	var heading := Label.new()
	heading.text = "Round %d / %d Results" % [match_progress.current_round, match_progress.match_round_limit]
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", maxi(18, roundi(26.0 * _display_scale())))
	root.add_child(heading)
	var score_list := ScrollContainer.new()
	score_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	score_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	score_list.custom_minimum_size.y = 120.0 if _is_compact_view() else 250.0
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", roundi(4.0 * _display_scale()))
	score_list.add_child(rows)
	root.add_child(score_list)
	for place in range(state.finishing_order.size()):
		var player_index: int = state.finishing_order[place]
		var player = state.players[player_index]
		var role := str(local_roles_by_player.get(player_index, "%d%s" % [place + 1, _ordinal_suffix(place + 1)]))
		var row := Label.new()
		row.text = "%d. %s  +%d  Total %d  ·  %s" % [place + 1, player.name, match_progress.round_history.back().round_points[player_index], match_progress.match_scores[player_index], role]
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rows.add_child(row)
	if previous_king_demoted:
		var demotion := Label.new()
		demotion.text = "The previous King is now Slave 1."
		demotion.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(demotion)
	var trade_notice := Label.new()
	if state.players.size() < 3:
		trade_notice.text = "Next Round: King selects 2 cards for Slave 1. Trade starts when you continue."
	elif state.players.size() == 3:
		trade_notice.text = "Next Round: King selects 2 for Slave 1; Queen selects 1 for Slave 1."
	elif state.players.size() < 7:
		trade_notice.text = "Next Round: King selects 2 for Slave 1; Queen selects 1 for Slave 2."
	else:
		trade_notice.text = "Next Round: King, Queen, and Seven trade with their matching Slaves."
	trade_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	trade_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(trade_notice)
	var next_round := Button.new()
	next_round.text = "Next Round"
	next_round.custom_minimum_size = Vector2(200, 52) * _display_scale()
	next_round.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	next_round.pressed.connect(_start_local_round)
	root.add_child(next_round)
	var menu := Button.new()
	menu.text = "Main Menu"
	menu.custom_minimum_size = Vector2(180, 48) * _display_scale()
	menu.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	menu.pressed.connect(_return_to_main_menu)
	root.add_child(menu)
	_enforce_text_minimum(root)

func _show_final_match_result() -> void:
	_clear()
	set_game_background(player_count)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", roundi(6.0 * _display_scale()))
	add_child(root)
	var heading := Label.new()
	heading.text = "Final Result — %d Rounds" % match_progress.match_round_limit
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", maxi(20, roundi(28.0 * _display_scale())))
	root.add_child(heading)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", roundi(4.0 * _display_scale()))
	scroll.add_child(rows)
	root.add_child(scroll)
	var ranking := match_progress.ranked_player_indices()
	for place in range(ranking.size()):
		var player_index := ranking[place]
		var row := Label.new()
		row.text = "%d. %s  ·  Score %d  ·  1st %d  ·  2nd %d" % [place + 1, state.players[player_index].name, match_progress.match_scores[player_index], match_progress.first_place_counts[player_index], match_progress.second_place_counts[player_index]]
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if place == 0:
			row.add_theme_color_override("font_color", Color("#f3d78b"))
			row.add_theme_font_size_override("font_size", maxi(18, roundi(24.0 * _display_scale())))
		rows.add_child(row)
	var rematch := Button.new()
	rematch.text = "Rematch"
	rematch.custom_minimum_size = Vector2(180.0, 48.0) * _display_scale()
	rematch.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	rematch.pressed.connect(_start_game)
	root.add_child(rematch)
	var menu := Button.new()
	menu.text = "Back to Main Menu"
	menu.custom_minimum_size = Vector2(200.0, 48.0) * _display_scale()
	menu.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	menu.pressed.connect(_return_to_main_menu)
	root.add_child(menu)
	_enforce_text_minimum(root)

func set_game_background(players: int) -> void:
	if not is_instance_valid(table_background):
		return
	table_background.texture = TABLE_FOUR_TEXTURE if players >= 2 and players <= 4 else TABLE_MANY_TEXTURE
	table_background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	table_background.visible = true

func set_title_screen_enabled(enabled: bool) -> void:
	if not is_instance_valid(table_background):
		return
	if enabled:
		table_background.texture = TITLE_TEXTURE
		table_background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	else:
		table_background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	table_background.visible = enabled

func _display_scale() -> float:
	return CARD_VIEW.display_scale(get_viewport_rect().size)

func _is_compact_view() -> bool:
	return DisplayServer.window_get_size().y < 500

func _enforce_text_minimum(root: Node) -> void:
	_enforce_node_text_minimum(root)

func _enforce_node_text_minimum(node: Node) -> void:
	if node is BaseButton and node.get_script() != CARD_VIEW and not (node is Button and node.text == "Play") and not node.has_meta("sfx_wired"):
		node.pressed.connect(SfxManager.play_ui_click)
		node.set_meta("sfx_wired", true)
	if node is Label or node is Button or node is LineEdit:
		var control := node as Control
		control.add_theme_font_size_override("font_size", maxi(16, control.get_theme_font_size("font_size")))
	for child in node.get_children():
		_enforce_node_text_minimum(child)

func _exchange_target_for_role(role: String) -> String:
	match role:
		"King": return "Slave 1"
		"Queen": return "Slave 1" if player_count == 3 else "Slave 2"
		"Seven": return "Slave 3"
		"Slave 1": return "King"
		"Slave 2": return "Queen"
		"Slave 3": return "Seven"
		_: return "the paired player"

func _ordinal_suffix(n: int) -> String:
	if n % 100 in [11, 12, 13]:
		return "th"
	match n % 10:
		1: return "st"
		2: return "nd"
		3: return "rd"
		_: return "th"
