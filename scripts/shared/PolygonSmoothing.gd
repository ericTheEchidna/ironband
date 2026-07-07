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


## Displaces each point of a closed loop perpendicular to its local tangent
## by a deterministic noise sample at that point's world position — the
## fractal-meander counterpart to chaikin_closed's corner-rounding. Pure
## rounding alone (chaikin_closed on its own) tends to read as artificially
## "bubbly"; this adds irregular wobble on top, closer to how a real
## coastline/border actually looks. Meant to run AFTER chaikin_closed, once
## there are enough points along each original edge to wobble independently
## (jittering the sparse original Voronoi vertices alone wouldn't add any
## detail between them).
##
## Deterministic: `noise` must be a FastNoiseLite with a fixed (non-random)
## seed — see this codebase's existing convention in CombatMap.gd. Because
## the result at any point depends only on that point's own world position,
## two adjacent shapes sampling the same shared boundary point (e.g. two
## regions computed from different partitions) get identical displacement —
## it does not reintroduce the seam risk chaikin_closed's callers already
## mitigate with a small overlap margin.
static func fractal_jitter_closed(points: PackedVector2Array, noise: FastNoiseLite, amplitude: float, frequency: float) -> PackedVector2Array:
	var n := points.size()
	if n < 3:
		return points
	var result := PackedVector2Array()
	result.resize(n)
	for i in n:
		var prev := points[(i - 1 + n) % n]
		var next := points[(i + 1) % n]
		var tangent := (next - prev)
		if tangent.length_squared() < 0.0001:
			result[i] = points[i]
			continue
		tangent = tangent.normalized()
		var normal := Vector2(-tangent.y, tangent.x)
		var p := points[i]
		var noise_val := noise.get_noise_2d(p.x * frequency, p.y * frequency)
		result[i] = p + normal * noise_val * amplitude
	return result
