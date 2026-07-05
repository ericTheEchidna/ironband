extends Node2D
class_name PartyMarker

## Party marker — a red dot fixed in screen pixels regardless of zoom.
## Scale is set each frame to 1/camera_zoom by the parent script, so all
## sizes here are in screen pixels.

const OUTER_R      := 10.0  # screen pixels
const INNER_R      :=  6.0
const TWEEN_DURATION := 0.18

@onready var _border: Polygon2D = $Border
@onready var _fill:   Polygon2D = $Fill
var _tween: Tween = null


func setup(_hex_size: float) -> void:
	_border.polygon = _circle_points(OUTER_R)
	_fill.polygon   = _circle_points(INNER_R)


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
