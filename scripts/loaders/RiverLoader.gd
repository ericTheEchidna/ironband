## RiverLoader — parse rivers.bin into named width+polyline records.
##
## Binary format (RIV1):
##   Header 6 B: magic(4) + river_count u16
##   Per river: id u16, width f32, point_count u16, then point_count × (i16 q, i16 r)
class_name RiverLoader

const MAGIC := "RIV1"

class RiverData:
	var id:     int
	var width:  float
	var points: Array  # Array of Vector2i


static func load_file(path: String) -> Array:
	var result: Array = []

	if not FileAccess.file_exists(path):
		push_warning("RiverLoader: not found: " + path)
		return result

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("RiverLoader: cannot open: " + path)
		return result

	var hdr := f.get_buffer(6)
	if hdr.size() < 6 or hdr.slice(0, 4).get_string_from_ascii() != MAGIC:
		push_warning("RiverLoader: bad magic in: " + path)
		f.close()
		return result

	var river_count := hdr.decode_u16(4)
	for _i in river_count:
		var rhdr := f.get_buffer(8)
		if rhdr.size() < 8:
			break
		var rv       := RiverData.new()
		rv.id         = rhdr.decode_u16(0)
		rv.width      = rhdr.decode_float(2)
		var pt_count  := rhdr.decode_u16(6)
		var pts_raw   := f.get_buffer(pt_count * 4)
		for j in pt_count:
			var base := j * 4
			rv.points.append(Vector2i(pts_raw.decode_s16(base), pts_raw.decode_s16(base + 2)))
		result.append(rv)

	f.close()
	return result
