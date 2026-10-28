extends Control

const ClientEndpointScript = preload("res://scripts/network/client_network_endpoint.gd")
const Protocol = preload("res://scripts/network/network_protocol.gd")
const CardDataScript = preload("res://scripts/cards/card_data.gd")
const HandSorterScript = preload("res://scripts/cards/hand_sorter.gd")
const GameRulesScript = preload("res://scripts/game/game_rules.gd")
const CardViewScript = preload("res://scripts/ui/card_view.gd")
const TablePresentationScript = preload("res://scripts/ui/table_presentation.gd")

signal single_player_requested

var endpoint: ClientNetworkEndpoint
var page := "main"
var guest_name := "Guest"
const PROFILE_PATH := "user://player_settings.cfg"
const DESKTOP_SERVER_URL := "ws://127.0.0.1:10000"
const WEB_SERVER_URL := "wss://slave-card-server.onrender.com"
const SERVER_URL_CONFIG_PATH := "res://config/server_url.cfg"
var server_url := DESKTOP_SERVER_URL
var room_code := ""
var room_max_players := 8
var room_players: Array = []
var lobby_all_ready := false
var lobby_ready_count := 0
var lobby_human_count := 0
var is_host := false
var local_player_index := -1
var online_player_index := -1
var online_round := 0
var online_phase := "lobby"
var online_players: Array = []
var online_hand: Array[CardData] = []
var online_rules := GameRulesScript.new()
var online_roles: Dictionary = {}
var online_snapshot: Dictionary = {}
var online_center_card_ids: Array[String] = []
var return_card_count := 0
var selected_card_ids: Array[String] = []
var exchange_role := ""
var exchange_mandatory_ids: Array[String] = []
var exchange_readiness: Dictionary = {}
var exchange_participant := false
var pending_request: Dictionary = {}
var status_text := ""

var name_input: LineEdit
var server_input: LineEdit
var room_code_input: LineEdit
var status_label: Label

func _ready() -> void:
	name = "MultiplayerFlow"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	endpoint = ClientEndpointScript.new()
	endpoint.name = "NetworkEndpoint"
	add_child(endpoint)
	endpoint.message_received.connect(_on_server_message)
	endpoint.connection_status_changed.connect(_on_connection_status)
	var profile := ConfigFile.new()
	if profile.load(PROFILE_PATH) == OK:
		guest_name = str(profile.get_value("profile", "display_name", "Guest"))
	server_url = WEB_SERVER_URL if OS.has_feature("web") else DESKTOP_SERVER_URL
	if not OS.has_feature("web"):
		var server_config := ConfigFile.new()
		if server_config.load(SERVER_URL_CONFIG_PATH) == OK:
			var configured_url := str(server_config.get_value("network", "server_url", DESKTOP_SERVER_URL)).strip_edges()
			if not configured_url.is_empty():
				server_url = configured_url
	_show_main_menu()

func _clear_screen() -> void:
	var host := get_parent()
	if host.has_method("set_table_background_enabled"):
		host.set_table_background_enabled(false)
	for child in get_children():
		if child != endpoint:
			remove_child(child)
			child.queue_free()

func _display_scale() -> float:
	return CardViewScript.display_scale(get_viewport_rect().size)

func _is_compact_view() -> bool:
	return DisplayServer.window_get_size().y < 500

func _update_lobby_grid_columns(grid: GridContainer) -> void:
	if not is_instance_valid(grid):
		return
	var width := get_viewport_rect().size.x
	if width >= 1100.0:
		grid.columns = 4
	elif width >= 700.0 and not _is_compact_view():
		grid.columns = 3
	else:
		grid.columns = 2

func _set_guest_name(value: String) -> void:
	guest_name = value
	var profile := ConfigFile.new()
	profile.set_value("profile", "display_name", value)
	profile.save(PROFILE_PATH)

func _set_room_code(value: String) -> void:
	var normalized := value.strip_edges().to_upper()
	room_code = normalized
	if is_instance_valid(room_code_input) and room_code_input.text != normalized:
		var caret_column := room_code_input.caret_column
		room_code_input.text = normalized
		room_code_input.caret_column = mini(caret_column, normalized.length())

