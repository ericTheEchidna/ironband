class_name BoundaryHighlight
extends Node2D

## Draws a set of closed polygon loops (e.g. a province/realm's outer
## boundary, or a land/water coastline) as Line2D loops, Chaikin-smoothed for
## a less angular Voronoi look. Line2D (not manual draw_polyline) because it
## gives proper rounded joins at every vertex for free; a hand-drawn polyline
## has no join control and reads as a broken/segmented line at the many
## sharp angles a voronoi boundary has.

var line_color := Color(0.85, 0.82, 0.62, 0.85)
var line_width_px := 1.0  # desired on-screen width, independent of camera zoom
var camera: Camera2D = null
var smoothing_iterations := 2  # 0 disables smoothing entirely


func set_loops(new_loops: Array) -> void:
	for child in get_children():
		child.queue_free()
	for loop in new_loops:
		if loop.size() < 2:
			continue
		var points: PackedVector2Array = loop
		if smoothing_iterations > 0 and points.size() >= 3:
			points = PolygonSmoothing.chaikin_closed(points, smoothing_iterations)
		var line := Line2D.new()
		line.points          = points
		line.closed          = true
		line.default_color   = line_color
		line.joint_mode      = Line2D.LINE_JOINT_ROUND
		line.begin_cap_mode  = Line2D.LINE_CAP_ROUND
		line.end_cap_mode    = Line2D.LINE_CAP_ROUND
		line.antialiased     = true
		add_child(line)
	_apply_zoom_width()


func _apply_zoom_width() -> void:
	var zoom  := camera.zoom.x if camera else 1.0
	var width := line_width_px / maxf(zoom, 0.0001)
	for child in get_children():
		child.width = width
