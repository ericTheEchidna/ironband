extends Node2D

## CombatMap — terrain-aware 19-hex tactical grid.
## Reads hex_terrain.bin for the active world hex + 2-ring neighbourhood.
## Visual placeholder: no units, no game logic.

const TERRAIN_PATH  := "res://worlds/cheia/hex_terrain.bin"
const HEXBIN_PATH   := "res://worlds/cheia/hex_grid.hexbin"
const HEX_RADIUS    := 100.0   # pixels, pointy-top vertex-to-center

# Pointy-top axial neighbour directions: N, NE, SE, S, SW, NW
const DIRS := [Vector2i(0,-1), Vector2i(1,-1), Vector2i(1,0),
               Vector2i(0,1),  Vector2i(-1,1),  Vector2i(-1,0)]

var _hex_q:    int = 0
var _hex_r:    int = 0
var _biome_id: int = 0

var _terrain: HexTerrainLoader.TerrainData = null
var _r_min:   int = 0
var _tex_w:   int = 0


func _ready() -> void:
	_hex_q    = Engine.get_meta("hex_q",        0)
	_hex_r    = Engine.get_meta("hex_r",        0)
	_biome_id = Engine.get_meta("hex_biome_id", 0)

	_load_hexbin_header()
	_terrain = HexTerrainLoader.load_file(TERRAIN_PATH, _r_min, _tex_w)

	_build_scene()
	_setup_hud()


func _load_hexbin_header() -> void:
	if not FileAccess.file_exists(HEXBIN_PATH):
		return
	var f := FileAccess.open(HEXBIN_PATH, FileAccess.READ)
	if f == null:
		return
	var hdr := f.get_buffer(72)
	f.close()
	if hdr.size() < 72:
		return
	_r_min = hdr.decode_s16(22)
	_tex_w = hdr.decode_u16(26)


func _build_scene() -> void:
	var vp_size := get_viewport_rect().size
	var center  := vp_size * 0.5

	# Dark background
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.10)
	bg.size  = vp_size
	add_child(bg)

	# Draw 19 hexes: center + ring 1 (6) + ring 2 (12)
	var hexes_to_draw: Array[Vector2i] = _ring2_hexes(_hex_q, _hex_r)
	for hqr in hexes_to_draw:
		_draw_hex(hqr.x, hqr.y, center)


