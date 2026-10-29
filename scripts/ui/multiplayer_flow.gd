extends Control

const ClientEndpointScript = preload("res://scripts/network/client_network_endpoint.gd")
const Protocol = preload("res://scripts/network/network_protocol.gd")
const CardDataScript = preload("res://scripts/cards/card_data.gd")
const HandSorterScript = preload("res://scripts/cards/hand_sorter.gd")
const GameRulesScript = preload("res://scripts/game/game_rules.gd")
const MatchStateScript = preload("res://scripts/game/match_state.gd")
const CardViewScript = preload("res://scripts/ui/card_view.gd")
const TablePresentationScript = preload("res://scripts/ui/table_presentation.gd")
const TableLayoutScript = preload("res://scripts/ui/table_layout.gd")

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
var create_match_round_limit := 4
var match_round_limit := 4
var room_players: Array = []
var lobby_all_ready := false
var lobby_ready_count := 0
var lobby_human_count := 0
var incoming_seat_swap: Dictionary = {}
var outgoing_seat_swaps: Array = []
var is_host := false
var local_player_index := -1
var online_player_index := -1
var online_round := 0
var last_round_sound := -1
var online_center_initialized := false
var online_phase := "lobby"
var rps_players: Array = []
var rps_choices: Dictionary = {}
var rps_round := 1
var online_rps_reveal_active := false
var queued_turn_snapshot: Dictionary = {}
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
	resized.connect(_layout_game_status_panel)
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
	if host.has_method("set_title_screen_enabled"):
		host.set_title_screen_enabled(true)
	for child in get_children():
		if child != endpoint:
			remove_child(child)
			child.queue_free()

func _display_scale() -> float:
	return float(TableLayoutScript.layout_for_viewport(get_viewport_rect().size).scale)

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
	if page in ["main", "create", "join", "lobby"]:
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
		var panel_padding_x := 8.0 if page == "lobby" and _is_compact_view() else 24.0
		var panel_padding_y := 8.0 if page == "lobby" and _is_compact_view() else 18.0
		panel_style.content_margin_left = panel_padding_x * _display_scale()
		panel_style.content_margin_right = panel_padding_x * _display_scale()
		panel_style.content_margin_top = panel_padding_y * _display_scale()
		panel_style.content_margin_bottom = panel_padding_y * _display_scale()
		panel.add_theme_stylebox_override("panel", panel_style)
		center.add_child(panel)
		panel.add_child(root)
	else:
		root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(root)
	root.add_theme_constant_override("separation", roundi((2.0 if page == "lobby" and _is_compact_view() else (4.0 if _is_compact_view() else 12.0)) * _display_scale()))
	if not title_text.is_empty():
		if page == "game":
			_add_game_status_panel(title_text)
		else:
			var heading := Label.new()
			heading.text = title_text
			heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			heading.custom_minimum_size.y = (28.0 if page == "lobby" and _is_compact_view() else 36.0) * _display_scale()
			heading.add_theme_font_size_override("font_size", maxi(16, roundi((22.0 if _is_compact_view() else 32.0) * _display_scale())))
			root.add_child(heading)
	return root

func _add_game_status_panel(status_text: String) -> void:
	var status_panel := PanelContainer.new()
	status_panel.name = "RoundStatusPanel"
	status_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	var hud_scale := _display_scale()
	status_panel.position = Vector2(16.0, 10.0) * hud_scale
	status_panel.custom_minimum_size.y = 40.0 * hud_scale
	status_panel.size = Vector2.ZERO
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
	var heading := Label.new()
	heading.name = "RoundStatus"
	heading.text = status_text
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.clip_text = true
	heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	heading.add_theme_font_size_override("font_size", maxi(16, roundi(18.0 * hud_scale)))
	status_panel.add_child(heading)
	_layout_game_status_panel()

