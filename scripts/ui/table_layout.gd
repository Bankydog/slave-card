extends RefCounted

const REFERENCE_SIZE := Vector2(1920.0, 1080.0)
const TOP_HUD_REFERENCE := Rect2(0.0, 0.0, 1920.0, 80.0)
const TABLE_REFERENCE := Rect2(530.0, 80.0, 860.0, 860.0)
const BOTTOM_HUD_REFERENCE := Rect2(0.0, 940.0, 1920.0, 140.0)

static func layout_for_viewport(viewport_size: Vector2) -> Dictionary:
	var safe_width := maxf(1.0, viewport_size.x)
	var safe_height := maxf(1.0, viewport_size.y)
	var scale := minf(safe_width / REFERENCE_SIZE.x, safe_height / REFERENCE_SIZE.y)
	var canvas_size := REFERENCE_SIZE * scale
	var origin := (viewport_size - canvas_size) * 0.5
	return {
		"scale": scale,
		"canvas_origin": origin,
		"canvas_rect": Rect2(origin, canvas_size),
		"top_hud": Rect2(origin + TOP_HUD_REFERENCE.position * scale, TOP_HUD_REFERENCE.size * scale),
		"table_zone": Rect2(origin + TABLE_REFERENCE.position * scale, TABLE_REFERENCE.size * scale),
		"bottom_hud": Rect2(origin + BOTTOM_HUD_REFERENCE.position * scale, BOTTOM_HUD_REFERENCE.size * scale)
	}
