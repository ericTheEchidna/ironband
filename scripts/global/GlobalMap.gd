extends Node2D

## GlobalMap — full-world hex view. Left-click at low zoom enters a locale
## (GameState.go_regional). Party marker shows current position but world_move
## is issued from the Regional phase, not here.

# Switch the active world here. "cheia" is the shipped world; "ancient" is the
# Azgaar "Ancient" import (worlds/ancient/hex_grid.hexbin).
const WORLD_NAME            := "ancient"
const WORLD_DIR             := "res://worlds/" + WORLD_NAME
const HEX_GRID_PATH         := WORLD_DIR + "/hex_grid.hexbin"
const LOCALES_PATH          := WORLD_DIR + "/locales.json"
const SHADER_PATH           := "res://shaders/WorldMap.gdshader"
# Absolute path the C++ engine reads for party position / movement.
const WORLD_HEX_PATH        := "/home/eric/source/ironband/worlds/" + WORLD_NAME + "/hex_grid.hexbin"
const DEBUG_LOG             := "/tmp/ironband_debug.log"

signal hex_selected(q: int, r: int)
signal province_selected(province_id: int, province_name: String)
signal realm_selected(realm_id: int, realm_name: String)

@export var zoom_thresh_province: float = 3.0
@export var zoom_thresh_hex:      float = 25.0

var _camera: Camera2D
var _rect:   ColorRect
var _mat:    ShaderMaterial

var _hex_size:  float = 1.0
var _origin_x:  float = 0.0
var _origin_y:  float = 0.0
var _r_min_val: int   = 0
var _map_w:     float = 0.0
var _map_h:     float = 0.0
var _fit_zoom:  float = 1.0

var _locales_cols: int = 5
var _locales_rows: int = 2

var _hex_img:           Image = null
var _province_img_data: Image = null
var _realm_names:       Dictionary[int, String] = {}
var _province_names:    Dictionary[int, String] = {}
var _province_capitals: Dictionary[int, String] = {}

var _is_dragging    := false
var _is_dbl_click   := false
var _drag_start     := Vector2.ZERO
var _camera_start   := Vector2.ZERO
var _drag_dist      := 0.0

var _hover_label: Label
var _sel_panel:   PanelContainer
var _sel_label:   Label
var _mp_label:    Label
var _zoom_label:  Label
var _mode_label:  Label

var _fog_img: Image        = null
var _fog_tex: ImageTexture = null

var _marker: Node2D = null
var _mp_current: int      = 0
var _mp_max:     int      = 6
var _camera_follow: bool  = false
var _camera_target: Vector2 = Vector2.ZERO
var _party_world_pos: Vector2 = Vector2.ZERO
var _has_party_pos:   bool    = false

@onready var _engine := get_node("/root/IronbandEngine")


func _ready() -> void:
	_camera = $Camera2D
	_rect    = $WorldRect
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.visible = false
	_setup_hud()

	$LoadingLabel.visible = true
	call_deferred("_load_and_render")


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

	_mode_label = Label.new()
	_mode_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mode_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_mode_label.offset_left = 8
	_mode_label.offset_top  = 8
	_mode_label.add_theme_color_override("font_color", Color.WHITE)
	_mode_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	_mode_label.add_theme_constant_override("shadow_offset_x", 1)
	_mode_label.add_theme_constant_override("shadow_offset_y", 1)
	hud.add_child(_mode_label)

	RenderingServer.set_default_clear_color(Color(0.16, 0.28, 0.45))


