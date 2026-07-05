extends Node2D

## CombatMap — procedurally generated terrain-aware battlefield.
## Seeded from world hex (q,r): same hex always generates the same map.
## No disk caching; generation targets < 50ms.

const TERRAIN_PATH := "res://worlds/cheia/hex_terrain.bin"
const HEXBIN_PATH  := "res://worlds/cheia/hex_grid.hexbin"

const GRID_COLS := 28
const GRID_ROWS := 18

const FEAT_NONE  := 0
const FEAT_TRAIL := 1
const FEAT_ROAD  := 2
const FEAT_RIVER := 3

const DIRS: Array[Vector2i] = [
	Vector2i(0,-1), Vector2i(1,-1), Vector2i(1,0),
	Vector2i(0,1),  Vector2i(-1,1), Vector2i(-1,0)
]


class CombatHex:
	var terrain_idx: int   ## 0–2 within biome palette
	var height_m:    float
	var feature:     int   ## FEAT_*


var _hex_q:       int   = 0
var _hex_r:       int   = 0
var _biome_id:    int   = 0
var _terrain:     HexTerrainLoader.TerrainData = null
var _r_min:       int   = 0
var _tex_w:       int   = 0
var _hex_radius:  float = 40.0
var _base_elev_m: float = 0.0
var _h_var:       float = 20.0
var _hexes:       Array[Vector2i] = []
var _generated:   Dictionary = {}   ## Vector2i → CombatHex


func _ready() -> void:
	_hex_q    = Engine.get_meta("hex_q",        0)
	_hex_r    = Engine.get_meta("hex_r",        0)
	_biome_id = Engine.get_meta("hex_biome_id", 0)
	_load_hexbin_header()
	_terrain = HexTerrainLoader.load_file(TERRAIN_PATH, HEXBIN_PATH, _r_min, _tex_w)
	_compute_hex_radius()
	_hexes = _rect_hexes()
	_generate_terrain()
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


func _compute_hex_radius() -> void:
	var vp    := get_viewport_rect().size
	var r_col := vp.x / (sqrt(3.0) * (GRID_COLS + 0.5))
	var r_row := (vp.y - 80.0) / (1.5 * (GRID_ROWS + 0.333))
	_hex_radius = minf(r_col, r_row)


# ── Terrain generation ─────────────────────────────────────────────────────────

func _generate_terrain() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(_hex_q, _hex_r))

	var t_noise := FastNoiseLite.new()
	t_noise.seed       = rng.randi()
	t_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	t_noise.frequency  = 0.18

	var h_noise := FastNoiseLite.new()
	h_noise.seed       = rng.randi()
	h_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	h_noise.frequency  = 0.10

	var center_t: HexTerrainLoader.HexTerrain = null
	if _terrain and not _terrain.is_empty():
		center_t = _terrain.get_hex(_hex_q, _hex_r)
	if center_t != null:
		_base_elev_m = center_t.height * 4000.0 / 255.0

	_h_var = _height_range(_biome_id)

	for hqr in _hexes:
		var ch         := CombatHex.new()
		var tn: float   = t_noise.get_noise_2d(hqr.x, hqr.y)
		ch.terrain_idx  = 0 if tn < -0.20 else (1 if tn < 0.35 else 2)
		var hn: float   = h_noise.get_noise_2d(hqr.x, hqr.y)
		ch.height_m     = _base_elev_m + hn * _h_var
		ch.feature      = FEAT_NONE
		_generated[hqr] = ch

	if center_t == null:
		return

	if center_t.has_river():
		_place_path(rng, FEAT_RIVER, 2, 0.25)

	var has_road  := false
	var has_trail := false
	for d in 6:
		if center_t.has_road_on_dir(d):  has_road  = true
		if center_t.has_trail_on_dir(d): has_trail = true

	if has_road:  _place_path(rng, FEAT_ROAD,  1, 0.72)
	if has_trail: _place_path(rng, FEAT_TRAIL, 1, 0.50)