func _layout_game_status_panel() -> void:
	var panel := find_child("RoundStatusPanel", true, false) as Control
	if not is_instance_valid(panel):
		return
	var layout: Dictionary = TableLayoutScript.layout_for_viewport(get_viewport_rect().size)
	var scale := float(layout.scale)
	var top_hud: Rect2 = layout.top_hud
	var panel_height := maxf(32.0, 42.0 * scale)
	panel.position = top_hud.position + Vector2(16.0, maxf(0.0, (top_hud.size.y - panel_height) * 0.5))
	var label := panel.get_node("RoundStatus") as Label
	var font_size := float(label.get_theme_font_size("font_size"))
	var content_width := float(label.text.length()) * font_size * 0.56
	panel.size = Vector2(minf(content_width + 24.0 * scale, top_hud.size.x - 24.0 * scale), panel_height)

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
	button.custom_minimum_size = Vector2(width, 34 if page == "lobby" and _is_compact_view() else (42 if _is_compact_view() else 52)) * _display_scale()
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
	var root := _root_box("")
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
	var host := get_parent()
	if host.has_method("set_title_screen_enabled"):
		host.set_title_screen_enabled(true)

func _show_create_room() -> void:
	page = "create"
	status_text = ""
	var root := _root_box("Create Room")
	root.alignment = BoxContainer.ALIGNMENT_CENTER
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
	var rounds_row := HBoxContainer.new()
	rounds_row.alignment = BoxContainer.ALIGNMENT_CENTER
	rounds_row.add_theme_constant_override("separation", roundi(8.0 * _display_scale()))
	var rounds_label := Label.new()
	rounds_label.text = "Rounds"
	rounds_label.custom_minimum_size.x = 76.0 * _display_scale()
	rounds_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rounds_row.add_child(rounds_label)
	for round_limit in MatchStateScript.ALLOWED_ROUND_LIMITS:
		var round_button := Button.new()
		round_button.text = str(round_limit)
		round_button.toggle_mode = true
		round_button.button_pressed = round_limit == create_match_round_limit
		round_button.custom_minimum_size = Vector2(64.0, 48.0) * _display_scale()
		_style_round_choice(round_button, round_limit == create_match_round_limit)
		round_button.pressed.connect(_select_create_match_round_limit.bind(round_limit))
		rounds_row.add_child(round_button)
	root.add_child(rounds_row)
	_action_button(root, "Create Room", func(): _send_request(Protocol.CREATE_ROOM, {"name": _effective_guest_name(), "max_players": room_max_players, "match_round_limit": create_match_round_limit}))
	_action_button(root, "Back", _show_main_menu, 150)
	_status(root)
	_enforce_text_minimum(root)

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

func _select_create_match_round_limit(round_limit: int) -> void:
	if not MatchStateScript.ALLOWED_ROUND_LIMITS.has(round_limit):
		return
	create_match_round_limit = round_limit
	_show_create_room()

func _show_join_room() -> void:
	page = "join"
	status_text = ""
	var root := _root_box("Join Room")
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	_labeled_line_edit(root, "Name", guest_name, "Guest name", _set_guest_name)
	room_code_input = _line_edit(root, room_code, "6-character room code", _set_room_code)
	_action_button(root, "Join Room", func(): _send_request(Protocol.JOIN_ROOM, {"name": _effective_guest_name(), "room_code": room_code.to_upper()}))
	_action_button(root, "Back", _show_main_menu, 150)
	_status(root)
	_enforce_text_minimum(root)

func _copy_room_code(button: Button) -> void:
	if room_code.is_empty() or not is_instance_valid(button):
		return
	DisplayServer.clipboard_set(room_code)
	button.text = "Copied!"
	get_tree().create_timer(1.4).timeout.connect(func():
		if is_instance_valid(button):
			button.text = "Copy"
	)