func _load_and_render() -> void:
	$LoadingLabel.text = "Loading hex grid…"
	await get_tree().process_frame
	var hdr := _load_hexbin(HEX_GRID_PATH)
	if hdr.is_empty():
		$LoadingLabel.text = "Error: could not load " + HEX_GRID_PATH
		return

	var tex_w: int   = hdr["tex_w"]
	var tex_h: int   = hdr["tex_h"]
	var map_w: float = hdr["map_w"]
	var map_h: float = hdr["map_h"]
	_map_w = map_w
	_map_h = map_h

	_load_locales()

	var fog_img := Image.create(tex_w, tex_h, false, Image.FORMAT_RGBA8)
	fog_img.fill(Color(0, 0, 0, 0))
	_fog_img = fog_img
	_fog_tex = ImageTexture.create_from_image(fog_img)

	var tex      := ImageTexture.create_from_image(_hex_img)
	var burg_tex := ImageTexture.create_from_image(_province_img_data)

	var shader := load(SHADER_PATH) as Shader
	_mat        = ShaderMaterial.new()
	_mat.shader = shader
	_mat.set_shader_parameter("hex_size",          _hex_size)
	_mat.set_shader_parameter("origin_x",          _origin_x)
	_mat.set_shader_parameter("origin_y",          _origin_y)
	_mat.set_shader_parameter("map_w",             map_w)
	_mat.set_shader_parameter("map_h",             map_h)
	_mat.set_shader_parameter("hex_data",          tex)
	_mat.set_shader_parameter("burg_data",         burg_tex)
	_mat.set_shader_parameter("tex_width",         tex_w)
	_mat.set_shader_parameter("tex_height",        tex_h)
	_mat.set_shader_parameter("r_min",             _r_min_val)
	_mat.set_shader_parameter("selected_q",        -9999)
	_mat.set_shader_parameter("selected_r",        -9999)
	_mat.set_shader_parameter("selected_realm_id", -1)
	_mat.set_shader_parameter("selected_burg_id",  -1)
	_mat.set_shader_parameter("selection_mode",     0)
	_mat.set_shader_parameter("camera_zoom",        1.0)
	_mat.set_shader_parameter("color_mode",        1)
	_mat.set_shader_parameter("fog_data",           _fog_tex)

	_rect.position = Vector2(_origin_x, _origin_y)
	_rect.size     = Vector2(map_w, map_h)
	_rect.material = _mat
	_rect.visible  = true

	var vp_size    := get_viewport_rect().size
	var view_center := Vector2(_origin_x + map_w * 0.5, _origin_y + map_h * 0.5)
	var fit_zoom   := vp_size.x / map_w
	_fit_zoom = fit_zoom
	_camera.position = view_center
	_camera.zoom = Vector2(fit_zoom, fit_zoom)
	_update_zoom_label(fit_zoom)

	var MarkerScript := preload("res://scripts/shared/PartyMarker.gd")
	_marker = MarkerScript.new()
	_marker.z_index = 10
	_marker.visible = false
	add_child(_marker)
	_marker.setup(_hex_size)

	$LoadingLabel.visible = false
	_connect_engine()


func _load_locales() -> void:
	var data := _load_json(LOCALES_PATH)
	_locales_cols = int(data.get("cols",       5))
	_locales_rows = int(data.get("rows",       2))


# --- engine wiring (replaces ProtohackClient) ---
func _connect_engine() -> void:
	_engine.load_world(WORLD_HEX_PATH)
	_engine.hex_entered.connect(_on_hex_entered)
	_engine.time_scale_changed.connect(_on_time_scale_changed)
	_engine.encounter_triggered.connect(_on_encounter)
	var p: Vector2i = _engine.get_party_position()
	if _marker:
		_marker.place_at(_hex_to_world(p.x, p.y))

func _on_hex_entered(q: int, r: int, _terrain: int, _prov: int, _realm: int) -> void:
	if _marker:
		_marker.move_to(_hex_to_world(q, r), _camera.zoom.x)

func _on_time_scale_changed(time_scale: float) -> void:
	if _zoom_label:
		_zoom_label.text = "PAUSED" if time_scale == 0.0 else "x%.0f" % time_scale

func _on_encounter(type: String, payload: String) -> void:
	if _hover_label:
		_hover_label.text = "Event: %s (%s)" % [type, payload]
		_hover_label.visible = true


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


