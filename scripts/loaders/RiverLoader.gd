## RiverLoader -- parse rivers.bin into world-space polylines with taper data.
##
## Binary format (RIV1):
##   Header 6 B: magic(4) + river_count u16
##   Per river: point_count u16, source_width f32, mouth_width f32,
##              then point_count × (f32 x, f32 y)
##   Widths are in Azgaar world units; scale by hex_size * RIVER_SCALE in renderer.
class_name RiverLoader

const MAGIC := "RIV1"


## Returns Array of Dictionaries:
##   { "points": Array[Vector2], "source_width": float, "mouth_width": float }
static func load_file(path: String) -> Array:
	var result: Array = []

	if not FileAccess.file_exists(path):
		push_warning("RiverLoader: file not found: " + path)
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
		var rhdr := f.get_buffer(10)
		if rhdr.size() < 10:
			break
		var pt_count     := rhdr.decode_u16(0)
		var source_width := rhdr.decode_float(2)
		var mouth_width  := rhdr.decode_float(6)
		var pts_raw      := f.get_buffer(pt_count * 8)
		if pts_raw.size() < pt_count * 8:
			push_warning("RiverLoader: truncated file, river point data cut short: " + path)
			break

		var pts: Array[Vector2] = []
		pts.resize(pt_count)
		for j in pt_count:
			var base := j * 8
			pts[j] = Vector2(pts_raw.decode_float(base), pts_raw.decode_float(base + 4))

		result.append({
			"points":       pts,
			"source_width": source_width,
			"mouth_width":  mouth_width,
		})

	f.close()
	return result