func _show_lobby() -> void:
	page = "lobby"
	var root := _root_box("Room Lobby")
	var code_row := HBoxContainer.new()
	code_row.alignment = BoxContainer.ALIGNMENT_CENTER
	code_row.add_theme_constant_override("separation", roundi(8.0 * _display_scale()))
	var code_label := Label.new()
	code_label.text = "ROOM CODE   %s" % room_code
	code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_label.add_theme_font_size_override("font_size", 24)
	code_row.add_child(code_label)
	var copy_button := Button.new()
	copy_button.text = "Copy"
	copy_button.custom_minimum_size = Vector2(82, 32 if _is_compact_view() else 40) * _display_scale()
	copy_button.pressed.connect(_copy_room_code.bind(copy_button))
	code_row.add_child(copy_button)
	root.add_child(code_row)
	if not incoming_seat_swap.is_empty():
		var request_row := HBoxContainer.new()
		request_row.alignment = BoxContainer.ALIGNMENT_CENTER
		var request_label := Label.new()
		request_label.text = "%s wants to swap seats with you." % str(incoming_seat_swap.get("name", "A player"))
		request_row.add_child(request_label)
		_action_button(request_row, "Accept", func(): _send_request(Protocol.RESPOND_SEAT_SWAP, {"request_id": int(incoming_seat_swap.get("request_id", -1)), "accept": true}), 110)
		_action_button(request_row, "Reject", func(): _send_request(Protocol.RESPOND_SEAT_SWAP, {"request_id": int(incoming_seat_swap.get("request_id", -1)), "accept": false}), 110)
		root.add_child(request_row)
	var count_label := Label.new()
	count_label.text = "%d / %d humans connected  ·  Match: %d rounds" % [lobby_human_count, room_max_players, match_round_limit]
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(count_label)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 48 if _is_compact_view() else 200
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
		var player_peer := int(player.get("peer_id", 0))
		var is_bot := bool(player.get("is_bot", false))
		var is_local := int(player.get("player_index", -1)) == local_player_index
		var card := Button.new()
		card.custom_minimum_size = Vector2(220.0, 42.0 if _is_compact_view() else 54.0) * _display_scale()
		var badge := "Host" if bool(player.get("is_host", false)) else ("Bot" if is_bot else "Guest")
		var ready_text := "Ready" if bool(player.get("ready", false)) else "Not Ready"
		card.text = "%s  ·  %s  ·  %s" % [str(player.get("name", "Guest")), badge, ready_text]
		if bool(player.get("disconnected", false)):
			card.text = "%s  ·  LEFT" % str(player.get("name", "Player"))
		card.add_theme_font_size_override("font_size", maxi(16, roundi(17.0 * _display_scale())))
		card.disabled = is_bot or is_local or player_peer <= 0 or not outgoing_seat_swaps.is_empty() or not incoming_seat_swap.is_empty()
		if not card.disabled:
			card.pressed.connect(func(): _send_request(Protocol.REQUEST_SEAT_SWAP, {"target_peer_id": player_peer}))
		grid.add_child(card)
	if not outgoing_seat_swaps.is_empty():
		var outgoing_label := Label.new()
		outgoing_label.text = "Seat swap request sent. Waiting for a reply."
		outgoing_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(outgoing_label)
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

func _image_action_button(button_name: String, texture_path: String, tooltip: String, action: Callable) -> TextureButton:
	var button := TextureButton.new()
	button.name = button_name
	button.texture_normal = load(texture_path)
	button.texture_hover = button.texture_normal
	button.texture_pressed = button.texture_normal
	button.ignore_texture_size = true
	button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	button.custom_minimum_size = Vector2(62 if _is_compact_view() else 74, 62 if _is_compact_view() else 74) * _display_scale()
	button.tooltip_text = tooltip
	button.pressed.connect(action)
	return button