func _place_path(rng: RandomNumberGenerator, feat: int,
                 width: int, straightness: float) -> void:
	var half_c   := GRID_COLS / 2
	var half_r   := GRID_ROWS / 2
	var entry_dc := rng.randi_range(-half_c / 2, half_c / 2)
	var exit_dc  := rng.randi_range(-half_c / 2, half_c / 2)
	var meander  := 0.0

	for dr in range(-half_r, half_r + (GRID_ROWS % 2)):
		var t      := float(dr + half_r) / float(GRID_ROWS)
		var ideal: float = lerp(float(entry_dc), float(exit_dc), t)
		meander    += rng.randf_range(-1.0, 1.0) * (1.0 - straightness) * 2.0
		meander    *= 0.65
		var dc     := int(round(ideal + meander))
		dc          = clampi(dc, -half_c + 1, half_c - 2)

		for w in range(-(width / 2), (width + 1) / 2):
			var col_shift: int = -(dr >> 1)
			var key := Vector2i(_hex_q + dc + w + col_shift, _hex_r + dr)
			var ch: CombatHex = _generated.get(key)
			if ch != null and ch.feature < feat:
				ch.feature = feat


static func _height_range(biome_id: int) -> float:
	match biome_id:
		1:  return 60.0   # Hot Desert — dunes
		2:  return 45.0   # Cold Desert
		5:  return 30.0   # Tropical Forest
		7:  return 50.0   # Boreal Forest — ridges
		8:  return 10.0   # Wetland — flat
		9:  return 55.0   # Tundra
		10: return 30.0   # Glacier
		11: return 25.0   # Snow
		12: return 8.0    # Mangrove — flat
	return 20.0


# ── Scene building ─────────────────────────────────────────────────────────────

func _build_scene() -> void:
	var vp_size := get_viewport_rect().size
	var center  := vp_size * 0.5

	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.10)
	bg.size  = vp_size
	add_child(bg)

	for hqr in _hexes:
		_draw_hex(hqr.x, hqr.y, center)


func _rect_hexes() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var half_r := GRID_ROWS / 2
	var half_c := GRID_COLS / 2
	for dr in range(-half_r, half_r + (GRID_ROWS % 2)):
		var col_shift: int = -(dr >> 1)
		for dc in range(-half_c, half_c + (GRID_COLS % 2)):
			result.append(Vector2i(_hex_q + dc + col_shift, _hex_r + dr))
	return result


func _hex_to_pixel(q: int, r: int, center: Vector2) -> Vector2:
	return center + Vector2(
		_hex_radius * sqrt(3.0) * ((q - _hex_q) + (r - _hex_r) * 0.5),
		_hex_radius * 1.5       *  (r - _hex_r)
	)


