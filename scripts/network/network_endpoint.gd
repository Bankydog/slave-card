class_name NetworkEndpoint
extends Node

func connect_to_server(_url: String) -> Error:
	return ERR_UNAVAILABLE

func disconnect_from_server() -> void:
	pass

func send_intent(_message_type: String, _payload: Dictionary = {}) -> bool:
	return false

@rpc("any_peer", "call_remote", "reliable")
func submit_message(message: Dictionary) -> void:
	if not is_server_endpoint():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 1:
		return
	var message_type := str(message.get("type", ""))
	if message_type in ["start_game", "select_rps", "continue_rps"]:
		print("[MP Server] RPC decoded: peer=%d type=%s." % [sender_id, message_type])
	handle_client_message(sender_id, message)

@rpc("authority", "call_remote", "reliable")
func receive_message(message: Dictionary) -> void:
	if is_server_endpoint():
		return
	var message_type := str(message.get("type", ""))
	if message_type in ["start_game", "deal", "rps_state", "turn_changed", "action_rejected"]:
		print("[MP Client] RPC decoded: type=%s." % message_type)
	handle_server_message(message)

func is_server_endpoint() -> bool:
	return false

func handle_client_message(_peer_id: int, _message: Dictionary) -> void:
	pass

func handle_server_message(_message: Dictionary) -> void:
	pass