func _show_online_game() -> void:
	page = "game"
	var trading := online_phase == "card_exchange"
	if trading and exchange_role.begins_with("Slave ") and selected_card_ids.is_empty():
		selected_card_ids = exchange_mandatory_ids.duplicate()
	HandSorterScript.sort_hand(online_hand)
	var title_text := "Round %d / %d · %s" % [online_round, match_round_limit, "Card Exchange" if trading else ("3♣ Tie Break" if online_phase == "rps_tiebreak" else "Playing")]
	var menu_root := _root_box(title_text)
	menu_root.queue_free()
	var root := Control.new()
	root.name = "OnlineGameplayLayout"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var host := get_parent()
	if host.has_method("set_game_background"):
		host.set_game_background(online_players.size())
	if online_phase == "rps_tiebreak":
		var rps_center := CenterContainer.new()
		rps_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		root.add_child(rps_center)
		var rps_content := VBoxContainer.new()
		rps_content.alignment = BoxContainer.ALIGNMENT_CENTER
		rps_center.add_child(rps_content)
		_show_online_rps(rps_content)
		_enforce_text_minimum(root)
		return
	if host.has_method("set_title_screen_enabled"):
		host.set_title_screen_enabled(false)

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
			if online_center_initialized:
				SfxManager.play_card_play()
		online_center_card_ids = next_center_ids.duplicate()
	var table_view: Control = TablePresentationScript.new()
	table_view.name = "TablePresentation"
	table_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(table_view)
	table_view.configure(online_players, online_player_index, int(online_snapshot.get("current_player", -1)), passed, current_cards, center_text, _is_compact_view(), animation_player)

	var center_message := ""
	if trading:
		if exchange_role == "King":
			center_message = "Role: King · Choose %d cards for Slave 1\nSelected: %d / %d" % [return_card_count, selected_card_ids.size(), return_card_count]
		elif exchange_role == "Queen":
			center_message = "Role: Queen · Choose %d cards for Slave 2\nSelected: %d / %d" % [return_card_count, selected_card_ids.size(), return_card_count]
		elif exchange_role == "Seven":
			center_message = "Role: Seven · Choose %d card(s) for Slave 3\nSelected: %d / %d" % [return_card_count, selected_card_ids.size(), return_card_count]
		elif exchange_role.begins_with("Slave "):
			var upper_role := "King/Queen" if exchange_role == "Slave 1" and online_players.size() == 3 else ("Queen" if exchange_role == "Slave 2" else ("Seven" if exchange_role == "Slave 3" else "King"))
			center_message = "%s: waiting to receive %d card(s) from %s." % [exchange_role, exchange_mandatory_ids.size(), upper_role]
		else:
			center_message = "Waiting for card exchange..."
	else:
		if int(online_snapshot.get("current_player", -1)) == online_player_index:
			center_message = "Your turn"
		else:
			var current_index := int(online_snapshot.get("current_player", -1))
			var current_name := "the current player"
			if current_index >= 0 and current_index < online_players.size():
				current_name = str(online_players[current_index].get("name", current_name))
			center_message = "Waiting for %s" % current_name
	if trading:
		center_message += "\n" + " · ".join(_trade_summary_parts())
	table_view.set_center_info(center_message)
	if trading:
		var trade_center := CenterContainer.new()
		trade_center.name = "TradeWaitLayer"
		trade_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		trade_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(trade_center)
		var trade_content := VBoxContainer.new()
		trade_content.alignment = BoxContainer.ALIGNMENT_CENTER
		trade_center.add_child(trade_content)
		_add_trade_progress(trade_content)
		if not exchange_participant or _trade_is_ready(exchange_role):
			var waiting := Label.new()
			waiting.name = "TradeWaiting"
			waiting.text = "Waiting Trade"
			waiting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			trade_content.add_child(waiting)
			_status(root)
			_enforce_text_minimum(root)
			return

	var layout: Dictionary = TableLayoutScript.layout_for_viewport(get_viewport_rect().size)
	var scale := float(layout.scale)
	var bottom_rect: Rect2 = layout.bottom_hud
	var bottom_hud := Control.new()
	bottom_hud.name = "BottomHUD"
	bottom_hud.position = bottom_rect.position
	bottom_hud.size = bottom_rect.size
	root.add_child(bottom_hud)
	var hand_scroll := ScrollContainer.new()
	hand_scroll.name = "OnlineHandScroll"
	hand_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	hand_scroll.position = Vector2(24.0, 2.0) * scale
	var hand_height := minf((77.0 if _is_compact_view() else 109.0) * scale, bottom_rect.size.y - 74.0 * scale)
	hand_scroll.size = Vector2(maxf(1.0, bottom_rect.size.x - 48.0 * scale), hand_height)
	bottom_hud.add_child(hand_scroll)
	var hand_center := CenterContainer.new()
	hand_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hand_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hand_scroll.add_child(hand_center)
	var hand_row := HBoxContainer.new()
	hand_row.alignment = BoxContainer.ALIGNMENT_CENTER
	hand_row.add_theme_constant_override("separation", roundi(-29.0 * scale))
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
		card_button.setup(card, selected, _is_compact_view(), scale)
		card_button.disabled = not selected and not selectable.has(card_id)
		card_button.set_available(not card_button.disabled)
		if not (trading and exchange_role.begins_with("Slave ")):
			card_button.pressed.connect(_toggle_card.bind(card_id))
		CardViewScript.add_hand_slot(hand_row, card_button, _is_compact_view(), scale)
	hand_row.add_theme_constant_override("separation", roundi(CardViewScript.hand_separation(online_hand.size(), hand_scroll.size.x, _is_compact_view(), scale)))

	var buttons := HBoxContainer.new()
	buttons.name = "OnlineActions"
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.position = Vector2(0.0, hand_height)
	buttons.size = Vector2(bottom_rect.size.x, maxf(0.0, bottom_rect.size.y - hand_height))
	buttons.add_theme_constant_override("separation", roundi(8.0 * scale))
	bottom_hud.add_child(buttons)
	if trading:
		var return_button := Button.new()
		return_button.name = "ConfirmTradeButton"
		return_button.text = "Confirm Trade (%d/%d)" % [selected_card_ids.size(), return_card_count]
		return_button.custom_minimum_size = Vector2(220, 48) * scale
		return_button.disabled = return_card_count <= 0 or selected_card_ids.size() != return_card_count
		return_button.pressed.connect(_submit_exchange)
		buttons.add_child(return_button)
	else:
		var play_button := _image_action_button("PlayButton", "res://assets/gadget/bottom-play.png", "Play", _submit_play)
		play_button.disabled = selected_card_ids.is_empty() or int(online_snapshot.get("current_player", -1)) != online_player_index
		buttons.add_child(play_button)
		var pass_button := _image_action_button("PassButton", "res://assets/gadget/bottom-pass.png", "Pass", func(): _send_request(Protocol.PASS, {}))
		buttons.add_child(pass_button)
		var leave_button := _image_action_button("LeaveButton", "res://assets/gadget/bottom-leave.png", "Leave", _leave_room)
		buttons.add_child(leave_button)
	_status(root)
	_enforce_text_minimum(root)

