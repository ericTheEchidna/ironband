## HexTerrainLoader — parse hex_terrain.bin into a per-hex terrain dictionary.
##
## Binary format (HXT1):
##   Header 10 B: magic(4) + version u16 + hex_count u32
##   Records N×12 B: height u8, type_flags u8, culture_id u16, religion_id u16,
##                   river_flow u16, river_id u16, route_flags u16
##
## type_flags bits: 0=harbor 1=port 2=coastal 3=ocean
## route_flags bits: 0-5=road on edge N/NE/SE/S/SW/NW, 6-11=trail on same edges
##
## Usage:
##   var terrain := HexTerrainLoader.load_file("res://worlds/cheia/hex_terrain.bin",
##                                              r_min, tex_w)
##   var t := terrain.get_hex(q, r)
##   # t.height, t.culture_id, t.river_flow, t.route_flags, etc.
class_name HexTerrainLoader

const MAGIC := "HXT1"
const RECORD_SIZE := 12

## Holds a parsed terrain record for one hex.
class HexTerrain:
	var height:      int  ## 0–255 elevation
	var type_flags:  int  ## bits: 0=harbor 1=port 2=coastal 3=ocean
	var culture_id:  int
	var religion_id: int
	var river_flow:  int  ## 0 = no river
	var river_id:    int  ## 0 = no river
	var route_flags: int  ## bits 0-5 road, 6-11 trail per edge direction

	func is_harbor()  -> bool: return (type_flags & 1)  != 0
	func is_port()    -> bool: return (type_flags & 2)  != 0
	func is_coastal() -> bool: return (type_flags & 4)  != 0
	func is_ocean()   -> bool: return (type_flags & 8)  != 0
	func has_river()  -> bool: return river_flow > 0
	func has_road_on_dir(d: int)  -> bool: return (route_flags & (1 << d))       != 0
	func has_trail_on_dir(d: int) -> bool: return (route_flags & (1 << (d + 6))) != 0


## Loaded terrain data, indexed by (q,r).
class TerrainData:
	var _data:  PackedByteArray
	var _r_min: int
	var _tex_w: int

	func _init(raw: PackedByteArray, r_min: int, tex_w: int) -> void:
		_data  = raw
		_r_min = r_min
		_tex_w = tex_w

	func get_hex(q: int, r: int) -> HexTerrain:
		var q_left := -(r >> 1) - 2
		var q_off  := q - q_left
		var r_off  := r - _r_min
		var pix    := r_off * _tex_w + q_off
		var base   := pix * RECORD_SIZE
		if base < 0 or base + RECORD_SIZE > _data.size():
			return null
		var t := HexTerrain.new()
		t.height      = _data.decode_u8(base)
		t.type_flags  = _data.decode_u8(base + 1)
		t.culture_id  = _data.decode_u16(base + 2)
		t.religion_id = _data.decode_u16(base + 4)
		t.river_flow  = _data.decode_u16(base + 6)
		t.river_id    = _data.decode_u16(base + 8)
		t.route_flags = _data.decode_u16(base + 10)
		return t

	func is_empty() -> bool:
		return _data.is_empty()


## Load hex_terrain.bin. r_min and tex_w come from the hexbin header.
## Returns a TerrainData, or an empty TerrainData on failure.
static func load_file(path: String, r_min: int, tex_w: int) -> TerrainData:
	if not FileAccess.file_exists(path):
		push_warning("HexTerrainLoader: file not found: " + path)
		return TerrainData.new(PackedByteArray(), r_min, tex_w)

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("HexTerrainLoader: cannot open: " + path)
		return TerrainData.new(PackedByteArray(), r_min, tex_w)

	var hdr := f.get_buffer(10)
	if hdr.size() < 10 or hdr.slice(0, 4).get_string_from_ascii() != MAGIC:
		push_warning("HexTerrainLoader: bad magic in: " + path)
		f.close()
		return TerrainData.new(PackedByteArray(), r_min, tex_w)

	var hex_count := hdr.decode_u32(6)
	var raw       := f.get_buffer(hex_count * RECORD_SIZE)
	f.close()

	if raw.size() != int(hex_count) * RECORD_SIZE:
		push_warning("HexTerrainLoader: truncated data in: " + path)
		return TerrainData.new(PackedByteArray(), r_min, tex_w)

	return TerrainData.new(raw, r_min, tex_w)
