## RouteLoader -- parse routes.bin into road/trail/searoute world-space polylines.
##
## Binary format (RTE2):
##   Header 6 B: magic(4) + route_count u16
##   Per route: group u8, point_count u16, then point_count x (f32 x, f32 y)
##   x, y are world-space pixel coordinates (same space as _hex_to_world output).
##
## group: 0=road 1=trail 2=searoute
##
## Usage:
##   var routes := RouteLoader.load_file("res://worlds/cheia/routes.bin")
##   for r in routes["roads"]:   # Array[Vector2] world-space coords
##       draw_polyline(r)
class_name RouteLoader

const MAGIC := "RTE2"


## Returns Dictionary with keys "roads", "trails", "searoutes",
## each an Array of Array[Vector2] (world-space coordinates).
static func load_file(path: String) -> Dictionary:
	var result := { "roads": [], "trails": [], "searoutes": [] }

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
		var group    := rhdr.decode_u8(0)
		var pt_count := rhdr.decode_u16(1)
		var pts_raw  := f.get_buffer(pt_count * 8)
		if pts_raw.size() < pt_count * 8:
			push_warning("RouteLoader: truncated file, route point data cut short: " + path)
			break

		var pts: Array[Vector2] = []
		pts.resize(pt_count)
		for j in pt_count:
			var base := j * 8
			pts[j] = Vector2(pts_raw.decode_float(base), pts_raw.decode_float(base + 4))

		match group:
			0: result["roads"].append(pts)
			1: result["trails"].append(pts)
			2: result["searoutes"].append(pts)

	f.close()
	return result
