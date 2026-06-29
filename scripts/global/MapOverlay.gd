extends Node2D

## Overlay layer for rivers and roads on GlobalMap.
## Sits at z_index=5 (above the hex shader rect, below the party marker).

var river_polys: Array = []   # Array of {pts: PackedVector2Array, width: float}
var road_polys:  Array = []   # Array of PackedVector2Array
var trail_polys: Array = []   # Array of PackedVector2Array
var camera: Camera2D = null


func _process(_delta: float) -> void:
	if camera != null and not (river_polys.is_empty() and road_polys.is_empty() and trail_polys.is_empty()):
		queue_redraw()


func _draw() -> void:
	if camera == null:
		return
	var inv := 1.0 / camera.zoom.x
	var river_color := Color(0.30, 0.55, 0.85, 0.80)
	var road_color  := Color(0.70, 0.55, 0.25, 0.90)
	var trail_color := Color(0.60, 0.48, 0.22, 0.55)
	for rv in river_polys:
		var w := clampf(rv.width * 6.0, 0.4, 3.0) * inv
		draw_polyline(rv.pts, river_color, w, true)
	for pts in road_polys:
		draw_polyline(pts, road_color, 1.8 * inv, true)
	for pts in trail_polys:
		draw_polyline(pts, trail_color, 0.9 * inv, true)
