extends Node2D
class_name PartyMarker

## Party marker — a pointy-top hex polygon drawn in world (Azgaar) coordinates.
## Pure visual: no game logic. Receives move_to() calls from WorldMap.gd.

const FILL_COLOR   := Color(1.0, 0.82, 0.12, 0.95)   # gold
const BORDER_COLOR := Color(0.10, 0.06, 0.00, 0.95)  # dark brown
const TWEEN_DURATION := 0.18   # seconds per step at zoom=1

var _hex_size: float = 1.0
var _fill:     Polygon2D
var _border:   Polygon2D
var _tween:    Tween = null


func setup(hex_size: float) -> void:
	_hex_size = hex_size
	_build_polygons()


func _build_polygons() -> void:
	if _border: _border.queue_free()
	if _fill:   _fill.queue_free()

	# WorldMap._process sets scale = 1/zoom, so world-space size == screen pixels.
	var outer := _hex_points(40.0)
	var inner := _hex_points(28.0)

	_border = Polygon2D.new()
	_border.polygon = outer
	_border.color   = BORDER_COLOR
	add_child(_border)

	_fill = Polygon2D.new()
	_fill.polygon = inner
	_fill.color   = FILL_COLOR
	add_child(_fill)


func move_to(world_pos: Vector2, camera_zoom: float = 1.0) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.set_ease(Tween.EASE_IN_OUT)
	_tween.set_trans(Tween.TRANS_QUAD)
	var dur: float = TWEEN_DURATION / maxf(camera_zoom, 0.5)
	_tween.tween_property(self, "position", world_pos, dur)


func place_at(world_pos: Vector2) -> void:
	if _tween:
		_tween.kill()
	position = world_pos
	visible = true


func flash() -> void:
	var t := create_tween()
	t.set_ease(Tween.EASE_OUT)
	t.tween_property(self, "scale", Vector2(1.6, 1.6), 0.08)
	t.tween_property(self, "scale", Vector2(1.0, 1.0), 0.14)


## Pointy-top hex polygon vertices (centre at origin).
static func _hex_points(size: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var angle := deg_to_rad(60.0 * i + 30.0)
		pts.append(Vector2(cos(angle), -sin(angle)) * size)
	return pts
