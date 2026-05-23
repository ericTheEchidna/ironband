extends Node2D

## WorldMap — loads hex_grid.json, builds a compact data texture (biome_id,
## realm_id per hex), and displays the world via a fragment shader that does
## analytical hex inverse-mapping. Scales cleanly at any zoom level.

const HEX_GRID_PATH  := "res://worlds/cheia/hex_grid.json"
const SHADER_PATH    := "res://shaders/WorldMap.gdshader"
const RELAY_SCRIPT   := "res://scripts/engine_relay.py"
const ENGINE_PATH    := "/home/eric/source/Hack2/build/app"
const WORLD_HEX_PATH := "/home/eric/source/Hack2/worlds/cheia/hex_grid.json"
const ENGINE_PORT    := 7373

signal hex_selected(q: int, r: int)
signal province_selected(province_id: int, province_name: String)
signal realm_selected(realm_id: int, realm_name: String)

@export var zoom_thresh_province: float = 3.0   # province borders visible at > 2.5
@export var zoom_thresh_hex:      float = 25.0  # individual hex selection

var _camera: Camera2D
var _rect: ColorRect
var _mat: ShaderMaterial

var _hex_size:  float = 1.0
var _origin_x:  float = 0.0
var _origin_y:  float = 0.0
var _r_min_val: int   = 0

var _hex_img:       Image = null
var _province_img_data: Image = null
var _realm_names:    Dictionary[int, String] = {}
var _province_names: Dictionary[int, String] = {}
var _province_capitals: Dictionary[int, String] = {}

var _is_dragging  := false
var _drag_start   := Vector2.ZERO
var _camera_start := Vector2.ZERO
var _drag_dist    := 0.0

var _hover_label:  Label
var _sel_panel:    PanelContainer
var _sel_label:    Label

var _client: ProtohackClient = null


func _ready() -> void:
	_camera = $Camera2D
	_rect    = $WorldRect
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_setup_hud()

	$LoadingLabel.visible = true
	call_deferred("_load_and_render")


func _process(_delta: float) -> void:
	if _client:
		_client.poll()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if _client:
			_client.stop()


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


func _load_and_render() -> void:
	var data := _load_json(HEX_GRID_PATH)
	if data.is_empty():
		$LoadingLabel.text = "Error: could not load " + HEX_GRID_PATH
		return

	_hex_size             = data.get("hex_size", 1.0)
	var origin: Dictionary = data.get("map_origin", {})
	var extent: Dictionary = data.get("map_extent", {})
	_origin_x             = origin.get("x", 0.0)
	_origin_y             = origin.get("y", 0.0)
	var hex_size: float   = _hex_size
	var origin_x: float   = _origin_x
	var origin_y: float   = _origin_y
	var map_w: float      = extent.get("w", 1234.0)
	var map_h: float      = extent.get("h", 540.0)
	var hexes: Array      = data.get("hexes", [])

	# ── Build hex data texture ─────────────────────────────────────────────
	# q_offset = q - q_left(r),  q_left(r) = -(r >> 1) - 2
	# r_offset = r - r_min
	# Texture: R=biome_id/255, G=realm_id/255, A=1 (0=no data)

	var r_min := 0
	var r_max := 0
	var q_off_max := 0
	for hex in hexes:
		var r: int     = int(hex.r)
		var q_left: int = -_floor_div2(r) - 2
		var q_off: int  = int(hex.q) - q_left
		if r < r_min: r_min = r
		if r > r_max: r_max = r
		if q_off > q_off_max: q_off_max = q_off

	var tex_w := q_off_max + 1
	var tex_h := r_max - r_min + 1
	_r_min_val = r_min

	$LoadingLabel.text = "Building data texture (%d×%d)…" % [tex_w, tex_h]
	await get_tree().process_frame

	var img      := Image.create(tex_w, tex_h, false, Image.FORMAT_RGBA8)
	var burg_img := Image.create(tex_w, tex_h, false, Image.FORMAT_RG8)
	img.fill(Color(0, 0, 0, 0))
	burg_img.fill(Color(0, 0, 0, 0))

	for hex in hexes:
		var r: int      = int(hex.r)
		var q_left: int = -_floor_div2(r) - 2
		var q_off: int  = int(hex.q) - q_left
		var r_off: int  = r - r_min
		var biome_f: float  = clamp(float(int(hex.biome_id)) / 255.0, 0.0, 1.0)
		var realm_f: float  = clamp(float(int(hex.realm_id)) / 255.0, 0.0, 1.0)
		img.set_pixel(q_off, r_off, Color(biome_f, realm_f, 0.0, 1.0))
		var province_id: int = int(hex.get("province_id", 0))
		burg_img.set_pixel(q_off, r_off, Color(
			float(province_id >> 8) / 255.0,
			float(province_id & 0xFF) / 255.0,
			0.0, 0.0))
		# Build name lookup tables
		var rid: int = int(hex.realm_id)
		if rid > 0 and not _realm_names.has(rid):
			_realm_names[rid] = str(hex.get("realm_name", ""))
		if province_id > 0 and not _province_names.has(province_id):
			_province_names[province_id]   = str(hex.get("province_name", ""))
			_province_capitals[province_id] = str(hex.get("province_capital", ""))

	_hex_img           = img
	_province_img_data = burg_img
	var tex          := ImageTexture.create_from_image(img)
	var burg_tex     := ImageTexture.create_from_image(burg_img)

	# ── Wire up shader ─────────────────────────────────────────────────────
	var shader := load(SHADER_PATH) as Shader
	_mat        = ShaderMaterial.new()
	_mat.shader = shader
	_mat.set_shader_parameter("hex_size",   hex_size)
	_mat.set_shader_parameter("origin_x",   origin_x)
	_mat.set_shader_parameter("origin_y",   origin_y)
	_mat.set_shader_parameter("map_w",      map_w)
	_mat.set_shader_parameter("map_h",      map_h)
	_mat.set_shader_parameter("hex_data",   tex)
	_mat.set_shader_parameter("burg_data",  burg_tex)
	_mat.set_shader_parameter("tex_width",  tex_w)
	_mat.set_shader_parameter("tex_height", tex_h)
	_mat.set_shader_parameter("r_min",      r_min)
	_mat.set_shader_parameter("selected_q",       -9999)
	_mat.set_shader_parameter("selected_r",       -9999)
	_mat.set_shader_parameter("selected_realm_id", -1)
	_mat.set_shader_parameter("selected_burg_id",  -1)
	_mat.set_shader_parameter("selection_mode",     0)
	_mat.set_shader_parameter("camera_zoom",        1.0)

	_rect.position = Vector2(origin_x, origin_y)
	_rect.size     = Vector2(map_w, map_h)
	_rect.material = _mat

	# Start camera centred on the map, zoomed to fit viewport width.
	var vp_size := get_viewport_rect().size
	_camera.position = Vector2(origin_x + map_w * 0.5, origin_y + map_h * 0.5)
	var fit_zoom := vp_size.x / map_w
	_camera.zoom = Vector2(fit_zoom, fit_zoom)

	$LoadingLabel.visible = false
	call_deferred("_start_engine_client")