func get_display_name() -> String:
	return _effective_guest_name()

func _root_box(title_text: String) -> VBoxContainer:
	_clear_screen()
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", roundi((4.0 if _is_compact_view() else 12.0) * _display_scale()))
	add_child(root)
	var heading := Label.new()
	heading.text = title_text
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.custom_minimum_size.y = 36.0 * _display_scale()
	heading.add_theme_font_size_override("font_size", maxi(16, roundi((22.0 if _is_compact_view() else 32.0) * _display_scale())))
	root.add_child(heading)
	return root

func _line_edit(parent: Control, value: String, hint: String, changed: Callable) -> LineEdit:
	var edit := LineEdit.new()
	edit.text = value
	edit.placeholder_text = hint
	edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	edit.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	edit.custom_minimum_size = Vector2(240, 40 if _is_compact_view() else 48) * _display_scale()
	edit.add_theme_font_size_override("font_size", maxi(16, roundi(16.0 * _display_scale())))
	edit.text_changed.connect(changed)
	edit.gui_input.connect(_on_line_edit_gui_input.bind(edit))
	parent.add_child(edit)
	return edit

func _on_line_edit_gui_input(event: InputEvent, edit: LineEdit) -> void:
	if not OS.has_feature("web") or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo or key_event.keycode != KEY_V:
		return
	if not key_event.ctrl_pressed and not key_event.meta_pressed:
		return
	# Let LineEdit/browser handling run first. If it did not insert anything, use
	# Godot's clipboard bridge while this specific LineEdit still has focus.
	call_deferred("_paste_clipboard_fallback", edit, edit.text)

func _paste_clipboard_fallback(edit: LineEdit, original_text: String) -> void:
	if not is_instance_valid(edit) or not edit.has_focus() or edit.text != original_text:
		return
	var clipboard_text := DisplayServer.clipboard_get()
	if not clipboard_text.is_empty():
		edit.insert_text_at_caret(clipboard_text)

func _labeled_line_edit(parent: Control, label_text: String, value: String, hint: String, changed: Callable) -> LineEdit:
	var label := Label.new()
	label.name = "%sLabel" % label_text
	label.text = label_text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size.x = 240.0 * _display_scale()
	label.add_theme_font_size_override("font_size", maxi(16, roundi(16.0 * _display_scale())))
	parent.add_child(label)
	var edit := _line_edit(parent, value, hint, changed)
	edit.name = "%sInput" % label_text
	return edit

func _action_button(parent: Control, text_value: String, action: Callable, width: int = 240) -> Button:
	var button := Button.new()
	button.name = "Action_%s" % text_value.replace(" ", "")
	button.text = text_value
	button.custom_minimum_size = Vector2(width, 42 if _is_compact_view() else 52) * _display_scale()
	button.add_theme_font_size_override("font_size", maxi(16, roundi(16.0 * _display_scale())))
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _status(parent: Control) -> void:
	if status_text.is_empty():
		status_label = null
		return
	status_label = Label.new()
	status_label.text = status_text
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(status_label)

func _show_main_menu() -> void:
	page = "main"
	var root := _root_box("SLAVE CARD")
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)
	_labeled_line_edit(root, "Name", guest_name, "Guest name", _set_guest_name)
	_action_button(root, "Single Player", func(): single_player_requested.emit())
	_action_button(root, "Create Room", _show_create_room)
	_action_button(root, "Join Room", _show_join_room)
	_status(root)
	var bottom := Control.new()
	bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(bottom)
	_enforce_text_minimum(root)

func _show_create_room() -> void:
	page = "create"
	status_text = ""
	var root := _root_box("Create Room")
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(row)
	var minus := Button.new()
	minus.text = "−"
	minus.custom_minimum_size = Vector2(56, 48)
	minus.pressed.connect(func(): room_max_players = maxi(2, room_max_players - 1); _show_create_room())
	row.add_child(minus)
	var count := Label.new()
	count.text = "%d players max" % room_max_players
	count.custom_minimum_size = Vector2(190, 48)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(count)
	var plus := Button.new()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(56, 48)
	plus.pressed.connect(func(): room_max_players = mini(12, room_max_players + 1); _show_create_room())
	row.add_child(plus)
	_action_button(root, "Create Room", func(): _send_request(Protocol.CREATE_ROOM, {"name": _effective_guest_name(), "max_players": room_max_players}))
	_action_button(root, "Back", _show_main_menu, 150)
	_status(root)
	_enforce_text_minimum(root)

