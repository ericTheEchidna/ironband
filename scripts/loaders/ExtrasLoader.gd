## ExtrasLoader — parse extras.bin (EXT1): a zlib-compressed JSON blob of
## Azgaar data that doesn't fit the fixed-width binary formats (goods,
## markets, per-burg garrisons, state diplomacy/campaigns, COA heraldry,
## nameBases, settings/info). See ibp-engine's azgaar_extras.py for exactly
## what's in it — both Azgaar converters build this blob from the same code
## so they can't drift on its contents.
##
## Usage:
##   var extras := ExtrasLoader.load_file("res://worlds/cheia/extras.bin")
##   var top := extras.top_goods_for_burg(burg_id, 5)   # [{name, stock}, ...]
##   var garrisons := extras.garrisons_for_burg(burg_id) # [{name, units}, ...]
class_name ExtrasLoader

const MAGIC := "EXT1"
## Generous cap for PackedByteArray.decompress_dynamic — the header only
## stores the compressed size, not the decompressed one, so this just needs
## to comfortably exceed any real extras.bin (currently ~a few MB decompressed).
const MAX_DECOMPRESSED_SIZE := 64 * 1024 * 1024


class ExtrasData:
	var _goods_by_id:   Dictionary  ## int good id -> String name
	var _markets:       Array       ## raw markets[] rows (centerBurgId, goods{})
	var _burg_garrisons: Dictionary ## String burg_id -> Array of {name, units}

	func _init(goods: Array, markets: Array, burg_garrisons: Dictionary) -> void:
		_goods_by_id = {}
		for g in goods:
			if g is Dictionary and g.has("i"):
				_goods_by_id[int(g["i"])] = str(g.get("name", ""))
		_markets = markets
		_burg_garrisons = burg_garrisons

	func is_empty() -> bool:
		return _markets.is_empty() and _burg_garrisons.is_empty()

	## Top `count` goods by stock (descending, stock > 0 only) for the market
	## centered on this burg. Empty array if the burg isn't a market center.
	func top_goods_for_burg(burg_id: int, count: int = 5) -> Array:
		for m in _markets:
			if not (m is Dictionary) or int(m.get("centerBurgId", -1)) != burg_id:
				continue
			var goods_dict: Dictionary = m.get("goods", {})
			var rows: Array = []
			for good_id_str in goods_dict:
				var entry: Dictionary = goods_dict[good_id_str]
				var stock: float = float(entry.get("stock", 0.0))
				if stock <= 0.0:
					continue
				rows.append({
					"name":  _goods_by_id.get(int(good_id_str), "Good #" + str(good_id_str)),
					"stock": stock,
				})
			rows.sort_custom(func(a, b): return a["stock"] > b["stock"])
			return rows.slice(0, count)
		return []

	## Regiments stationed exactly in this burg (name + unit-type counts).
	## Most burgs have none — a garrison is a notable fact when present.
	func garrisons_for_burg(burg_id: int) -> Array:
		return _burg_garrisons.get(str(burg_id), [])


static func load_file(path: String) -> ExtrasData:
	var empty := ExtrasData.new([], [], {})

	if not FileAccess.file_exists(path):
		push_warning("ExtrasLoader: file not found: " + path)
		return empty

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("ExtrasLoader: cannot open: " + path)
		return empty

	var hdr := f.get_buffer(8)
	if hdr.size() < 8 or hdr.slice(0, 4).get_string_from_ascii() != MAGIC:
		push_warning("ExtrasLoader: bad magic in: " + path)
		f.close()
		return empty

	var blob_size := hdr.decode_u32(4)
	var blob := f.get_buffer(blob_size)
	f.close()

	if blob.size() < blob_size:
		push_warning("ExtrasLoader: truncated file: " + path)
		return empty

	var json_bytes := blob.decompress_dynamic(MAX_DECOMPRESSED_SIZE, FileAccess.COMPRESSION_DEFLATE)
	if json_bytes.is_empty():
		push_warning("ExtrasLoader: decompression failed: " + path)
		return empty

	var parsed = JSON.parse_string(json_bytes.get_string_from_utf8())
	if parsed == null or not (parsed is Dictionary):
		push_warning("ExtrasLoader: JSON parse failed: " + path)
		return empty

	var extras: Dictionary = parsed
	return ExtrasData.new(
		extras.get("goods", []),
		extras.get("markets", []),
		extras.get("burg_garrisons", {}))