func _start_engine_client() -> void:
	_client = ProtohackClient.new()
	add_child(_client)
	_client.handshake_done.connect(func(): print("[WorldMap] Engine handshake complete"))
	_client.worldmap_end.connect(func(): print("[WorldMap] Engine worldmap stream complete"))
	_client.engine_error.connect(func(code, msg): push_error("[WorldMap] Engine error: %s — %s" % [code, msg]))

	var relay := ProjectSettings.globalize_path(RELAY_SCRIPT)
	if not _client.start(relay, ENGINE_PATH, WORLD_HEX_PATH, ENGINE_PORT):
		push_error("[WorldMap] Failed to start engine client")
		_client = null


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("WorldMap: not found: " + path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("WorldMap: cannot open: " + path)
		return {}
	var raw := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(raw) != OK:
		push_error("WorldMap: JSON error: " + json.get_error_message())
		return {}
	return json.get_data()


# GDScript floor division by 2, matching Python's // semantics for negative ints.
static func _floor_div2(r: int) -> int:
	# Arithmetic right shift gives floor(r/2) for all signed integers.
	return r >> 1


# ── Camera controls ────────────────────────────────────────────────────────

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
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_camera.zoom = (_camera.zoom * 1.15).clamp(Vector2(0.1, 0.1), Vector2(50.0, 50.0))
			if _mat: _mat.set_shader_parameter("camera_zoom", _camera.zoom.x)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_camera.zoom = (_camera.zoom / 1.15).clamp(Vector2(0.1, 0.1), Vector2(50.0, 50.0))
			if _mat: _mat.set_shader_parameter("camera_zoom", _camera.zoom.x)

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _is_dragging:
			_drag_dist += mm.relative.length()
			var delta := mm.position - _drag_start
			_camera.position = _camera_start - delta / _camera.zoom.x
		_update_hover(mm.position)


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
	hex_selected.emit(hex.x, hex.y)
	_update_sel_panel("Hex", "q=%d  r=%d" % [hex.x, hex.y])


func _select_province(province_id: int) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selection_mode",    1)
	_mat.set_shader_parameter("selected_burg_id",  province_id)
	var pname: String   = _province_names.get(province_id, "")
	var capital: String = _province_capitals.get(province_id, "")
	province_selected.emit(province_id, pname)
	var label := pname if capital.is_empty() else pname + "  ·  " + capital
	_update_sel_panel("Province", label)


func _select_realm(realm_id: int) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selection_mode",    2)
	_mat.set_shader_parameter("selected_realm_id", realm_id)
	var rname: String = _realm_names.get(realm_id, "")
	realm_selected.emit(realm_id, rname)
	_update_sel_panel("Realm", rname)


func _update_sel_panel(type: String, label: String) -> void:
	_sel_label.text = type + "  —  " + label
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
		var rid := _sample_realm_id(hex)
		if rid > 0:
			text = "Realm — " + _realm_names.get(rid, "")
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

	_hover_label.visible = not text.is_empty()
	if not text.is_empty():
		_hover_label.text = text
		_hover_label.position = screen_pos + Vector2(14, -22)


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
	var r_f := world_pos.y / (1.5 * _hex_size)
	var q_f := (world_pos.x / (sqrt3 * _hex_size)) - r_f * 0.5
	return _hex_round(q_f, r_f)


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
	return Vector2i(rx, rz)  # (q, r)