func _show_join_room() -> void:
	page = "join"
	status_text = ""
	var root := _root_box("Join Room")
	_labeled_line_edit(root, "Name", guest_name, "Guest name", _set_guest_name)
	room_code_input = _line_edit(root, room_code, "6-character room code", _set_room_code)
	_action_button(root, "Join Room", func(): _send_request(Protocol.JOIN_ROOM, {"name": _effective_guest_name(), "room_code": room_code.to_upper()}))
	_action_button(root, "Back", _show_main_menu, 150)
	_status(root)
	_enforce_text_minimum(root)

func _show_lobby() -> void:
	page = "lobby"
	var root := _root_box("Room Lobby")
	var code_label := Label.new()
	code_label.text = "ROOM CODE   %s" % room_code
	code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_label.add_theme_font_size_override("font_size", 26)
	root.add_child(code_label)
	var count_label := Label.new()
	count_label.text = "%d / %d connected" % [room_players.size(), room_max_players]
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(count_label)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 80 if _is_compact_view() else 220
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var centered := CenterContainer.new()
	centered.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centered.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(centered)
	var grid := GridContainer.new()
	grid.name = "LobbyPlayerGrid"
	grid.add_theme_constant_override("h_separation", roundi(12.0 * _display_scale()))
	grid.add_theme_constant_override("v_separation", roundi(10.0 * _display_scale()))
	centered.add_child(grid)
	root.add_child(scroll)
	_update_lobby_grid_columns(grid)
	scroll.resized.connect(_update_lobby_grid_columns.bind(grid))
	for player in room_players:
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(220.0, 54.0) * _display_scale()
		var card_content := Control.new()
		card_content.custom_minimum_size = card.custom_minimum_size
		card_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
		card.add_child(card_content)
		var centered_name := CenterContainer.new()
		centered_name.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var line := Label.new()
		var badge := "Host" if bool(player.get("is_host", false)) else ("Bot" if bool(player.get("is_bot", false)) else "Guest")
		line.text = "%s  ·  %s" % [str(player.get("name", "Guest")), badge]
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line.add_theme_font_size_override("font_size", maxi(16, roundi(18.0 * _display_scale())))
		centered_name.add_child(line)
		card_content.add_child(centered_name)
		if bool(player.get("ready", false)):
			var ready_icon := TextureRect.new()
			ready_icon.name = "ReadyIcon"
			ready_icon.texture = load("res://assets/gadget/check.png")
			ready_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			ready_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			var icon_size := 24.0 * _display_scale()
			var icon_margin := 6.0 * _display_scale()
			ready_icon.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
			ready_icon.offset_left = -icon_size - icon_margin
			ready_icon.offset_top = icon_margin
			ready_icon.offset_right = -icon_margin
			ready_icon.offset_bottom = icon_size + icon_margin
			card_content.add_child(ready_icon)
		grid.add_child(card)
	var ready_summary := Label.new()
	ready_summary.text = "Ready %d / %d" % [lobby_ready_count, lobby_human_count]
	ready_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(ready_summary)
	var local_ready := local_player_index >= 0 and local_player_index < room_players.size() and bool(room_players[local_player_index].get("ready", false))
	_action_button(root, "Cancel Ready" if local_ready else "Ready", func(): _send_request(Protocol.SET_READY, {"ready": not local_ready}))
	if is_host:
		var fill_bots := CheckBox.new()
		fill_bots.text = "Fill empty seats with bots"
		fill_bots.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		root.add_child(fill_bots)
		var start_button := _action_button(root, "Start Game", func(): _send_request(Protocol.START_GAME, {"fill_bots": fill_bots.button_pressed}))
		start_button.disabled = not lobby_all_ready
	else:
		var waiting := Label.new()
		waiting.text = "Waiting for the host to start"
		waiting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(waiting)
	_action_button(root, "Leave Room", _leave_room, 170)
	_status(root)
	_enforce_text_minimum(root)

