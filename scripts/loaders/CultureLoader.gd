## CultureLoader — parse cultures.bin into a culture id→name+color dictionary.
##
## Binary format (CUL1):
##   Header 10 B: magic(4) + count u16 + strtab_size u32
##   Strtab: null-terminated UTF-8 name strings
##   Records N×10 B: id u16, name_offset u32, r u8, g u8, b u8, type u8
##
## Usage:
##   var cultures := CultureLoader.load_file("res://worlds/cheia/cultures.bin")
##   var c := cultures.get(culture_id)
##   # c.name, c.color (Color), c.type
class_name CultureLoader

const MAGIC       := "CUL1"
const RECORD_SIZE := 10

class CultureEntry:
	var id:    int
	var name:  String
	var color: Color
	var type:  int


class CultureData:
	var _map: Dictionary  ## int id → CultureEntry

	func _init() -> void:
		_map = {}

	func lookup(id: int) -> CultureEntry:
		return _map.get(id, null)

	func all() -> Array:
		return _map.values()

	func is_empty() -> bool:
		return _map.is_empty()


static func load_file(path: String) -> CultureData:
	var result := CultureData.new()

	if not FileAccess.file_exists(path):
		push_warning("CultureLoader: file not found: " + path)
		return result

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("CultureLoader: cannot open: " + path)
		return result

	var hdr := f.get_buffer(10)
	if hdr.size() < 10 or hdr.slice(0, 4).get_string_from_ascii() != MAGIC:
		push_warning("CultureLoader: bad magic in: " + path)
		f.close()
		return result

	var count       := hdr.decode_u16(4)
	var strtab_size := hdr.decode_u32(6)
	var strtab      := f.get_buffer(strtab_size)
	var raw         := f.get_buffer(count * RECORD_SIZE)
	f.close()

	if raw.size() < count * RECORD_SIZE:
		push_warning("CultureLoader: truncated file, expected %d records, got %d bytes: %s" %
			[count, raw.size(), path])
		return result

	for i in count:
		var base := i * RECORD_SIZE
		var e    := CultureEntry.new()
		e.id    = raw.decode_u16(base)
		var name_off := raw.decode_u32(base + 2)
		e.color = Color8(raw.decode_u8(base + 6), raw.decode_u8(base + 7),
		                 raw.decode_u8(base + 8))
		e.type  = raw.decode_u8(base + 9)
		e.name  = _strtab_get(strtab, name_off)
		result._map[e.id] = e

	return result


static func _strtab_get(strtab: PackedByteArray, offset: int) -> String:
	if offset >= strtab.size():
		return ""
	var end := strtab.find(0, offset)
	if end < 0: end = strtab.size()
	return strtab.slice(offset, end).get_string_from_utf8()
