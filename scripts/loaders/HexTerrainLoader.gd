## HexTerrainLoader — parse hex_terrain.bin into a per-hex terrain dictionary.
##
## Binary format (HXT1):
##   Header 10 B: magic(4) + version u16 + hex_count u32
##   Records N×12 B: height u8, type_flags u8, culture_id u16, religion_id u16,
##                   river_flow u16, river_id u16, route_flags u16
##
## type_flags bits: 0=harbor 2=coastal 3=ocean (bit 1 unused — "port" is a
## burg attribute, not a per-hex one; see BurgLoader.Burg.is_port())
## route_flags bits: bit 0 = has_road, bit 6 = has_trail — both are HEX-LEVEL
##                   booleans ("does any road/trail touch this hex"), not
##                   per-edge-direction data. azgaar_to_hex.py's writer never
##                   sets bits 1-5 or 7-11, so has_road_on_dir(d)/
##                   has_trail_on_dir(d) below only ever return true for d=0.
##                   Bit 12 (ferry) is likewise never set by the current
##                   writer — has_ferry() always returns false today.
##
## Records are stored in hexbin sequential order (same traversal as hex_grid.hexbin),
## NOT in texture-pixel order. load_file requires the hexbin path to build the
## pixel→sequential-index map used by get_hex().
##
## Usage:
##   var terrain := HexTerrainLoader.load_file(
##       "res://worlds/cheia/hex_terrain.bin",
##       "res://worlds/cheia/hex_grid.hexbin",
##       r_min, tex_w)
##   var t := terrain.get_hex(q, r)
##   # t.height, t.culture_id, t.river_flow, t.route_flags, etc.
class_name HexTerrainLoader

const MAGIC := "HXT1"
const RECORD_SIZE := 12

## Holds a parsed terrain record for one hex.
class HexTerrain:
	var height:      int  ## 0–255 elevation
	var type_flags:  int  ## bits: 0=harbor 2=coastal 3=ocean (bit 1 unused)
	var culture_id:  int
	var religion_id: int
	var river_flow:  int  ## 0 = no river
	var river_id:    int  ## 0 = no river
	var route_flags: int  ## hex-level only: bit 0 = has_road, bit 6 = has_trail

	func is_harbor()  -> bool: return (type_flags & 1)  != 0
	func is_coastal() -> bool: return (type_flags & 4)  != 0
	func is_ocean()   -> bool: return (type_flags & 8)  != 0
	func has_river()  -> bool: return river_id > 0
	func has_road_on_dir(d: int)  -> bool: return (route_flags & (1 << d))       != 0
	func has_trail_on_dir(d: int) -> bool: return (route_flags & (1 << (d + 6))) != 0
	func has_ferry()  -> bool: return (route_flags & (1 << 12)) != 0


## Loaded terrain data, indexed by (q,r).
class TerrainData:
	var _data:    PackedByteArray
	## pix_map[pix] = sequential record index in _data, or -1 if no hex at that pixel.
	var _pix_map: PackedInt32Array
	var _r_min:   int
	var _tex_w:   int

	func _init(raw: PackedByteArray, pix_map: PackedInt32Array, r_min: int, tex_w: int) -> void:
		_data    = raw
		_pix_map = pix_map
		_r_min   = r_min
		_tex_w   = tex_w

	func get_hex(q: int, r: int) -> HexTerrain:
		var q_left := -(r >> 1) - 2
		var q_off  := q - q_left
		var r_off  := r - _r_min
		var pix    := r_off * _tex_w + q_off
		if pix < 0 or pix >= _pix_map.size():
			return null
		var seq_idx: int = _pix_map[pix]
		if seq_idx < 0:
			return null
		var base := seq_idx * RECORD_SIZE
		var t := HexTerrain.new()
		t.height      = _data.decode_u8(base)
		t.type_flags  = _data.decode_u8(base + 1)
		t.culture_id  = _data.decode_u16(base + 2)
		t.religion_id = _data.decode_u16(base + 4)
		t.river_flow  = _data.decode_u16(base + 6)
		t.river_id    = _data.decode_u16(base + 8)
		t.route_flags = _data.decode_u16(base + 10)
		return t

	func get_hex_debug(q: int, r: int) -> String:
		var q_left := -(r >> 1) - 2
		var q_off  := q - q_left
		var r_off  := r - _r_min
		var pix    := r_off * _tex_w + q_off
		if pix < 0 or pix >= _pix_map.size():
			return "pix=%d OOB (map=%d)" % [pix, _pix_map.size()]
		var seq_idx: int = _pix_map[pix]
		return "q=%d r=%d  q_off=%d r_off=%d  pix=%d  seq=%d  r_min=%d tex_w=%d" % [
			q, r, q_off, r_off, pix, seq_idx, _r_min, _tex_w]

	func is_empty() -> bool:
		return _data.is_empty()