func _show_online_game() -> void:
	page = "game"
	var trading := online_phase == "card_exchange"
	if trading and exchange_role.begins_with("Slave ") and selected_card_ids.is_empty():
		selected_card_ids = exchange_mandatory_ids.duplicate()
	HandSorterScript.sort_hand(online_hand)
	var title_text := "Round %d  ·  %s" % [online_round, "Card Exchange" if trading else "Playing"]
	var root := _root_box(title_text)
	var host := get_parent()
	if host.has_method("set_table_background_enabled"):
		host.set_table_background_enabled(online_players.size() == 4)
	var current_cards: Array[CardData] = []
	var serialized_cards: Array = online_snapshot.get("current_cards", [])
	if serialized_cards.is_empty() and not online_snapshot.get("current_card", {}).is_empty():
		serialized_cards = [online_snapshot.current_card]
	for card_data in serialized_cards:
		current_cards.append(CardDataScript.from_dict(card_data))
	var combination: Dictionary = online_snapshot.get("combination", {})
	var center_text := "Lead a combination"
	if not current_cards.is_empty():
		center_text = "%s · %s" % [str(combination.get("type", "Play")), str(online_snapshot.get("last_player_name", "Last player"))]
	var passed: Array = []
	for player in online_players:
		passed.append(bool(player.get("passed", false)))
	var next_center_ids: Array[String] = []
	for card: CardData in current_cards:
		next_center_ids.append(card.card_id())
	var animation_player := -1
	if next_center_ids != online_center_card_ids:
		if not next_center_ids.is_empty():
			animation_player = int(online_snapshot.get("last_player", -1))
		online_center_card_ids = next_center_ids.duplicate()
	var table_view: Control = TablePresentationScript.new()
	table_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	table_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	table_view.custom_minimum_size.y = 120.0 * _display_scale()
	root.add_child(table_view)
	table_view.configure(online_players, online_player_index, int(online_snapshot.get("current_player", -1)), passed, current_cards, center_text, _is_compact_view(), animation_player)

	var info := Label.new()
	info.name = "TradeInfo" if trading else "GameInfo"
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if trading:
		if exchange_role == "King":
			info.text = "Role: King · Choose %d cards to give to Slave 1\nSelected: %d / %d" % [return_card_count, selected_card_ids.size(), return_card_count]
		elif exchange_role == "Queen":
			info.text = "Role: Queen · Choose %d cards to give to Slave 2\nSelected: %d / %d" % [return_card_count, selected_card_ids.size(), return_card_count]
		elif exchange_role == "Seven":
			info.text = "Role: Seven · Choose %d card(s) to give to Slave 3\nSelected: %d / %d" % [return_card_count, selected_card_ids.size(), return_card_count]
		elif exchange_role.begins_with("Slave "):
			var upper_role := "King/Queen" if exchange_role == "Slave 1" and online_players.size() == 3 else ("Queen" if exchange_role == "Slave 2" else ("Seven" if exchange_role == "Slave 3" else "King"))
			info.text = "%s: waiting to receive %d card(s) from %s." % [exchange_role, exchange_mandatory_ids.size(), upper_role]
		else:
			info.text = "Waiting for card exchange..."
	else:
		if int(online_snapshot.get("current_player", -1)) == online_player_index:
			info.text = "Your turn"
		else:
			var current_index := int(online_snapshot.get("current_player", -1))
			var current_name := "the current player"
			if current_index >= 0 and current_index < online_players.size():
				current_name = str(online_players[current_index].get("name", current_name))
			info.text = "Waiting for %s" % current_name
	root.add_child(info)

	if trading:
		_add_trade_progress(root)
		if not exchange_participant or _trade_is_ready(exchange_role):
			var waiting := Label.new()
			waiting.name = "TradeWaiting"
			if not exchange_participant:
				waiting.text = "Waiting Trade"
			elif exchange_role.begins_with("Slave "):
				var upper_role := "King/Queen" if exchange_role == "Slave 1" and online_players.size() == 3 else ("Queen" if exchange_role == "Slave 2" else ("Seven" if exchange_role == "Slave 3" else "King"))
				waiting.text = "Waiting for %s to choose cards..." % upper_role
			else:
				waiting.text = "Waiting Trade"
			waiting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			root.add_child(waiting)
			_status(root)
			_enforce_text_minimum(root)
			return

	var hand_scroll := ScrollContainer.new()
	hand_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	hand_scroll.custom_minimum_size.y = minf(280.0 * _display_scale(), maxf(78.0, size.y * (0.24 if _is_compact_view() else 0.28)))
	hand_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hand_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(hand_scroll)
	var hand_center := CenterContainer.new()
	hand_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hand_scroll.add_child(hand_center)
	var hand_row := HBoxContainer.new()
	hand_row.alignment = BoxContainer.ALIGNMENT_CENTER
	hand_row.add_theme_constant_override("separation", roundi((-21.0 if _is_compact_view() else -29.0) * _display_scale()))
	hand_center.add_child(hand_row)
	var selectable: Dictionary = {}
	if trading:
		if exchange_role.begins_with("Slave "):
			for id in exchange_mandatory_ids:
				selectable[id] = true
		else:
			for card in online_hand:
				selectable[card.card_id()] = true
	else:
		selectable = online_rules.selectable_card_ids(online_hand, current_cards, selected_card_ids)
	for card in online_hand:
		var card_id := card.card_id()
		var card_button = CardViewScript.new()
		var selected := selected_card_ids.has(card_id)
		card_button.setup(card, selected, _is_compact_view(), _display_scale())
		card_button.disabled = not selected and not selectable.has(card_id)
		card_button.set_available(not card_button.disabled)
		if not (trading and exchange_role.begins_with("Slave ")):
			card_button.pressed.connect(_toggle_card.bind(card_id))
		CardViewScript.add_hand_slot(hand_row, card_button, _is_compact_view(), _display_scale())

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(buttons)
	if trading:
		var return_button := Button.new()
		return_button.name = "ConfirmTradeButton"
		return_button.text = "Confirm Trade (%d/%d)" % [selected_card_ids.size(), return_card_count]
		return_button.custom_minimum_size = Vector2(220, 48 if _is_compact_view() else 56) * _display_scale()
		return_button.disabled = return_card_count <= 0 or selected_card_ids.size() != return_card_count
		return_button.pressed.connect(_submit_exchange)
		buttons.add_child(return_button)
	else:
		var play_button := Button.new()
		play_button.text = "Play"
		play_button.custom_minimum_size = Vector2(140, 48 if _is_compact_view() else 56) * _display_scale()
		play_button.disabled = selected_card_ids.is_empty() or int(online_snapshot.get("current_player", -1)) != online_player_index
		play_button.pressed.connect(_submit_play)
		buttons.add_child(play_button)
		var pass_button := Button.new()
		pass_button.text = "Pass"
		pass_button.custom_minimum_size = Vector2(140, 48 if _is_compact_view() else 56) * _display_scale()
		pass_button.pressed.connect(func(): _send_request(Protocol.PASS, {}))
		buttons.add_child(pass_button)
	_status(root)
	_enforce_text_minimum(root)