func _trade_summary_parts() -> Array[String]:
	var parts: Array[String] = []
	for role in ["King", "Queen", "Seven", "Slave 1", "Slave 2", "Slave 3"]:
		var value := str(exchange_readiness.get(role, ""))
		if not value.is_empty():
			parts.append("%s: %s" % [role, value])
	return parts
func _show_online_rps(root: Control) -> void:
	var heading := Label.new()
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.text = "Two players hold 3♣ · choose rock, paper, or scissors" if rps_round <= 1 else "Tie · choose again (round %d)" % rps_round
	root.add_child(heading)
	var held_cards := HBoxContainer.new()
	held_cards.alignment = BoxContainer.ALIGNMENT_CENTER
	held_cards.add_theme_constant_override("separation", roundi(24.0 * _display_scale()))
	root.add_child(held_cards)
	for player_index_value in rps_players:
		var player_index := int(player_index_value)
		var holder := VBoxContainer.new()
		holder.alignment = BoxContainer.ALIGNMENT_CENTER
		held_cards.add_child(holder)
		var back := TextureRect.new()
		back.texture = TablePresentationScript.rps_back_texture()
		back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		back.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		back.custom_minimum_size = Vector2(60.0, 84.0) * _display_scale()
		holder.add_child(back)
		var holder_label := Label.new()
		holder_label.text = "You" if player_index == online_player_index else str(online_players[player_index].get("name", "Opponent")) if player_index < online_players.size() else "Opponent"
		holder_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		holder.add_child(holder_label)
	var choices := HBoxContainer.new()
	choices.alignment = BoxContainer.ALIGNMENT_CENTER
	choices.add_theme_constant_override("separation", roundi(8.0 * _display_scale()))
	root.add_child(choices)
	var local_is_tied := rps_players.has(online_player_index)
	var already_chosen := rps_choices.has(str(online_player_index))
	if local_is_tied and not already_chosen:
		for choice in range(3):
			var button := TextureButton.new()
			button.texture_normal = TablePresentationScript.rps_texture(choice)
			button.ignore_texture_size = true
			button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
			button.custom_minimum_size = Vector2(72.0, 100.0) * _display_scale()
			button.pressed.connect(_select_rps_choice.bind(choice))
			choices.add_child(button)
	else:
		var waiting := Label.new()
		waiting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		waiting.text = "Your choice is locked. Waiting for the other player..." if already_chosen else "Waiting for the tied players to choose..."
		root.add_child(waiting)