## Load hex_terrain.bin. hexbin_path is used to build the pixel→record index map.
## r_min and tex_w come from the hexbin header (already parsed by the caller).
## Returns a TerrainData, or an empty TerrainData on failure.
static func load_file(path: String, hexbin_path: String, r_min: int, tex_w: int) -> TerrainData:
	var empty := TerrainData.new(PackedByteArray(), PackedInt32Array(), r_min, tex_w)

	if not FileAccess.file_exists(path):
		push_warning("HexTerrainLoader: file not found: " + path)
		return empty

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("HexTerrainLoader: cannot open: " + path)
		return empty

	var hdr := f.get_buffer(10)
	if hdr.size() < 10 or hdr.slice(0, 4).get_string_from_ascii() != MAGIC:
		push_warning("HexTerrainLoader: bad magic in: " + path)
		f.close()
		return empty

	var hex_count := hdr.decode_u32(6)
	var raw       := f.get_buffer(hex_count * RECORD_SIZE)
	f.close()

	if raw.size() != int(hex_count) * RECORD_SIZE:
		push_warning("HexTerrainLoader: truncated data in: " + path)
		return empty

	# Build pixel→sequential-index map from the hexbin traversal order.
	var pix_map := _build_pix_map(hexbin_path, r_min, tex_w)
	if pix_map.is_empty():
		push_warning("HexTerrainLoader: failed to build pix_map from: " + hexbin_path)
		return empty

	return TerrainData.new(raw, pix_map, r_min, tex_w)


## Reads hex_grid.hexbin and returns a PackedInt32Array of size tex_w*tex_h where
## pix_map[pix] is the sequential record index of the hex at that pixel, or -1.
static func _build_pix_map(hexbin_path: String, r_min: int, tex_w: int) -> PackedInt32Array:
	var empty := PackedInt32Array()

	if not FileAccess.file_exists(hexbin_path):
		push_warning("HexTerrainLoader: hexbin not found: " + hexbin_path)
		return empty

	var f := FileAccess.open(hexbin_path, FileAccess.READ)
	if f == null:
		push_warning("HexTerrainLoader: cannot open hexbin: " + hexbin_path)
		return empty

	var hdr := f.get_buffer(72)
	if hdr.size() < 72 or hdr.slice(0, 4).get_string_from_ascii() != "HXB1":
		push_warning("HexTerrainLoader: bad hexbin magic")
		f.close()
		return empty

	var version     := hdr.decode_u16(4)
	var biome_cnt   := hdr.decode_u16(6)
	var hex_count   := hdr.decode_u32(8)
	var strtab_size := hdr.decode_u32(12)
	var realm_cnt   := hdr.decode_u16(16)
	var prov_cnt    := hdr.decode_u16(18)
	var burg_cnt    := hdr.decode_u16(20)
	var tex_h       := hdr.decode_u16(28)
	var rec_size    := 11 if version >= 2 else 10

	# Skip name tables — we only need the hex records.
	f.get_buffer(strtab_size + biome_cnt * 4 + realm_cnt * 6 + prov_cnt * 10 + burg_cnt * 4)

	var recs := f.get_buffer(hex_count * rec_size)
	f.close()

	var pix_map := PackedInt32Array()
	pix_map.resize(tex_w * tex_h)
	pix_map.fill(-1)

	for i in hex_count:
		var base  := i * rec_size
		var q     := recs.decode_s16(base)
		var r     := recs.decode_s16(base + 2)
		var q_left := -(r >> 1) - 2
		var q_off  := q - q_left
		var r_off  := r - r_min
		if q_off < 0 or q_off >= tex_w or r_off < 0 or r_off >= tex_h:
			continue
		pix_map[r_off * tex_w + q_off] = i

	return pix_map