func _add_trade_progress(parent: Control) -> void:
	var progress := HBoxContainer.new()
	progress.alignment = BoxContainer.ALIGNMENT_CENTER
	progress.add_theme_constant_override("separation", roundi(8.0 * _display_scale()))
	parent.add_child(progress)
	var roles: Array[String] = ["King", "Slave 1"]
	if online_players.size() >= 7:
		roles = ["King", "Queen", "Seven", "Slave 1", "Slave 2", "Slave 3"]
	elif online_players.size() >= 4:
		roles = ["King", "Queen", "Slave 1", "Slave 2"]
	elif online_players.size() == 3:
		roles = ["King", "Queen", "Slave 1"]
	for role in roles:
		var label := Label.new()
		label.name = "TradeStatus_%s" % role.replace(" ", "")
		label.text = "%s: %s" % [role, str(exchange_readiness.get(role, "Selecting"))]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		progress.add_child(label)

func _trade_is_ready(role: String) -> bool:
	return str(exchange_readiness.get(role, "")) == "Ready"

func _trade_is_role(role: String) -> bool:
	return role in ["King", "Queen", "Seven", "Slave 1", "Slave 2", "Slave 3"]

func _show_results(payload: Dictionary) -> void:
	page = "results"
	online_roles = payload.get("roles_by_player", online_roles)
	var root := _root_box("Round %d Results" % online_round)
	var heading := Label.new()
	heading.text = "Finishing order"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(heading)
	var order: Array = payload.get("finishing_order", [])
	for place in range(order.size()):
		var player_index := int(order[place])
		var player_name := "Player %d" % (player_index + 1)
		if player_index < online_players.size():
			player_name = str(online_players[player_index].get("name", player_name))
		var role := _role_for(player_index)
		var line := Label.new()
		line.text = "%s  —  %s" % [role, player_name]
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(line)
	if bool(payload.get("previous_king_demoted", false)):
		var demotion := Label.new()
		demotion.text = "The previous King is now Slave 1."
		demotion.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(demotion)
	var trade_notice := Label.new()
	if online_players.size() < 3:
		trade_notice.text = "Next round: King returns 2 cards to Slave 1."
	elif online_players.size() == 3:
		trade_notice.text = "Next round: King returns 2 cards to Slave 1; Queen returns 1 card to Slave 1."
	elif online_players.size() < 7:
		trade_notice.text = "Next round: King returns 2 cards to Slave 1; Queen returns 1 card to Slave 2."
	else:
		trade_notice.text = "Next round: King, Queen, and Seven trade with their matching Slaves."
	trade_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	trade_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(trade_notice)
	if is_host:
		_action_button(root, "Start Next Round · Card Trade", func(): _send_request(Protocol.START_NEXT_ROUND, {}))
	else:
		var wait := Label.new()
		wait.text = "Waiting for the host to start the next round"
		wait.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(wait)
	_action_button(root, "Leave Room", _leave_room, 170)
	_status(root)
	_enforce_text_minimum(root)