func _reveal_online_rps() -> void:
	if online_rps_reveal_active:
		return
	online_rps_reveal_active = true
	var choices_snapshot := rps_choices.duplicate(true)
	var players_snapshot := rps_players.duplicate()
	var root := _root_box("3♣ Tie Break")
	var heading := Label.new()
	heading.text = "Rock · Paper · Scissors"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(heading)
	var cards := HBoxContainer.new()
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override("separation", roundi(30.0 * _display_scale()))
	root.add_child(cards)
	var faces: Array[TextureRect] = []
	var revealed_textures: Array[Texture2D] = []
	for player_value in players_snapshot:
		var player_index := int(player_value)
		var holder := VBoxContainer.new()
		holder.alignment = BoxContainer.ALIGNMENT_CENTER
		cards.add_child(holder)
		var face := TextureRect.new()
		face.texture = TablePresentationScript.rps_back_texture()
		face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		face.custom_minimum_size = Vector2(92.0, 128.0) * _display_scale()
		holder.add_child(face)
		faces.append(face)
		var choice := int(choices_snapshot.get(str(player_index), 0))
		revealed_textures.append(TablePresentationScript.rps_texture(choice))
		var player_name := str(online_players[player_index].get("name", "Player %d" % (player_index + 1))) if player_index < online_players.size() else "Player %d" % (player_index + 1)
		var label := Label.new()
		label.text = "You" if player_index == online_player_index else player_name
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		holder.add_child(label)
	var tween := create_tween()
	tween.tween_interval(0.1)
	tween.set_parallel(true)
	for face in faces:
		tween.tween_property(face, "scale:x", 0.0, 0.1).set_trans(Tween.TRANS_CUBIC)
	tween.set_parallel(false)
	tween.tween_callback(func():
		for i in range(faces.size()):
			faces[i].texture = revealed_textures[i]
	)
	tween.set_parallel(true)
	for face in faces:
		tween.tween_property(face, "scale:x", 1.0, 0.15).set_trans(Tween.TRANS_CUBIC)
	await tween.finished
	online_rps_reveal_active = false
	if not queued_turn_snapshot.is_empty():
		online_snapshot = queued_turn_snapshot
		queued_turn_snapshot.clear()
		online_phase = str(online_snapshot.get("phase", "playing"))
		online_players = online_snapshot.get("players", online_players)
		if page == "game":
			_show_online_game()

