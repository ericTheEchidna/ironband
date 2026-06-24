extends Node2D

const HEX_GRID_PATH         := "res://worlds/cheia/hex_grid.hexbin"
const LOCALES_PATH          := "res://worlds/cheia/locales.json"
const SHADER_PATH           := "res://shaders/WorldMap.gdshader"
const DEBUG_FOCUS_HEX       := Vector2i(373, 252)

@export var zoom_thresh_province: float = 3.0
@export var zoom_thresh_hex:      float = 25.0

var _camera: Camera2D
var _rect:   ColorRect
var _mat:    ShaderMaterial

# Set from hexbin header at startup (fast 72-byte read).
var _hex_size:      float = 1.0
var _origin_x:      float = 0.0
var _origin_y:      float = 0.0
var _r_min_val:     int   = 0
var _map_w:         float = 0.0
var _map_h:         float = 0.0
var _tex_w_global:  int   = 0
var _tex_h_global:  int   = 0

# Locale grid — from locales.json.
var _locales_cols:     int   = 5
var _locales_rows:     int   = 2
var _locale_col:       int   = -1
var _locale_row:       int   = -1
var _locale_world_rect: Rect2 = Rect2()
var _region_fog_rad:   int   = 6

var _hex_img:           Image = null
var _province_img_data: Image = null
var _realm_names:       Dictionary[int, String] = {}
var _province_names:    Dictionary[int, String] = {}
var _province_capitals: Dictionary[int, String] = {}

var _is_dragging  := false
var _drag_start   := Vector2.ZERO
var _camera_start := Vector2.ZERO
var _drag_dist    := 0.0

var _hover_label: Label
var _sel_panel:   PanelContainer
var _sel_label:   Label
var _mp_label:    Label
var _zoom_label:  Label
var _enter_btn:   Button

var _fog_img: Image        = null
var _fog_tex: ImageTexture = null

var _marker: Node2D = null
var _mp_current: int      = 0
var _mp_max:     int      = 6
var _camera_follow: bool  = false
var _camera_target: Vector2 = Vector2.ZERO
var _party_world_pos: Vector2 = Vector2.ZERO
var _has_party_pos:   bool    = false
var _selected_hex:    Vector2i = Vector2i(-9999, -9999)
var _startup_center_pending: bool = true


func _ready() -> void:
	_camera = $Camera2D
	_camera.anchor_mode = Camera2D.ANCHOR_MODE_DRAG_CENTER
	_rect    = $WorldRect
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.visible = false
	_setup_hud()

	# Read world dimensions from hexbin header (72 bytes — instant).
	var hdr := _read_hexbin_header(HEX_GRID_PATH)
	if hdr.is_empty():
		$LoadingLabel.text = "Error: cannot read " + HEX_GRID_PATH
		return
	_hex_size     = hdr["hex_size"]
	_origin_x     = hdr["origin_x"]
	_origin_y     = hdr["origin_y"]
	_map_w        = hdr["map_w"]
	_map_h        = hdr["map_h"]
	_r_min_val    = hdr["r_min"]
	_tex_w_global = hdr["tex_w"]
	_tex_h_global = hdr["tex_h"]

	var lcfg := _load_json(LOCALES_PATH)
	_locales_cols   = int(lcfg.get("cols",       5))
	_locales_rows   = int(lcfg.get("rows",       2))
	_region_fog_rad = int(lcfg.get("fog_radius", 6))

	$LoadingLabel.text = "Loading map…"
	$LoadingLabel.visible = true
	call_deferred("_load_static_map_preview")