func _send_request(message_type: String, payload: Dictionary) -> void:
	status_text = "Connecting to room server…"
	if endpoint.connected:
		endpoint.send_intent(message_type, payload)
		return
	pending_request = {"type": message_type, "payload": payload.duplicate(true)}
	var error: Error = endpoint.connect_to_server(server_url.strip_edges())
	if error != OK:
		status_text = "Could not start the WebSocket connection."
		_refresh_current_page()

func _on_connection_status(connected: bool, reason: String) -> void:
	if connected:
		status_text = ""
		if not pending_request.is_empty():
			endpoint.send_intent(str(pending_request.type), pending_request.payload)
			pending_request.clear()
	else:
		status_text = reason
		_refresh_current_page()

func _on_server_message(message: Dictionary) -> void:
	var message_type := str(message.get("type", ""))
	var payload: Dictionary = message.get("payload", {})
	if message_type != Protocol.ACTION_REJECTED:
		status_text = ""
	match message_type:
		Protocol.ROOM_CREATED:
			room_code = str(payload.get("room_code", ""))
			room_max_players = int(payload.get("max_players", room_max_players))
			is_host = true
		Protocol.LOBBY_STATE:
			room_code = str(payload.get("room_code", room_code))
			room_max_players = int(payload.get("max_players", room_max_players))
			room_players = payload.get("players", [])
			local_player_index = int(payload.get("your_player_index", -1))
			is_host = bool(payload.get("is_host", is_host))
			lobby_all_ready = bool(payload.get("all_ready", false))
			lobby_ready_count = int(payload.get("ready_count", 0))
			lobby_human_count = int(payload.get("human_count", room_players.size()))
			if page == "lobby" or page == "create" or page == "join":
				_show_lobby()
		Protocol.START_GAME:
			online_snapshot.clear()
			online_center_card_ids.clear()
			online_round = int(payload.get("round_number", online_round + 1))
			online_phase = str(payload.get("phase", "playing"))
			online_players = payload.get("players", online_players)
			online_roles = payload.get("roles_by_player", online_roles)
		Protocol.DEAL:
			online_player_index = int(payload.get("player_index", online_player_index))
			online_round = int(payload.get("round_number", online_round))
			online_phase = str(payload.get("phase", online_phase))
			return_card_count = int(payload.get("exchange_return_count", 0))
			exchange_role = str(payload.get("exchange_role", payload.get("role", "")))
			exchange_mandatory_ids.clear()
			for card_id in payload.get("exchange_mandatory_ids", []):
				exchange_mandatory_ids.append(str(card_id))
			exchange_readiness = payload.get("exchange_readiness", exchange_readiness)
			exchange_participant = bool(payload.get("exchange_participant", false))
			online_players = payload.get("players", online_players)
			online_hand.clear()
			for item in payload.get("hand", []):
				online_hand.append(CardDataScript.from_dict(item))
			selected_card_ids.clear()
			_show_online_game()
		Protocol.TURN_CHANGED:
			online_snapshot = payload
			online_phase = str(payload.get("phase", online_phase))
			online_players = payload.get("players", online_players)
			if page == "game":
				_show_online_game()
		Protocol.CARD_EXCHANGE:
			exchange_readiness = payload.get("readiness", exchange_readiness)
			if str(payload.get("phase", "")) == "complete":
				online_phase = "playing"
			if page == "game":
				_show_online_game()
		Protocol.ROLES_ASSIGNED:
			online_roles = payload.get("roles_by_player", online_roles)
		Protocol.ROUND_FINISHED:
			online_players = payload.get("players", online_players)
			online_snapshot["finishing_order"] = payload.get("finishing_order", [])
			online_roles = payload.get("roles_by_player", online_roles)
			_show_results(payload)
		Protocol.ACTION_REJECTED:
			status_text = str(payload.get("reason", "The action was rejected."))
			_refresh_current_page()
		_:
			pass

