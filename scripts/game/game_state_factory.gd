extends RefCounted

const GameStateResource: Script = preload("res://scripts/game/game_state.gd")

static var _diagnostic_reported := false

static func create() -> Variant:
	var script: Script = GameStateResource
	if script == null:
		push_error("[GameState factory] Preloaded GameState script is null.")
		return null

	var can_instantiate := script.can_instantiate()
	var report_diagnostics := not _diagnostic_reported
	if report_diagnostics:
		print(
			"[GameState factory] resource_type=%d value=%s class=%s path=%s is_gdscript=%s base=%s global_name=%s can_instantiate=%s"
			% [
				typeof(script),
				str(script),
				script.get_class(),
				script.resource_path,
				script is GDScript,
				script.get_instance_base_type(),
				script.get_global_name(),
				can_instantiate
			]
		)
		_diagnostic_reported = true

	if not can_instantiate:
		push_error("[GameState factory] GameState script cannot be instantiated: %s" % script.resource_path)
		return null

	var instance: Object = script.new()
	if instance == null:
		push_error("[GameState factory] GameState script returned Nil from new(): %s" % script.resource_path)
		return null
	if not instance.has_method("start"):
		push_error("[GameState factory] GameState instance does not provide start(): %s" % instance.get_class())
		return null

	if report_diagnostics:
		var instance_script = instance.get_script() as Script
		print(
			"[GameState factory] instance_type=%d value=%s class=%s script_path=%s"
			% [typeof(instance), str(instance), instance.get_class(), instance_script.resource_path if instance_script != null else ""]
		)
	return instance
