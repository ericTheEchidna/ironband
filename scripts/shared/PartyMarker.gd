extends Node2D
class_name PartyMarker

## Party marker — a red dot fixed in screen pixels regardless of zoom.
## Scale is set each frame to 1/camera_zoom by the parent script, so all
## sizes here are in screen pixels.

const FILL_COLOR   := Color(1.0, 0.15, 0.10, 1.0)   # red
const BORDER_COLOR := Color(0.15, 0.0,  0.0,  1.0)  # dark red
const OUTER_R      := 10.0  # screen pixels
const INNER_R      :=  6.0
const TWEEN_DURATION := 0.18

var _fill:   Polygon2D
var _border: Polygon2D
var _tween:  Tween = null


func setup(_hex_size: float) -> void:
	_build_polygons()


func _build_polygons() -> void:
	if _border: _border.queue_free()
	if _fill:   _fill.queue_free()

	_border = Polygon2D.new()
	_border.polygon = _circle_points(OUTER_R)
	_border.color   = BORDER_COLOR
	add_child(_border)

	_fill = Polygon2D.new()
	_fill.polygon = _circle_points(INNER_R)
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


static func _circle_points(radius: float, steps: int = 24) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in steps:
		var angle := TAU * i / steps
		pts.append(Vector2(cos(angle), sin(angle)) * radius)
	return pts