func _select_rps_choice(choice: int) -> void:
	_send_request(Protocol.SELECT_RPS, {"choice": choice})

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
	online_round = int(payload.get("current_round", payload.get("round_number", online_round)))
	match_round_limit = int(payload.get("match_round_limit", match_round_limit))
	online_roles = payload.get("roles_by_player", online_roles)
	online_players = payload.get("players", online_players)
	var root := _root_box("Round %d / %d Results" % [online_round, match_round_limit])
	var host := get_parent()
	if host.has_method("set_game_background"):
		host.set_game_background(online_players.size())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 110.0 if _is_compact_view() else 240.0
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", roundi(4.0 * _display_scale()))
	scroll.add_child(rows)
	root.add_child(scroll)
	var order: Array = payload.get("finishing_order", [])
	var points: Array = payload.get("round_points", [])
	var scores: Array = payload.get("match_scores", [])
	for place in range(order.size()):
		var player_index := int(order[place])
		var player_name := "Player %d" % (player_index + 1)
		if player_index < online_players.size():
			player_name = str(online_players[player_index].get("name", player_name))
		var role := _role_for(player_index)
		var earned := int(points[player_index]) if player_index < points.size() else 0
		var total := int(scores[player_index]) if player_index < scores.size() else 0
		var row := Label.new()
		row.text = "%d. %s  +%d  Total %d  ·  %s" % [place + 1, player_name, earned, total, role]
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rows.add_child(row)
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
		_action_button(root, "Next Round", func(): _send_request(Protocol.START_NEXT_ROUND, {}))
	else:
		var wait := Label.new()
		wait.text = "Waiting for the host to start the next round"
		wait.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(wait)
	_action_button(root, "Leave Room", _leave_room, 170)
	_status(root)
	_enforce_text_minimum(root)