func _ring2_hexes(cq: int, cr: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	result.append(Vector2i(cq, cr))
	# Ring 1
	for d in DIRS:
		result.append(Vector2i(cq + d.x, cr + d.y))
	# Ring 2 — standard hex ring walk: start SW, step each of 6 edge directions
	var cursor := Vector2i(cq + DIRS[4].x * 2, cr + DIRS[4].y * 2)
	for side in 6:
		for _step in 2:
			result.append(cursor)
			cursor += DIRS[side]
	return result


func _hex_to_pixel(q: int, r: int, center: Vector2) -> Vector2:
	var sqrt3 := sqrt(3.0)
	return center + Vector2(
		HEX_RADIUS * sqrt3 * (q - _hex_q + (r - _hex_r) * 0.5),
		HEX_RADIUS * 1.5   *  (r - _hex_r)
	)


func _hex_vertices(cx: float, cy: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var angle := deg_to_rad(60.0 * i + 30.0)  # pointy-top
		pts.append(Vector2(cx + cos(angle) * HEX_RADIUS,
		                   cy - sin(angle) * HEX_RADIUS))
	return pts


func _draw_hex(q: int, r: int, center: Vector2) -> void:
	var pixel := _hex_to_pixel(q, r, center)
	var verts := _hex_vertices(pixel.x, pixel.y)

	var t: HexTerrainLoader.HexTerrain = null
	if _terrain and not _terrain.is_empty():
		t = _terrain.get_hex(q, r)

	# Base colour from biome of the center hex, height-shaded
	var base_col := _biome_color(_biome_id)
	if t != null:
		var shade := lerp(0.55, 1.0, float(t.height) / 255.0)
		base_col = base_col * shade
		base_col.a = 1.0

	# Hex fill
	var fill := Polygon2D.new()
	fill.polygon = verts
	fill.color   = base_col
	add_child(fill)

	# Hex border
	var border := Line2D.new()
	border.points        = PackedVector2Array(verts) + PackedVector2Array([verts[0]])
	border.width         = 1.5
	border.default_color = Color(0, 0, 0, 0.6)
	add_child(border)

	if t == null:
		return

	# River edges — blue line across each edge where river flows
	if t.has_river():
		for d in 6:
			var nb_qr := Vector2i(q, r) + DIRS[d]
			if _terrain:
				var nb_t := _terrain.get_hex(nb_qr.x, nb_qr.y)
				if nb_t != null and nb_t.has_river() and nb_t.river_id == t.river_id:
					_draw_edge_line(verts, d, Color(0.25, 0.55, 0.90, 0.85), 3.0)

	# Road edges — tan line
	for d in 6:
		if t.has_road_on_dir(d):
			_draw_edge_line(verts, d, Color(0.82, 0.72, 0.42, 0.9), 2.5)

	# Trail edges — thin brown dashed approximation (shorter line)
	for d in 6:
		if t.has_trail_on_dir(d):
			_draw_edge_line(verts, d, Color(0.55, 0.38, 0.22, 0.7), 1.5)

	# Harbor marker
	if t.is_harbor():
		var lbl := Label.new()
		lbl.text     = "⚓"
		lbl.position = pixel - Vector2(10, 10)
		lbl.add_theme_font_size_override("font_size", 14)
		add_child(lbl)


func _draw_edge_line(verts: PackedVector2Array, dir: int,
                     col: Color, width: float) -> void:
	var v0 := verts[dir]
	var v1 := verts[(dir + 1) % 6]
	var a := v0.lerp(v1, 0.2)
	var b := v0.lerp(v1, 0.8)
	var line := Line2D.new()
	line.points        = PackedVector2Array([a, b])
	line.width         = width
	line.default_color = col
	add_child(line)


func _setup_hud() -> void:
	var hud := CanvasLayer.new()
	add_child(hud)

	# Hex info
	var t: HexTerrainLoader.HexTerrain = null
	if _terrain and not _terrain.is_empty():
		t = _terrain.get_hex(_hex_q, _hex_r)

	var info_parts: Array[String] = []
	info_parts.append(_biome_name(_biome_id))
	if t != null:
		var elev_m := int(t.height * 4000.0 / 255.0)
		info_parts.append("elev %dm" % elev_m)
		if t.has_river():    info_parts.append("river")
		if t.has_road_on_dir(0) or t.has_road_on_dir(1) or t.has_road_on_dir(2) \
		or t.has_road_on_dir(3) or t.has_road_on_dir(4) or t.has_road_on_dir(5):
			info_parts.append("road")
		if t.is_harbor():    info_parts.append("harbor")
		if t.is_coastal():   info_parts.append("coast")

	var info := Label.new()
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.text = "Hex  q=%d  r=%d\n%s" % [_hex_q, _hex_r, "  ·  ".join(info_parts)]
	info.add_theme_color_override("font_color", Color.WHITE)
	info.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	info.add_theme_constant_override("shadow_offset_x", 1)
	info.add_theme_constant_override("shadow_offset_y", 1)
	info.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	info.offset_left = 8
	info.offset_top  = 8
	hud.add_child(info)

	var btn := Button.new()
	btn.text = "← Region"
	btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	btn.offset_left   =   8
	btn.offset_right  = 120
	btn.offset_bottom =  -8
	btn.offset_top    = -44
	btn.pressed.connect(_return_to_region)
	hud.add_child(btn)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
			_return_to_region()


func _return_to_region() -> void:
	GameState.go_regional()


# ── Biome colour / name ───────────────────────────────────────────────────────

static func _biome_color(id: int) -> Color:
	match id:
		0:  return Color(0.10, 0.25, 0.55)   # Marine
		1:  return Color(0.88, 0.79, 0.38)   # Hot desert
		2:  return Color(0.76, 0.72, 0.60)   # Cold desert
		3:  return Color(0.79, 0.78, 0.35)   # Savanna
		4:  return Color(0.38, 0.65, 0.25)   # Grassland
		5:  return Color(0.15, 0.52, 0.18)   # Tropical forest
		6:  return Color(0.22, 0.52, 0.20)   # Temperate forest
		7:  return Color(0.05, 0.40, 0.10)   # Boreal forest
		8:  return Color(0.10, 0.42, 0.32)   # Wetland
		9:  return Color(0.30, 0.50, 0.45)   # Tundra
		10: return Color(0.72, 0.78, 0.80)   # Glacier
		11: return Color(0.88, 0.94, 1.00)   # Snow
		12: return Color(0.18, 0.40, 0.35)   # Mangrove
	return Color(0.5, 0.5, 0.5)


static func _biome_name(id: int) -> String:
	match id:
		0:  return "Marine"
		1:  return "Hot Desert"
		2:  return "Cold Desert"
		3:  return "Savanna"
		4:  return "Grassland"
		5:  return "Tropical Forest"
		6:  return "Temperate Forest"
		7:  return "Boreal Forest"
		8:  return "Wetland"
		9:  return "Tundra"
		10: return "Glacier"
		11: return "Snow"
		12: return "Mangrove"
	return "Unknown"