func _hex_vertices(cx: float, cy: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var angle := deg_to_rad(60.0 * i + 30.0)
		pts.append(Vector2(cx + cos(angle) * _hex_radius,
		                   cy - sin(angle) * _hex_radius))
	return pts


func _draw_hex(q: int, r: int, center: Vector2) -> void:
	var pixel  := _hex_to_pixel(q, r, center)
	var verts  := _hex_vertices(pixel.x, pixel.y)
	var ch: CombatHex = _generated.get(Vector2i(q, r))

	var fill_col: Color
	if ch == null:
		fill_col = Color(0.3, 0.3, 0.3)
	elif ch.feature == FEAT_RIVER:
		fill_col = Color(0.18 + ch.terrain_idx * 0.04, 0.45, 0.82)
	else:
		fill_col = _terrain_color(_biome_id, ch.terrain_idx)
		var t: float = (ch.height_m - (_base_elev_m - _h_var)) / (2.0 * _h_var)
		var shade: float = lerp(0.55, 1.0, clampf(t, 0.0, 1.0))
		fill_col = fill_col * shade
		fill_col.a = 1.0

	var fill := Polygon2D.new()
	fill.polygon = verts
	fill.color   = fill_col
	add_child(fill)

	var border := Line2D.new()
	border.points        = PackedVector2Array(verts) + PackedVector2Array([verts[0]])
	border.width         = 1.0
	border.default_color = Color(0, 0, 0, 0.4)
	add_child(border)

	if ch == null:
		return

	match ch.feature:
		FEAT_ROAD:
			_draw_path_line(verts, Color(0.82, 0.72, 0.42, 0.9), 4.0)
		FEAT_TRAIL:
			_draw_path_line(verts, Color(0.55, 0.38, 0.22, 0.75), 2.5)


func _draw_path_line(verts: PackedVector2Array, col: Color, width: float) -> void:
	# Top vertex (i=1) to bottom vertex (i=4) — vertical road/trail stripe
	var line := Line2D.new()
	line.points        = PackedVector2Array([verts[1], verts[4]])
	line.width         = width
	line.default_color = col
	add_child(line)


# ── HUD ────────────────────────────────────────────────────────────────────────

func _setup_hud() -> void:
	var hud := CanvasLayer.new()
	add_child(hud)

	var center_ch: CombatHex = _generated.get(Vector2i(_hex_q, _hex_r))
	var info_parts: Array[String] = [_biome_name(_biome_id)]
	if center_ch != null:
		info_parts.append("elev %dm" % int(center_ch.height_m))
		match center_ch.feature:
			FEAT_RIVER: info_parts.append("river")
			FEAT_ROAD:  info_parts.append("road")
			FEAT_TRAIL: info_parts.append("trail")

	var info := Label.new()
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.text = "Hex  q=%d  r=%d   %dx%d\n%s" % [
		_hex_q, _hex_r, GRID_COLS, GRID_ROWS, "  ·  ".join(info_parts)]
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


# ── Terrain colour / biome name ────────────────────────────────────────────────

static func _terrain_color(biome_id: int, terrain_idx: int) -> Color:
	var i := clampi(terrain_idx, 0, 2)
	var p: Array[Color]
	match biome_id:
		0:  p = [Color(0.08,0.18,0.50), Color(0.12,0.28,0.62), Color(0.18,0.40,0.70)]
		1:  p = [Color(0.85,0.76,0.42), Color(0.72,0.60,0.38), Color(0.94,0.88,0.52)]
		2:  p = [Color(0.65,0.60,0.50), Color(0.55,0.50,0.42), Color(0.75,0.72,0.62)]
		3:  p = [Color(0.78,0.70,0.30), Color(0.65,0.55,0.25), Color(0.58,0.65,0.28)]
		4:  p = [Color(0.38,0.65,0.22), Color(0.44,0.72,0.28), Color(0.30,0.52,0.18)]
		5:  p = [Color(0.10,0.42,0.12), Color(0.08,0.32,0.10), Color(0.22,0.52,0.18)]
		6:  p = [Color(0.20,0.48,0.18), Color(0.28,0.55,0.22), Color(0.38,0.42,0.15)]
		7:  p = [Color(0.08,0.38,0.10), Color(0.22,0.32,0.14), Color(0.60,0.65,0.65)]
		8:  p = [Color(0.20,0.48,0.30), Color(0.28,0.38,0.20), Color(0.38,0.32,0.18)]
		9:  p = [Color(0.48,0.55,0.45), Color(0.38,0.42,0.36), Color(0.70,0.75,0.72)]
		10: p = [Color(0.72,0.88,0.95), Color(0.58,0.80,0.92), Color(0.88,0.96,1.00)]
		11: p = [Color(0.88,0.92,0.96), Color(0.75,0.82,0.88), Color(0.55,0.50,0.48)]
		12: p = [Color(0.16,0.40,0.28), Color(0.28,0.28,0.18), Color(0.08,0.30,0.35)]
		_:  return Color(0.5, 0.5, 0.5)
	return p[i]


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