func _load_static_map_preview() -> void:
	var result := _load_hexbin(HEX_GRID_PATH,
		_origin_x, _origin_x + _map_w,
		_origin_y, _origin_y + _map_h,
		0.0)
	if result.is_empty():
		$LoadingLabel.text = "Error loading map"
		return

	_locale_world_rect = Rect2(Vector2(_origin_x, _origin_y), Vector2(_map_w, _map_h))

	if _fog_img == null:
		_fog_img = Image.create(_tex_w_global, _tex_h_global, false, Image.FORMAT_RGBA8)
		_fog_img.fill(Color(1, 0, 0, 1))
		_fog_tex = ImageTexture.create_from_image(_fog_img)

	var tex      := ImageTexture.create_from_image(_hex_img)
	var burg_tex := ImageTexture.create_from_image(_province_img_data)

	var shader := load(SHADER_PATH) as Shader
	_mat        = ShaderMaterial.new()
	_mat.shader = shader
	_mat.set_shader_parameter("hex_size",          _hex_size)
	_mat.set_shader_parameter("origin_x",          _origin_x)
	_mat.set_shader_parameter("origin_y",          _origin_y)
	_mat.set_shader_parameter("map_w",             _map_w)
	_mat.set_shader_parameter("map_h",             _map_h)
	_mat.set_shader_parameter("hex_data",          tex)
	_mat.set_shader_parameter("burg_data",         burg_tex)
	_mat.set_shader_parameter("tex_width",         _tex_w_global)
	_mat.set_shader_parameter("tex_height",        _tex_h_global)
	_mat.set_shader_parameter("r_min",             _r_min_val)
	_mat.set_shader_parameter("selected_q",        -9999)
	_mat.set_shader_parameter("selected_r",        -9999)
	_mat.set_shader_parameter("selected_realm_id", -1)
	_mat.set_shader_parameter("selected_burg_id",  -1)
	_mat.set_shader_parameter("selection_mode",     0)
	_mat.set_shader_parameter("fog_data",           _fog_tex)

	_rect.position = Vector2(_origin_x, _origin_y)
	_rect.size     = Vector2(_map_w, _map_h)
	_rect.material = _mat
	_rect.visible  = true

	var vp_size  := get_viewport_rect().size
	var fit_zoom := vp_size.x / maxf(_map_w, 1.0)
	var focus_world := _hex_to_world(DEBUG_FOCUS_HEX.x, DEBUG_FOCUS_HEX.y)
	_camera.position = focus_world
	_camera_target = focus_world
	_camera_follow = false
	_camera.zoom = Vector2(fit_zoom, fit_zoom)
	_mat.set_shader_parameter("camera_zoom", fit_zoom)
	_update_zoom_label(fit_zoom)

	if _marker == null:
		var MarkerScript := preload("res://scripts/shared/PartyMarker.gd")
		_marker = MarkerScript.new()
		_marker.z_index = 10
		add_child(_marker)
		_marker.setup(_hex_size)
	_marker.visible = false  # hidden until engine reports party position

	$LoadingLabel.visible = false


func _process(delta: float) -> void:
	if _camera_follow:
		_camera.position = _camera.position.lerp(_camera_target, 1.0 - pow(0.01, delta))
	if _marker and _marker.visible:
		_marker.scale = Vector2.ONE / _camera.zoom.x


func _notification(_what: int) -> void:
	pass


func _setup_hud() -> void:
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)

	_hover_label = Label.new()
	_hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_label.visible = false
	_hover_label.add_theme_color_override("font_color", Color.WHITE)
	_hover_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	_hover_label.add_theme_constant_override("shadow_offset_x", 1)
	_hover_label.add_theme_constant_override("shadow_offset_y", 1)
	hud.add_child(_hover_label)

	_sel_panel = PanelContainer.new()
	_sel_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sel_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_sel_panel.visible = false
	hud.add_child(_sel_panel)

	_sel_label = Label.new()
	_sel_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sel_panel.add_child(_sel_label)

	_mp_label = Label.new()
	_mp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mp_label.text = "MP: – / –"
	_sel_panel.add_child(_mp_label)

	_zoom_label = Label.new()
	_zoom_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_zoom_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_zoom_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_zoom_label.offset_right = -8
	_zoom_label.offset_top   = 8
	_zoom_label.add_theme_color_override("font_color", Color.WHITE)
	_zoom_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	_zoom_label.add_theme_constant_override("shadow_offset_x", 1)
	_zoom_label.add_theme_constant_override("shadow_offset_y", 1)
	hud.add_child(_zoom_label)

	_enter_btn = Button.new()
	_enter_btn.text = "Enter Hex →"
	_enter_btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_enter_btn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_enter_btn.grow_vertical   = Control.GROW_DIRECTION_BEGIN
	_enter_btn.offset_right  = -8
	_enter_btn.offset_bottom = -8
	_enter_btn.offset_left   = -140
	_enter_btn.offset_top    = -44
	_enter_btn.visible = false
	_enter_btn.pressed.connect(_enter_local)
	hud.add_child(_enter_btn)


