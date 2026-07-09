## BurgLoader — parse burgs.bin into an array of burg records.
##
## Binary format (BRG1):
##   Header 10 B: magic(4) + burg_count u16 + strtab_size u32
##   Strtab: null-terminated UTF-8 name strings
##   Records N×20 B: burg_id u16, state_id u16, culture_id u16,
##                   hex_q i16, hex_r i16, name_offset u32,
##                   population f32, type u8, flags u8
##
## type: 0=village 1=town 2=city 3=naval 4=capital
## flags bits: 0=capital 1=port 2=walls 3=citadel 4=plaza 5=temple 6=shanty
##
## Usage:
##   var burgs := BurgLoader.load_file("res://worlds/cheia/burgs.bin")
##   for b in burgs.all:
##       print(b.name, b.hex_q, b.hex_r)
##   var b := burgs.by_hex.get(Vector2i(q, r))
class_name BurgLoader

const MAGIC       := "BRG1"
const RECORD_SIZE := 20

class Burg:
	var burg_id:    int
	var state_id:   int
	var culture_id: int
	var hex_q:      int
	var hex_r:      int
	var name:       String
	var population: float
	var type:       int     ## 0=village 1=town 2=city 3=naval 4=capital
	var flags:      int

	func is_capital()  -> bool: return (flags & 1)  != 0
	func is_port()     -> bool: return (flags & 2)  != 0
	func has_walls()   -> bool: return (flags & 4)  != 0
	func has_citadel() -> bool: return (flags & 8)  != 0
	func has_plaza()   -> bool: return (flags & 16) != 0
	func has_temple()  -> bool: return (flags & 32) != 0
	func has_shanty()  -> bool: return (flags & 64) != 0

	func type_name() -> String:
		match type:
			0: return "Village"
			1: return "Town"
			2: return "City"
			3: return "Naval"
			4: return "Capital"
		return "Unknown"


class BurgData:
	var all:    Array[Burg]               ## all burgs, ordered as in file
	var by_hex: Dictionary                ## Vector2i(q,r) → Burg

	func is_empty() -> bool:
		return all.is_empty()


static func load_file(path: String) -> BurgData:
	var result := BurgData.new()
	result.all    = []
	result.by_hex = {}

	if not FileAccess.file_exists(path):
		push_warning("BurgLoader: file not found: " + path)
		return result

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("BurgLoader: cannot open: " + path)
		return result

	var hdr := f.get_buffer(10)
	if hdr.size() < 10 or hdr.slice(0, 4).get_string_from_ascii() != MAGIC:
		push_warning("BurgLoader: bad magic in: " + path)
		f.close()
		return result

	var burg_count  := hdr.decode_u16(4)
	var strtab_size := hdr.decode_u32(6)
	var strtab      := f.get_buffer(strtab_size)
	var raw         := f.get_buffer(burg_count * RECORD_SIZE)
	f.close()

	if raw.size() < burg_count * RECORD_SIZE:
		push_warning("BurgLoader: truncated file, expected %d burg records, got %d bytes: %s" %
			[burg_count, raw.size(), path])
		return result

	for i in burg_count:
		var base := i * RECORD_SIZE
		var b    := Burg.new()
		b.burg_id    = raw.decode_u16(base)
		b.state_id   = raw.decode_u16(base + 2)
		b.culture_id = raw.decode_u16(base + 4)
		b.hex_q      = raw.decode_s16(base + 6)
		b.hex_r      = raw.decode_s16(base + 8)
		var name_off := raw.decode_u32(base + 10)
		b.population = raw.decode_float(base + 14)
		b.type       = raw.decode_u8(base + 18)
		b.flags      = raw.decode_u8(base + 19)
		b.name       = _strtab_get(strtab, name_off)

		result.all.append(b)
		result.by_hex[Vector2i(b.hex_q, b.hex_r)] = b

	return result


static func _strtab_get(strtab: PackedByteArray, offset: int) -> String:
	if offset >= strtab.size():
		return ""
	var end := strtab.find(0, offset)
	if end < 0: end = strtab.size()
	return strtab.slice(offset, end).get_string_from_utf8()