func _show_final_match_result(payload: Dictionary) -> void:
	page = "final_results"
	online_round = int(payload.get("current_round", online_round))
	match_round_limit = int(payload.get("match_round_limit", match_round_limit))
	online_roles = payload.get("roles_by_player", online_roles)
	online_players = payload.get("players", online_players)
	var root := _root_box("Final Result — %d Rounds" % match_round_limit)
	var host := get_parent()
	if host.has_method("set_game_background"):
		host.set_game_background(online_players.size())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", roundi(5.0 * _display_scale()))
	scroll.add_child(rows)
	root.add_child(scroll)
	var leaderboard: Array = payload.get("leaderboard", [])
	for place in range(leaderboard.size()):
		var entry: Dictionary = leaderboard[place]
		var row := Label.new()
		row.text = "%d. %s  ·  Score %d  ·  1st %d  ·  2nd %d" % [place + 1, str(entry.get("name", "Player")), int(entry.get("score", 0)), int(entry.get("first_place_count", 0)), int(entry.get("second_place_count", 0))]
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if place == 0:
			row.add_theme_color_override("font_color", Color("#f3d78b"))
			row.add_theme_font_size_override("font_size", maxi(18, roundi(24.0 * _display_scale())))
		rows.add_child(row)
	if is_host:
		_action_button(root, "Rematch", func(): _send_request(Protocol.REMATCH, {}))
	else:
		var waiting := Label.new()
		waiting.text = "Waiting for the host to rematch"
		waiting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(waiting)
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
			match_round_limit = int(payload.get("match_round_limit", match_round_limit))
			online_round = int(payload.get("current_round", online_round))
			room_players = payload.get("players", [])
			incoming_seat_swap = payload.get("incoming_swap", {})
			outgoing_seat_swaps = payload.get("outgoing_swaps", [])
			local_player_index = int(payload.get("your_player_index", -1))
			is_host = bool(payload.get("is_host", is_host))
			lobby_all_ready = bool(payload.get("all_ready", false))
			lobby_ready_count = int(payload.get("ready_count", 0))
			lobby_human_count = int(payload.get("human_count", room_players.size()))
			if page == "lobby" or page == "create" or page == "join" or (page == "final_results" and str(payload.get("phase", "")) == "lobby"):
				_show_lobby()
		Protocol.START_GAME:
			online_snapshot.clear()
			online_center_card_ids.clear()
			online_round = int(payload.get("current_round", payload.get("round_number", online_round + 1)))
			match_round_limit = int(payload.get("match_round_limit", match_round_limit))
			_play_round_start_once(online_round)
			online_center_initialized = false
			online_phase = str(payload.get("phase", "playing"))
			online_players = payload.get("players", online_players)
			online_roles = payload.get("roles_by_player", online_roles)
		Protocol.DEAL:
			online_player_index = int(payload.get("player_index", online_player_index))
			online_round = int(payload.get("current_round", payload.get("round_number", online_round)))
			match_round_limit = int(payload.get("match_round_limit", match_round_limit))
			_play_round_start_once(online_round)
			online_center_initialized = true
			online_phase = str(payload.get("phase", online_phase))
			rps_players = payload.get("rps_players", rps_players)
			rps_choices = payload.get("rps_choices", rps_choices)
			rps_round = int(payload.get("rps_round", rps_round))
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
		Protocol.RPS_STATE:
			rps_players = payload.get("players", rps_players)
			rps_choices = payload.get("choices", {})
			rps_round = int(payload.get("round", rps_round))
			online_phase = str(payload.get("phase", online_phase))
			if page == "game":
				if online_phase == "playing" and rps_choices.size() >= rps_players.size() and not rps_players.is_empty():
					_reveal_online_rps()
				else:
					_show_online_game()
		Protocol.TURN_CHANGED:
			if online_rps_reveal_active:
				queued_turn_snapshot = payload.duplicate(true)
				return
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
			online_snapshot = payload.duplicate(true)
			online_roles = payload.get("roles_by_player", online_roles)
			_show_results(payload)
		Protocol.MATCH_FINISHED:
			online_players = payload.get("players", online_players)
			online_snapshot = payload.duplicate(true)
			online_roles = payload.get("roles_by_player", online_roles)
			_show_final_match_result(payload)
		Protocol.SEAT_SWAP_RESULT:
			status_text = "Seat swap accepted." if bool(payload.get("accepted", false)) else "Seat swap declined."
			_refresh_current_page()
		Protocol.ACTION_REJECTED:
			status_text = str(payload.get("reason", "The action was rejected."))
			_refresh_current_page()
		_:
			pass

func _play_round_start_once(round_number: int) -> void:
	if round_number <= 0 or round_number == last_round_sound:
		return
	last_round_sound = round_number
	SfxManager.play_shuffle()

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
	SfxManager.play_card_select()
	_show_online_game()

func _leave_room() -> void:
	if endpoint.connected:
		endpoint.send_intent(Protocol.LEAVE_ROOM, {})
		endpoint.disconnect_from_server()
	room_code = ""
	incoming_seat_swap.clear()
	outgoing_seat_swaps.clear()
	last_round_sound = -1
	online_center_initialized = false
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
		"final_results": _show_final_match_result(online_snapshot)

func _enforce_text_minimum(root: Node) -> void:
	_enforce_node_text_minimum(root)

func _enforce_node_text_minimum(node: Node) -> void:
	if node is BaseButton and node.get_script() != CardViewScript and not (node is Button and node.text == "Play") and not node.has_meta("sfx_wired"):
		node.pressed.connect(SfxManager.play_ui_click)
		node.set_meta("sfx_wired", true)
	if node is Label or node is Button or node is LineEdit:
		var control := node as Control
		control.add_theme_font_size_override("font_size", maxi(16, control.get_theme_font_size("font_size")))
	if node is Label and page in ["main", "create", "join", "lobby"]:
		(node as Label).add_theme_color_override("font_color", Color(0.12, 0.09, 0.07))
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