func _submit_play() -> void:
	if selected_card_ids.is_empty():
		status_text = "Select a combination to play."
		_refresh_current_page()
		return
	_send_request(Protocol.PLAY_CARDS, {"card_ids": selected_card_ids.duplicate()})

func _submit_exchange() -> void:
	if return_card_count <= 0 or selected_card_ids.size() != return_card_count:
		status_text = "Select exactly %d cards to return." % return_card_count
		_refresh_current_page()
		return
	_send_request(Protocol.SELECT_CARDS, {"card_ids": selected_card_ids.duplicate()})

func _toggle_card(card_id: String) -> void:
	if online_phase == "card_exchange" and (exchange_role.begins_with("Slave ") or _trade_is_ready(exchange_role)):
		return
	if selected_card_ids.has(card_id):
		selected_card_ids.erase(card_id)
	else:
		selected_card_ids.append(card_id)
	_show_online_game()

func _leave_room() -> void:
	if endpoint.connected:
		endpoint.send_intent(Protocol.LEAVE_ROOM, {})
		endpoint.disconnect_from_server()
	room_code = ""
	room_players.clear()
	online_hand.clear()
	pending_request.clear()
	is_host = false
	status_text = ""
	_show_main_menu()

func _role_for(player_index: int) -> String:
	var value = online_roles.get(player_index, online_roles.get(str(player_index), ""))
	if str(value).is_empty() and player_index < online_players.size():
		value = online_players[player_index].get("role", "")
	return str(value) if not str(value).is_empty() else "%d%s" % [player_index + 1, _ordinal_suffix(player_index + 1)]

func _refresh_current_page() -> void:
	match page:
		"main": _show_main_menu()
		"create": _show_create_room()
		"join": _show_join_room()
		"lobby": _show_lobby()
		"game": _show_online_game()
		"results": _show_results(online_snapshot)

func _enforce_text_minimum(root: Node) -> void:
	_enforce_node_text_minimum(root)

func _enforce_node_text_minimum(node: Node) -> void:
	if node is Label or node is Button or node is LineEdit:
		var control := node as Control
		control.add_theme_font_size_override("font_size", maxi(16, control.get_theme_font_size("font_size")))
	for child in node.get_children():
		_enforce_node_text_minimum(child)

func _effective_guest_name() -> String:
	var cleaned := guest_name.strip_edges()
	return cleaned if not cleaned.is_empty() else "Guest"

func _ordinal_suffix(n: int) -> String:
	if n % 100 in [11, 12, 13]:
		return "th"
	match n % 10:
		1: return "st"
		2: return "nd"
		3: return "rd"
		_: return "th"