# ── Locale loading ─────────────────────────────────────────────────────────────

func _load_locale_then_place_party(q: int, r: int, mp: int, mp_max: int) -> void:
	await get_tree().process_frame
	var bounds := _locale_hex_bounds(_locale_col, _locale_row)

	var result := _load_hexbin(HEX_GRID_PATH,
		bounds["wx_min"], bounds["wx_max"],
		bounds["wy_min"], bounds["wy_max"],
		bounds["pad_world"])
	if result.is_empty():
		$LoadingLabel.text = "Error loading locale"
		return

	_locale_world_rect = Rect2(
		Vector2(bounds["wx_min"], bounds["wy_min"]),
		Vector2(bounds["world_w"], bounds["world_h"]))

	# Fog: allocate once per locale (full world dims so fog persists across locales).
	if _fog_img == null:
		_fog_img = Image.create(_tex_w_global, _tex_h_global, false, Image.FORMAT_RGBA8)
		_fog_img.fill(Color(0, 0, 0, 0))
		_fog_tex = ImageTexture.create_from_image(_fog_img)

	var tex      := ImageTexture.create_from_image(_hex_img)
	var burg_tex := ImageTexture.create_from_image(_province_img_data)

	var shader := load(SHADER_PATH) as Shader
	_mat        = ShaderMaterial.new()
	_mat.shader = shader
	# Always pass global origin + full world dims to the shader.
	# The shader uses origin_x/y for both UV→world and world→hex, so they must
	# be consistent. The ColorRect covers the full world; the camera bounds to
	# the locale so the user only sees locale data.
	_mat.set_shader_parameter("hex_size",          _hex_size)
	_mat.set_shader_parameter("origin_x",          _origin_x)
	_mat.set_shader_parameter("origin_y",          _origin_y)
	_mat.set_shader_parameter("map_w",             _map_w)
	_mat.set_shader_parameter("map_h",             _map_h)
	_mat.set_shader_parameter("hex_data",          tex)
	_mat.set_shader_parameter("burg_data",         burg_tex)
	_mat.set_shader_parameter("tex_width",         _tex_w_global)
	_mat.set_shader_parameter("tex_height",        _tex_h_global)
	_mat.set_shader_parameter("r_min",             _r_min_val)
	_mat.set_shader_parameter("selected_q",        -9999)
	_mat.set_shader_parameter("selected_r",        -9999)
	_mat.set_shader_parameter("selected_realm_id", -1)
	_mat.set_shader_parameter("selected_burg_id",  -1)
	_mat.set_shader_parameter("selection_mode",     0)
	_mat.set_shader_parameter("fog_data",           _fog_tex)

	_rect.position = Vector2(_origin_x, _origin_y)
	_rect.size     = Vector2(_map_w, _map_h)
	_rect.material = _mat
	_rect.visible  = true

	# Camera: fit locale width to viewport, centered on locale for now.
	# _finish_party_setup will immediately re-center on the party marker.
	var vp_size  := get_viewport_rect().size
	var fit_zoom := vp_size.x / float(bounds["world_w"])
	_camera.zoom = Vector2(fit_zoom, fit_zoom)
	_mat.set_shader_parameter("camera_zoom", fit_zoom)
	_update_zoom_label(fit_zoom)

	# Party marker (create once, reuse on locale transitions).
	if _marker == null:
		var MarkerScript := preload("res://scripts/shared/PartyMarker.gd")
		_marker = MarkerScript.new()
		_marker.z_index = 10
		add_child(_marker)
		_marker.setup(_hex_size)

	$LoadingLabel.visible = false
	_finish_party_setup(q, r, mp, mp_max)


