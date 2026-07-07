class_name PolygonSmoothing
extends RefCounted

## Chaikin's corner-cutting algorithm — deterministic (no RNG), the standard
## technique for softening a procedural polygon's straight-edge corners
## without changing its underlying topology.


## Smooths a closed loop (no duplicated closing point — same convention as
## Geometry2D.merge_polygons' output and Line2D.closed = true). Each
## iteration roughly quadruples the point count.
static func chaikin_closed(points: PackedVector2Array, iterations: int) -> PackedVector2Array:
	var pts := points
	for _i in iterations:
		if pts.size() < 3:
			break
		var new_pts := PackedVector2Array()
		var n := pts.size()
		for i in n:
			var p0 := pts[i]
			var p1 := pts[(i + 1) % n]
			new_pts.append(p0.lerp(p1, 0.25))
			new_pts.append(p0.lerp(p1, 0.75))
		pts = new_pts
	return pts
