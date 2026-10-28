extends Control

const CARD_VIEW = preload("res://scripts/ui/card_view.gd")
const GameStateScript = preload("res://scripts/game/game_state.gd")
const BotBrainScript = preload("res://scripts/ai/bot_brain.gd")
const MultiplayerFlowScript = preload("res://scripts/ui/multiplayer_flow.gd")
const RoleSystemScript = preload("res://scripts/game/role_system.gd")
const CardExchangeScript = preload("res://scripts/game/card_exchange.gd")
const HandSorterScript = preload("res://scripts/cards/hand_sorter.gd")
const TablePresentationScript = preload("res://scripts/ui/table_presentation.gd")

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
var local_exchange
var local_phase := "playing"
var local_round_number := 0
var selected_exchange_ids: Array[String] = []
var previous_king_demoted := false
var next_round_starter := -1
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
		table_background.hide()
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
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", roundi(18.0 * _display_scale()))
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(root)
	var title := Label.new()
	title.text = "SLAVE CARD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", roundi(38.0 * _display_scale()))
	root.add_child(title)
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
	var start := Button.new()
	start.text = "Start Game"
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
	_start_local_round()

func _start_local_round() -> void:
	_clear()
	local_round_number += 1
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
	_build_table()
	_refresh()

func _build_table() -> void:
	set_table_background_enabled(player_count == 4)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", roundi((4.0 if _is_compact_view() else 10.0) * _display_scale()))
	add_child(root)
	title_label = Label.new()
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title_label)
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
	buttons_box = HBoxContainer.new()
	buttons_box.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(buttons_box)
	var play := Button.new()
	play.name = "PlayButton"
	play.text = "Play"
	play.custom_minimum_size = Vector2(150, 48 if _is_compact_view() else 56) * _display_scale()
	play.pressed.connect(_play_selected)
	buttons_box.add_child(play)
	var pass_button := Button.new()
	pass_button.name = "PassButton"
	pass_button.text = "Pass"
	pass_button.custom_minimum_size = Vector2(150, 48 if _is_compact_view() else 56) * _display_scale()
	pass_button.pressed.connect(_pass)
	buttons_box.add_child(pass_button)
	var exchange_button := Button.new()
	exchange_button.name = "ExchangeButton"
	exchange_button.text = "Return selected"
	exchange_button.custom_minimum_size = Vector2(190, 48 if _is_compact_view() else 56) * _display_scale()
	exchange_button.pressed.connect(_submit_local_exchange)
	exchange_button.hide()
	buttons_box.add_child(exchange_button)
	var menu := Button.new()
	menu.text = "Menu"
	menu.custom_minimum_size = Vector2(100, 48 if _is_compact_view() else 56) * _display_scale()
	menu.pressed.connect(_return_to_main_menu)
	buttons_box.add_child(menu)

func _refresh() -> void:
	if state == null or not is_instance_valid(hand_box):
		return
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
	title_label.text = "YOUR TURN" if current.is_human else "%s is thinking…" % current.name
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
	title_label.text = "Card Exchange  ·  Round %d" % local_round_number
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
	_clear()
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", roundi((8.0 if _is_compact_view() else 12.0) * _display_scale()))
	add_child(root)
	var heading := Label.new()
	heading.text = "Round %d Results" % local_round_number
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 30)
	root.add_child(heading)
	for place in range(state.finishing_order.size()):
		var player_index: int = state.finishing_order[place]
		var player = state.players[player_index]
		var role := str(local_roles_by_player.get(player_index, "%d%s" % [place + 1, _ordinal_suffix(place + 1)]))
		var line := Label.new()
		line.text = "%s  —  %s" % [role, player.name]
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(line)
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
	next_round.text = "Next Round · Card Trade"
	next_round.custom_minimum_size = Vector2(200, 56) * _display_scale()
	next_round.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	next_round.pressed.connect(_start_local_round)
	root.add_child(next_round)
	var menu := Button.new()
	menu.text = "Main Menu"
	menu.custom_minimum_size = Vector2(180, 52) * _display_scale()
	menu.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	menu.pressed.connect(_return_to_main_menu)
	root.add_child(menu)
	_enforce_text_minimum(root)

func set_table_background_enabled(enabled: bool) -> void:
	if is_instance_valid(table_background):
		table_background.visible = enabled

func _display_scale() -> float:
	return CARD_VIEW.display_scale(get_viewport_rect().size)

func _is_compact_view() -> bool:
	return DisplayServer.window_get_size().y < 500

func _enforce_text_minimum(root: Node) -> void:
	_enforce_node_text_minimum(root)

func _enforce_node_text_minimum(node: Node) -> void:
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