func _finish_party_setup(q: int, r: int, mp: int, mp_max: int) -> void:
	_mp_current = mp
	_mp_max     = mp_max
	_update_mp_hud()
	_sel_panel.visible = true
	var party_wpos := _hex_to_world(q, r)
	_party_world_pos = party_wpos   # always the actual party hex, never map center
	_has_party_pos   = true
	_reveal_fog(q, r, _region_fog_rad)
	var cam_pos := party_wpos
	if _startup_center_pending:
		cam_pos = _map_center_world()  # only the camera starts at map center
		_startup_center_pending = false
	_camera.position = cam_pos
	_camera_target = cam_pos
	_camera_follow = false
	if _marker:
		_marker.place_at(party_wpos)  # marker always at party hex
		_marker.visible = true


# ── Locale helpers ─────────────────────────────────────────────────────────────

func _hex_to_locale(q: int, r: int) -> Vector2i:
	var wpos := _hex_to_world(q, r)
	return _world_to_locale(wpos)


func _world_to_locale(wpos: Vector2) -> Vector2i:
	var col  := int(floor((wpos.x - _origin_x) / (_map_w / _locales_cols)))
	var row  := int(floor((wpos.y - _origin_y) / (_map_h / _locales_rows)))
	return Vector2i(clampi(col, 0, _locales_cols - 1),
	                clampi(row, 0, _locales_rows - 1))


func _map_center_world() -> Vector2:
	return Vector2(_origin_x + _map_w * 0.5, _origin_y + _map_h * 0.5)


func _viewport_center_world() -> Vector2:
	var center_px := get_viewport_rect().size * 0.5
	return get_viewport().get_canvas_transform().affine_inverse() * center_px


func _locale_hex_bounds(col: int, row: int) -> Dictionary:
	var lw   := _map_w / _locales_cols
	var lh   := _map_h / _locales_rows
	var wx0  := _origin_x + col * lw
	var wy0  := _origin_y + row * lh
	var wx1  := wx0 + lw
	var wy1  := wy0 + lh
	# World-space padding avoids sheared clipping from fixed q/r range filtering.
	var pad_world := _hex_size * 2.0
	return {
		"wx_min":    wx0,
		"wy_min":    wy0,
		"wx_max":    wx1,
		"wy_max":    wy1,
		"world_w":   lw,
		"world_h":   lh,
		"pad_world": pad_world,
	}


# ── Fog ────────────────────────────────────────────────────────────────────────

func _reveal_fog(q0: int, r0: int, radius: int) -> void:
	if _fog_img == null or _fog_tex == null:
		return
	for dq in range(-radius, radius + 1):
		var r1 := maxi(-radius, -dq - radius)
		var r2 := mini( radius, -dq + radius)
		for dr in range(r1, r2 + 1):
			_set_fog_pixel(q0 + dq, r0 + dr)
	_fog_tex.update(_fog_img)


func _set_fog_pixel(q: int, r: int) -> void:
	var q_left := -_floor_div2(r) - 2
	var q_off  := q - q_left
	var r_off  := r - _r_min_val
	if q_off < 0 or q_off >= _fog_img.get_width() or r_off < 0 or r_off >= _fog_img.get_height():
		return
	_fog_img.set_pixel(q_off, r_off, Color(1.0, 0.0, 0.0))


# ── File loading ───────────────────────────────────────────────────────────────

func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var raw := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(raw) != OK:
		return {}
	return json.get_data()