func _load_hexbin(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("GlobalMap: not found: " + path); return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("GlobalMap: cannot open: " + path); return {}

	var hdr_buf := f.get_buffer(72)
	if hdr_buf.size() < 72:
		push_error("GlobalMap: hexbin header too short"); f.close(); return {}
	if hdr_buf.slice(0, 4).get_string_from_ascii() != "HXB1":
		push_error("GlobalMap: hexbin bad magic"); f.close(); return {}

	var biome_cnt    := hdr_buf.decode_u16(6)
	var hex_count    := hdr_buf.decode_u32(8)
	var strtab_size  := hdr_buf.decode_u32(12)
	var realm_cnt    := hdr_buf.decode_u16(16)
	var province_cnt := hdr_buf.decode_u16(18)
	var burg_cnt     := hdr_buf.decode_u16(20)
	var r_min_val    := hdr_buf.decode_s16(22)
	var tex_w        := hdr_buf.decode_u16(26)
	var tex_h        := hdr_buf.decode_u16(28)
	_hex_size  = hdr_buf.decode_double(32)
	_origin_x  = hdr_buf.decode_double(40)
	_origin_y  = hdr_buf.decode_double(48)
	var map_w  := hdr_buf.decode_double(56)
	var map_h  := hdr_buf.decode_double(64)
	_r_min_val = r_min_val

	var strtab := f.get_buffer(strtab_size)
	f.get_buffer(biome_cnt * 4)

	var realm_buf := f.get_buffer(realm_cnt * 6)
	for i in realm_cnt:
		var base := i * 6
		var rid  := realm_buf.decode_u16(base)
		var off  := realm_buf.decode_u32(base + 2)
		if rid > 0:
			_realm_names[rid] = _strtab_get(strtab, off)

	var prov_buf := f.get_buffer(province_cnt * 10)
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

	var img_data  := PackedByteArray(); img_data.resize(tex_w * tex_h * 4); img_data.fill(0)
	var burg_data := PackedByteArray(); burg_data.resize(tex_w * tex_h * 2); burg_data.fill(0)

	for i in hex_count:
		var base     := i * 10
		var q        := recs.decode_s16(base)
		var r        := recs.decode_s16(base + 2)
		var biome_id := recs.decode_u8(base + 4)
		var realm_id := recs.decode_u8(base + 5)
		var prov_id  := recs.decode_u16(base + 6)
		var q_left   := -_floor_div2(r) - 2
		var q_off    := q - q_left
		var r_off    := r - r_min_val
		var pix      := r_off * tex_w + q_off
		img_data.encode_u8(pix * 4,     biome_id)
		img_data.encode_u8(pix * 4 + 1, realm_id)
		img_data.encode_u8(pix * 4 + 3, 255)
		burg_data.encode_u8(pix * 2,     prov_id >> 8)
		burg_data.encode_u8(pix * 2 + 1, prov_id & 0xFF)

	_hex_img           = Image.create_from_data(tex_w, tex_h, false, Image.FORMAT_RGBA8, img_data)
	_province_img_data = Image.create_from_data(tex_w, tex_h, false, Image.FORMAT_RG8,   burg_data)
	return {"tex_w": tex_w, "tex_h": tex_h, "map_w": map_w, "map_h": map_h}


static func _strtab_get(strtab: PackedByteArray, offset: int) -> String:
	if offset >= strtab.size():
		return ""
	var end := strtab.find(0, offset)
	if end < 0: end = strtab.size()
	return strtab.slice(offset, end).get_string_from_utf8()


static func _floor_div2(r: int) -> int:
	return r >> 1


# ── Camera ──────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_is_dragging  = true
				_is_dbl_click = mb.double_click
				_drag_start   = mb.position
				_camera_start = _camera.position
				_drag_dist    = 0.0
			else:
				_is_dragging = false
				if _drag_dist < 4.0:
					var world_pos := get_viewport().get_canvas_transform().affine_inverse() * mb.position
					if _is_dbl_click:
						var loc := _world_to_locale(world_pos)
						var lw := _map_w / _locales_cols
						var lh := _map_h / _locales_rows
						var wx0 := _origin_x + loc.x * lw
						var wy0 := _origin_y + loc.y * lh
						_dbg("=== DOUBLE-CLICK → go_regional ===")
						_dbg("  world_pos      : (%.2f, %.2f)" % [world_pos.x, world_pos.y])
						_dbg("  locale         : (%d, %d)" % [loc.x, loc.y])
						_dbg("  locale bounds  : wx=[%.2f, %.2f]  wy=[%.2f, %.2f]" % [wx0, wx0+lw, wy0, wy0+lh])
						_dbg("  locale size    : %.2f x %.2f" % [lw, lh])
						_dbg("  map origin     : (%.2f, %.2f)  size: %.2f x %.2f" % [_origin_x, _origin_y, _map_w, _map_h])
						_dbg("  grid           : %dx%d  hex_size=%.4f" % [_locales_cols, _locales_rows, _hex_size])
						Engine.set_meta("entry_world_x", world_pos.x)
						Engine.set_meta("entry_world_y", world_pos.y)
						GameState.go_regional(loc.x, loc.y)
					else:
						_select_by_zoom(world_pos)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_camera.zoom = (_camera.zoom * 1.15).clamp(Vector2(_fit_zoom, _fit_zoom), Vector2(50.0, 50.0))
			if _mat: _mat.set_shader_parameter("camera_zoom", _camera.zoom.x)
			_update_zoom_label(_camera.zoom.x)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_camera.zoom = (_camera.zoom / 1.15).clamp(Vector2(_fit_zoom, _fit_zoom), Vector2(50.0, 50.0))
			if _mat: _mat.set_shader_parameter("camera_zoom", _camera.zoom.x)
			_update_zoom_label(_camera.zoom.x)

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _is_dragging:
			_drag_dist += mm.relative.length()
			var delta := mm.position - _drag_start
			_camera.position = _camera_start - delta / _camera.zoom.x
		_update_hover(mm.position)

	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			if k.keycode == KEY_X and _has_party_pos:
				_camera.position = _party_world_pos
				_camera_follow   = false


func _select_by_zoom(world_pos: Vector2) -> void:
	var hex  := _world_to_hex(world_pos)
	var zoom := _camera.zoom.x
	if zoom < zoom_thresh_province:
		var loc := _world_to_locale(world_pos)
		_update_sel_panel("Locale", "(%d, %d)  —  double-click to enter" % [loc.x, loc.y])
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


func _world_to_locale(world_pos: Vector2) -> Vector2i:
	var col := int(floor((world_pos.x - _origin_x) / (_map_w / _locales_cols)))
	var row := int(floor((world_pos.y - _origin_y) / (_map_h / _locales_rows)))
	return Vector2i(clampi(col, 0, _locales_cols - 1),
	                clampi(row, 0, _locales_rows - 1))


func _select_hex(hex: Vector2i) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selection_mode", 0)
	_mat.set_shader_parameter("selected_q", hex.x)
	_mat.set_shader_parameter("selected_r", hex.y)
	hex_selected.emit(hex.x, hex.y)
	_update_sel_panel("Hex", "q=%d  r=%d" % [hex.x, hex.y])
	_engine.move_party(PackedVector2Array([Vector2(hex.x, hex.y)]))
	_engine.set_time_scale(1.0)


func _select_province(province_id: int) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selection_mode",   1)
	_mat.set_shader_parameter("selected_burg_id", province_id)
	var pname: String   = _province_names.get(province_id, "")
	var capital: String = _province_capitals.get(province_id, "")
	province_selected.emit(province_id, pname)
	_update_sel_panel("Province", pname if capital.is_empty() else pname + "  ·  " + capital)


func _select_realm(realm_id: int) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selection_mode",    2)
	_mat.set_shader_parameter("selected_realm_id", realm_id)
	realm_selected.emit(realm_id, _realm_names.get(realm_id, ""))
	_update_sel_panel("Realm", _realm_names.get(realm_id, ""))


func _update_sel_panel(type: String, label: String) -> void:
	_sel_label.text = type + "  —  " + label


func _hex_to_world(q: int, r: int) -> Vector2:
	var sqrt3 := sqrt(3.0)
	return Vector2(
		_hex_size * sqrt3 * (q + r * 0.5) + _origin_x,
		_hex_size * 1.5   *  r             + _origin_y
	)


func _update_mp_hud() -> void:
	if _mp_label:
		_mp_label.text = "MP: %d / %d" % [_mp_current, _mp_max]
	_sel_panel.visible = true
	_sel_panel.reset_size()


func _update_hover(screen_pos: Vector2) -> void:
	if _mat == null:
		_hover_label.visible = false
		return
	var world_pos := get_viewport().get_canvas_transform().affine_inverse() * screen_pos
	var hex  := _world_to_hex(world_pos)
	var zoom := _camera.zoom.x
	var text := ""
	if zoom < zoom_thresh_province:
		var loc := _world_to_locale(world_pos)
		text = "Locale (%d, %d)  —  double-click to enter" % [loc.x, loc.y]
	elif zoom < zoom_thresh_hex:
		var pid := _sample_province_id(hex)
		if pid > 0:
			text = "Province — " + _province_names.get(pid, "")
		else:
			var rid := _sample_realm_id(hex)
			if rid > 0:
				text = "Realm — " + _realm_names.get(rid, "")
	else:
		var c := _sample_hex_pixel(hex)
		if c.a >= 0.5:
			text = "Hex  q=%d  r=%d" % [hex.x, hex.y]

	text += "  [%.0f, %.0f]" % [world_pos.x, world_pos.y]
	_hover_label.visible = true
	if not text.is_empty():
		_hover_label.text = text
		_hover_label.position = screen_pos + Vector2(14, -22)


func _update_zoom_label(zoom: float) -> void:
	if _zoom_label:
		_zoom_label.text = "zoom: %.2f×" % zoom
	if _mode_label:
		if zoom < zoom_thresh_province:
			_mode_label.text = "[ ENTER REGION ]"
		elif zoom < zoom_thresh_hex:
			_mode_label.text = "[ SELECT AREA ]"
		else:
			_mode_label.text = "[ MOVE PARTY ]"
	if _mat:
		_mat.set_shader_parameter("color_mode", 2 if zoom >= zoom_thresh_province else 1)


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


func _world_to_hex(world_pos: Vector2) -> Vector2i:
	var sqrt3 := sqrt(3.0)
	var r_f := (world_pos.y - _origin_y) / (1.5 * _hex_size)
	var q_f := ((world_pos.x - _origin_x) / (sqrt3 * _hex_size)) - r_f * 0.5
	return _hex_round(q_f, r_f)


func _dbg(msg: String) -> void:
	var f := FileAccess.open(DEBUG_LOG, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(DEBUG_LOG, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(msg)
	f.close()


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
