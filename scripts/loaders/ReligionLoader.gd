## ReligionLoader — parse religions.bin into a religion id→name+color dictionary.
##
## Binary format (REL1):  identical layout to cultures.bin but magic "REL1"
##   type: 0=Folk 1=Organized 2=Cult 3=Heresy
##
## Usage:
##   var religions := ReligionLoader.load_file("res://worlds/cheia/religions.bin")
##   var r := religions.get(religion_id)
##   # r.name, r.color (Color), r.type
class_name ReligionLoader

const MAGIC       := "REL1"
const RECORD_SIZE := 10

class ReligionEntry:
	var id:    int
	var name:  String
	var color: Color
	var type:  int

	func type_name() -> String:
		match type:
			0: return "Folk"
			1: return "Organized"
			2: return "Cult"
			3: return "Heresy"
		return "Unknown"


class ReligionData:
	var _map: Dictionary  ## int id → ReligionEntry

	func _init() -> void:
		_map = {}

	func get(id: int) -> ReligionEntry:
		return _map.get(id, null)

	func all() -> Array:
		return _map.values()

	func is_empty() -> bool:
		return _map.is_empty()


static func load_file(path: String) -> ReligionData:
	var result := ReligionData.new()

	if not FileAccess.file_exists(path):
		push_warning("ReligionLoader: file not found: " + path)
		return result

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("ReligionLoader: cannot open: " + path)
		return result

	var hdr := f.get_buffer(10)
	if hdr.size() < 10 or hdr.slice(0, 4).get_string_from_ascii() != MAGIC:
		push_warning("ReligionLoader: bad magic in: " + path)
		f.close()
		return result

	var count       := hdr.decode_u16(4)
	var strtab_size := hdr.decode_u32(6)
	var strtab      := f.get_buffer(strtab_size)
	var raw         := f.get_buffer(count * RECORD_SIZE)
	f.close()

	for i in count:
		var base := i * RECORD_SIZE
		var e    := ReligionEntry.new()
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