func _read_hexbin_header(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("RegionMap: not found: " + path); return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("RegionMap: cannot open: " + path); return {}
	var buf := f.get_buffer(72)
	f.close()
	if buf.size() < 72:
		push_error("RegionMap: header too short"); return {}
	if buf.slice(0, 4).get_string_from_ascii() != "HXB1":
		push_error("RegionMap: bad magic"); return {}
	return {
		"tex_w":    buf.decode_u16(26),
		"tex_h":    buf.decode_u16(28),
		"r_min":    buf.decode_s16(22),
		"hex_size": buf.decode_double(32),
		"origin_x": buf.decode_double(40),
		"origin_y": buf.decode_double(48),
		"map_w":    buf.decode_double(56),
		"map_h":    buf.decode_double(64),
	}


func _load_hexbin(path: String,
				  wx_min: float, wx_max: float,
				  wy_min: float, wy_max: float,
				  pad_world: float) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("RegionMap: not found: " + path); return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("RegionMap: cannot open: " + path); return {}

	var hdr := f.get_buffer(72)
	if hdr.size() < 72:
		push_error("RegionMap: header too short"); f.close(); return {}
	if hdr.slice(0, 4).get_string_from_ascii() != "HXB1":
		push_error("RegionMap: bad magic"); f.close(); return {}

	var biome_cnt    := hdr.decode_u16(6)
	var hex_count    := hdr.decode_u32(8)
	var strtab_size  := hdr.decode_u32(12)
	var realm_cnt    := hdr.decode_u16(16)
	var province_cnt := hdr.decode_u16(18)
	var burg_cnt     := hdr.decode_u16(20)

	var strtab := f.get_buffer(strtab_size)
	f.get_buffer(biome_cnt * 4)

	var realm_buf := f.get_buffer(realm_cnt * 6)
	_realm_names.clear()
	for i in realm_cnt:
		var base := i * 6
		var rid  := realm_buf.decode_u16(base)
		var off  := realm_buf.decode_u32(base + 2)
		if rid > 0:
			_realm_names[rid] = _strtab_get(strtab, off)

	var prov_buf := f.get_buffer(province_cnt * 10)
	_province_names.clear()
	_province_capitals.clear()
	for i in province_cnt:
		var base     := i * 10
		var pid      := prov_buf.decode_u16(base)
		var name_off := prov_buf.decode_u32(base + 2)
		var cap_off  := prov_buf.decode_u32(base + 6)
		if pid > 0:
			_province_names[pid]    = _strtab_get(strtab, name_off)
			_province_capitals[pid] = _strtab_get(strtab, cap_off)

	f.get_buffer(burg_cnt * 4)
	var recs := f.get_buffer(hex_count * 10)
	f.close()

	# Use full-world texture dimensions so fog and shader indexing stay consistent.
	var tw := _tex_w_global
	var th := _tex_h_global
	var img_data  := PackedByteArray(); img_data.resize(tw * th * 4); img_data.fill(0)
	var burg_data := PackedByteArray(); burg_data.resize(tw * th * 2); burg_data.fill(0)

	var loaded := 0
	var sqrt3 := sqrt(3.0)
	var wx_lo := wx_min - pad_world
	var wx_hi := wx_max + pad_world
	var wy_lo := wy_min - pad_world
	var wy_hi := wy_max + pad_world
	for i in hex_count:
		var base     := i * 10
		var q        := recs.decode_s16(base)
		var r        := recs.decode_s16(base + 2)
		# Filter by locale world-space rect to avoid axial shear clipping.
		var wx := _hex_size * sqrt3 * (q + r * 0.5) + _origin_x
		var wy := _hex_size * 1.5   *  r             + _origin_y
		if wx < wx_lo or wx > wx_hi or wy < wy_lo or wy > wy_hi:
			continue
		var biome_id := recs.decode_u8(base + 4)
		var realm_id := recs.decode_u8(base + 5)
		var prov_id  := recs.decode_u16(base + 6)
		var q_left   := -_floor_div2(r) - 2
		var q_off    := q - q_left
		var r_off    := r - _r_min_val
		if q_off < 0 or q_off >= tw or r_off < 0 or r_off >= th:
			continue
		var pix      := r_off * tw + q_off
		img_data.encode_u8(pix * 4,     biome_id)
		img_data.encode_u8(pix * 4 + 1, realm_id)
		img_data.encode_u8(pix * 4 + 3, 255)
		burg_data.encode_u8(pix * 2,     prov_id >> 8)
		burg_data.encode_u8(pix * 2 + 1, prov_id & 0xFF)
		loaded += 1

	print("[RegionMap] locale (%d,%d): loaded %d / %d hexes" % [_locale_col, _locale_row, loaded, hex_count])
	_hex_img           = Image.create_from_data(tw, th, false, Image.FORMAT_RGBA8, img_data)
	_province_img_data = Image.create_from_data(tw, th, false, Image.FORMAT_RG8,   burg_data)
	return {"tex_w": tw, "tex_h": th}


static func _strtab_get(strtab: PackedByteArray, offset: int) -> String:
	if offset >= strtab.size():
		return ""
	var end := strtab.find(0, offset)
	if end < 0: end = strtab.size()
	return strtab.slice(offset, end).get_string_from_utf8()


static func _floor_div2(r: int) -> int:
	return r >> 1


# ── Input ──────────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_is_dragging  = true
				_drag_start   = mb.position
				_camera_start = _camera.position
				_drag_dist    = 0.0
			else:
				_is_dragging = false
				if _drag_dist < 4.0:
					var world_pos := get_viewport().get_canvas_transform().affine_inverse() * mb.position
					_select_by_zoom(world_pos)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var world_pos := get_viewport().get_canvas_transform().affine_inverse() * mb.position
			_move_party_to(world_pos)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_toward_marker(1.15)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_toward_marker(1.0 / 1.15)

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _is_dragging:
			_drag_dist += mm.relative.length()
			var delta := mm.position - _drag_start
			_camera.position = _camera_start - delta / _camera.zoom.x
			_clamp_camera_to_locale()
		_update_hover(mm.position)

	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			if k.keycode == KEY_X and _has_party_pos:
				_camera.position = _party_world_pos
				_camera_follow   = false


# ── Selection ──────────────────────────────────────────────────────────────────

func _select_by_zoom(world_pos: Vector2) -> void:
	var hex  := _world_to_hex(world_pos)
	var zoom := _camera.zoom.x
	if zoom < zoom_thresh_province:
		var rid := _sample_realm_id(hex)
		if rid > 0:
			_select_realm(rid)
	elif zoom < zoom_thresh_hex:
		var pid := _sample_province_id(hex)
		if pid > 0:
			_select_province(pid)
		else:
			var rid := _sample_realm_id(hex)
			if rid > 0:
				_select_realm(rid)
	else:
		_select_hex(hex)


func _select_hex(hex: Vector2i) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selection_mode", 0)
	_mat.set_shader_parameter("selected_q", hex.x)
	_mat.set_shader_parameter("selected_r", hex.y)
	_selected_hex = hex
	if _enter_btn:
		_enter_btn.visible = true
	_update_sel_panel("Hex", "q=%d  r=%d" % [hex.x, hex.y])


func _move_party_to(world_pos: Vector2) -> void:
	var hex := _world_to_hex(world_pos)
	if _mat:
		_mat.set_shader_parameter("selection_mode", 0)
		_mat.set_shader_parameter("selected_q", hex.x)
		_mat.set_shader_parameter("selected_r", hex.y)
	_selected_hex = hex
	if _enter_btn:
		_enter_btn.visible = true
	_update_sel_panel("→", "q=%d  r=%d" % [hex.x, hex.y])


func _select_province(province_id: int) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selection_mode",   1)
	_mat.set_shader_parameter("selected_burg_id", province_id)
	if _enter_btn:
		_enter_btn.visible = false
	var pname: String   = _province_names.get(province_id, "")
	var capital: String = _province_capitals.get(province_id, "")
	_update_sel_panel("Province", pname if capital.is_empty() else pname + "  ·  " + capital)


func _select_realm(realm_id: int) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selection_mode",    2)
	_mat.set_shader_parameter("selected_realm_id", realm_id)
	if _enter_btn:
		_enter_btn.visible = false
	_update_sel_panel("Realm", _realm_names.get(realm_id, ""))


func _enter_local() -> void:
	GameState.go_local(_selected_hex.x, _selected_hex.y, _get_biome_id(_selected_hex))


func _get_biome_id(hex: Vector2i) -> int:
	var c := _sample_hex_pixel(hex)
	return int(c.r * 255.0 + 0.5) if c.a >= 0.5 else 0


# ── HUD helpers ────────────────────────────────────────────────────────────────

func _update_sel_panel(type: String, label: String) -> void:
	_sel_label.text = type + "  —  " + label


func _update_mp_hud() -> void:
	if _mp_label:
		_mp_label.text = "MP: %d / %d" % [_mp_current, _mp_max]
	_sel_panel.visible = true
	_sel_panel.reset_size()


func _update_zoom_label(zoom: float) -> void:
	if _zoom_label:
		_zoom_label.text = "zoom: %.2f×" % zoom


func _update_hover(screen_pos: Vector2) -> void:
	if _mat == null:
		_hover_label.visible = false
		return
	var world_pos := get_viewport().get_canvas_transform().affine_inverse() * screen_pos
	var hex  := _world_to_hex(world_pos)
	var text := "px=(%.0f, %.0f)  hex=(%d, %d)" % [screen_pos.x, screen_pos.y, hex.x, hex.y]
	_hover_label.visible = not text.is_empty()
	if not text.is_empty():
		_hover_label.text = text
		_hover_label.position = screen_pos + Vector2(14, -22)


# ── Coordinate helpers ─────────────────────────────────────────────────────────

func _hex_to_world(q: int, r: int) -> Vector2:
	var sqrt3 := sqrt(3.0)
	return Vector2(
		_hex_size * sqrt3 * (q + r * 0.5) + _origin_x,
		_hex_size * 1.5   *  r             + _origin_y
	)


func _world_to_hex(world_pos: Vector2) -> Vector2i:
	var sqrt3 := sqrt(3.0)
	var r_f := (world_pos.y - _origin_y) / (1.5 * _hex_size)
	var q_f := ((world_pos.x - _origin_x) / (sqrt3 * _hex_size)) - r_f * 0.5
	return _hex_round(q_f, r_f)


func _zoom_toward_marker(factor: float) -> void:
	var old_zoom := _camera.zoom.x
	var new_zoom := clampf(old_zoom * factor, 0.1, 50.0)
	if _has_party_pos:
		_camera.position = _party_world_pos - (_party_world_pos - _camera.position) * (old_zoom / new_zoom)
	_camera.zoom = Vector2(new_zoom, new_zoom)
	if _mat: _mat.set_shader_parameter("camera_zoom", new_zoom)
	_update_zoom_label(new_zoom)
	_clamp_camera_to_locale()


func _clamp_camera_to_locale() -> void:
	if _locale_world_rect == Rect2():
		return
	var vp_half := get_viewport_rect().size * 0.5 / _camera.zoom.x
	var lo := _locale_world_rect.position + vp_half
	var hi := _locale_world_rect.end      - vp_half
	if lo.x <= hi.x:
		_camera.position.x = clamp(_camera.position.x, lo.x, hi.x)
	if lo.y <= hi.y:
		_camera.position.y = clamp(_camera.position.y, lo.y, hi.y)


# ── Texture sampling ───────────────────────────────────────────────────────────

func _sample_hex_pixel(hex: Vector2i) -> Color:
	if _hex_img == null:
		return Color(0, 0, 0, 0)
	var q_left := -_floor_div2(hex.y) - 2
	var q_off  := hex.x - q_left
	var r_off  := hex.y - _r_min_val
	if q_off < 0 or q_off >= _hex_img.get_width() or r_off < 0 or r_off >= _hex_img.get_height():
		return Color(0, 0, 0, 0)
	return _hex_img.get_pixel(q_off, r_off)


func _sample_realm_id(hex: Vector2i) -> int:
	var c := _sample_hex_pixel(hex)
	if c.a < 0.5:
		return -1
	return int(c.g * 255.0 + 0.5)


func _sample_province_id(hex: Vector2i) -> int:
	if _province_img_data == null:
		return 0
	var q_left := -_floor_div2(hex.y) - 2
	var q_off  := hex.x - q_left
	var r_off  := hex.y - _r_min_val
	if q_off < 0 or q_off >= _province_img_data.get_width() or r_off < 0 or r_off >= _province_img_data.get_height():
		return 0
	var c := _province_img_data.get_pixel(q_off, r_off)
	return int(c.r * 255.0 + 0.5) * 256 + int(c.g * 255.0 + 0.5)


static func _hex_round(q_f: float, r_f: float) -> Vector2i:
	var x_f := q_f
	var z_f := r_f
	var y_f := -x_f - z_f
	var rx  := roundi(x_f)
	var ry  := roundi(y_f)
	var rz  := roundi(z_f)
	var xd  := absf(float(rx) - x_f)
	var yd  := absf(float(ry) - y_f)
	var zd  := absf(float(rz) - z_f)
	if xd > yd and xd > zd:
		rx = -ry - rz
	elif yd > zd:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector2i(rx, rz)
