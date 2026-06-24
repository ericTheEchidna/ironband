## RouteLoader — parse routes.bin into road/trail/searoute hex polylines.
##
## Binary format (RTE1):
##   Header 6 B: magic(4) + route_count u16
##   Per route: group u8, point_count u16, then point_count × (i16 q, i16 r)
##
## group: 0=road 1=trail 2=searoute
##
## Usage:
##   var routes := RouteLoader.load_file("res://worlds/cheia/routes.bin")
##   for r in routes.roads:
##       draw_polyline(r)  # r is PackedVector2iArray of (q,r) hex coords
class_name RouteLoader

const MAGIC := "RTE1"

class RouteData:
	var roads:     Array[PackedVector2iArray]
	var trails:    Array[PackedVector2iArray]
	var searoutes: Array[PackedVector2iArray]

	func is_empty() -> bool:
		return roads.is_empty() and trails.is_empty() and searoutes.is_empty()

	func all_of_group(group: int) -> Array[PackedVector2iArray]:
		match group:
			0: return roads
			1: return trails
			2: return searoutes
		return []


static func load_file(path: String) -> RouteData:
	var result := RouteData.new()
	result.roads     = []
	result.trails    = []
	result.searoutes = []

	if not FileAccess.file_exists(path):
		push_warning("RouteLoader: file not found: " + path)
		return result

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("RouteLoader: cannot open: " + path)
		return result

	var hdr := f.get_buffer(6)
	if hdr.size() < 6 or hdr.slice(0, 4).get_string_from_ascii() != MAGIC:
		push_warning("RouteLoader: bad magic in: " + path)
		f.close()
		return result

	var route_count := hdr.decode_u16(4)
	for _i in route_count:
		var rhdr := f.get_buffer(3)
		if rhdr.size() < 3:
			break
		var group      := rhdr.decode_u8(0)
		var pt_count   := rhdr.decode_u16(1)
		var pts_raw    := f.get_buffer(pt_count * 4)

		var pts := PackedVector2iArray()
		pts.resize(pt_count)
		for j in pt_count:
			var base := j * 4
			pts[j] = Vector2i(pts_raw.decode_s16(base), pts_raw.decode_s16(base + 2))

		match group:
			0: result.roads.append(pts)
			1: result.trails.append(pts)
			2: result.searoutes.append(pts)

	f.close()
	return result
