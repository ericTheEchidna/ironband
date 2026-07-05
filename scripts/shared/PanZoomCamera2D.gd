class_name PanZoomCamera2D
extends Camera2D

## Drag-to-pan mechanics shared by GlobalMap and RegionMap. Godot's Camera2D
## has no built-in drag-to-pan, so this is the hand-rolled part; wheel-zoom
## behavior differs meaningfully between the two callers (cursor-centered vs.
## marker-centered) and stays in each script rather than living here.

const CLICK_THRESHOLD_PX := 4.0

var _is_dragging  := false
var _drag_start   := Vector2.ZERO
var _camera_start := Vector2.ZERO
var _drag_dist    := 0.0


func begin_drag(mouse_pos: Vector2) -> void:
	_is_dragging  = true
	_drag_start   = mouse_pos
	_camera_start = position
	_drag_dist    = 0.0


## Returns true if the total drag distance stayed under the click threshold —
## callers treat that as a click rather than a pan.
func end_drag() -> bool:
	_is_dragging = false
	return _drag_dist < CLICK_THRESHOLD_PX


func is_dragging() -> bool:
	return _is_dragging


## Feed every InputEventMouseMotion while dragging. No-op if not dragging.
func drag_to(mouse_pos: Vector2, relative: Vector2) -> void:
	if not _is_dragging:
		return
	_drag_dist += relative.length()
	var delta := mouse_pos - _drag_start
	position = _camera_start - delta / zoom.x
