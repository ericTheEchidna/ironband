extends Node2D

## WorldMap — loads hex_grid.hexbin, builds a compact data texture (biome_id,
## realm_id per hex), and displays the world via a fragment shader that does
## analytical hex inverse-mapping. Scales cleanly at any zoom level.

const HEX_GRID_PATH       := "res://worlds/cheia/hex_grid.hexbin"
const REGIONS_PATH        := "res://worlds/cheia/regions.json"
const SHADER_PATH         := "res://shaders/WorldMap.gdshader"
const ProtohackClientScript := preload("res://scripts/ProtohackClient.gd")
const RELAY_SCRIPT   := "res://scripts/engine_relay.py"
const ENGINE_PATH    := "/home/eric/source/ibp-engine/build/app"
const WORLD_HEX_PATH := "/home/eric/source/ibp-engine/worlds/cheia/hex_grid.hexbin"
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
var _mp_label:     Label

var _region_q_min:      int   = -9999
var _region_q_max:      int   =  9999
var _region_r_min:      int   = -9999
var _region_r_max:      int   =  9999
var _region_fog_rad:    int   = 6
var _region_world_rect: Rect2 = Rect2()

var _fog_img: Image        = null
var _fog_tex: ImageTexture = null

var _client = null  # ProtohackClient, set in _start_engine_client
var _marker: Node2D = null
var _mp_current: int    = 0
var _mp_max: int        = 6
var _camera_follow: bool    = false
var _camera_target: Vector2 = Vector2.ZERO
var _party_world_pos: Vector2 = Vector2.ZERO
var _has_party_pos: bool      = false


func _ready() -> void:
	_camera = $Camera2D
	_rect    = $WorldRect
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.visible = false  # hidden until shader material is applied
	_setup_hud()

	$LoadingLabel.visible = true
	call_deferred("_load_and_render")


func _process(delta: float) -> void:
	if _client:
		_client.poll()
	if _camera_follow:
		_camera.position = _camera.position.lerp(_camera_target, 1.0 - pow(0.01, delta))
	# Clamp camera position to play region
	if _region_world_rect != Rect2():
		var vp_half := get_viewport_rect().size * 0.5 / _camera.zoom.x
		var lo := _region_world_rect.position + vp_half
		var hi := _region_world_rect.end      - vp_half
		if lo.x <= hi.x and lo.y <= hi.y:
			_camera.position = _camera.position.clamp(lo, hi)
		else:
			_camera.position = _region_world_rect.get_center()
	# Keep marker constant screen size regardless of zoom
	if _marker and _marker.visible:
		_marker.scale = Vector2.ONE / _camera.zoom.x


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

	_mp_label = Label.new()
	_mp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mp_label.text = "MP: – / –"
	_sel_panel.add_child(_mp_label)


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

	_load_region()

	# Fog image — same dimensions as the hex data texture, all-unrevealed at start.
	var fog_img := Image.create(tex_w, tex_h, false, Image.FORMAT_RGBA8)
	fog_img.fill(Color(0, 0, 0, 0))  # R=0 → unrevealed
	_fog_img = fog_img
	_fog_tex = ImageTexture.create_from_image(fog_img)

	var tex      := ImageTexture.create_from_image(_hex_img)
	var burg_tex := ImageTexture.create_from_image(_province_img_data)

	# ── Wire up shader ─────────────────────────────────────────────────────
	var shader := load(SHADER_PATH) as Shader
	_mat        = ShaderMaterial.new()
	_mat.shader = shader
	_mat.set_shader_parameter("hex_size",   _hex_size)
	_mat.set_shader_parameter("origin_x",   _origin_x)
	_mat.set_shader_parameter("origin_y",   _origin_y)
	_mat.set_shader_parameter("map_w",      map_w)
	_mat.set_shader_parameter("map_h",      map_h)
	_mat.set_shader_parameter("hex_data",   tex)
	_mat.set_shader_parameter("burg_data",  burg_tex)
	_mat.set_shader_parameter("tex_width",  tex_w)
	_mat.set_shader_parameter("tex_height", tex_h)
	_mat.set_shader_parameter("r_min",      _r_min_val)
	_mat.set_shader_parameter("selected_q",       -9999)
	_mat.set_shader_parameter("selected_r",       -9999)
	_mat.set_shader_parameter("selected_realm_id", -1)
	_mat.set_shader_parameter("selected_burg_id",  -1)
	_mat.set_shader_parameter("selection_mode",     0)
	_mat.set_shader_parameter("camera_zoom",        1.0)
	_mat.set_shader_parameter("fog_data",          _fog_tex)

	_rect.position = Vector2(_origin_x, _origin_y)
	_rect.size     = Vector2(map_w, map_h)
	_rect.material = _mat
	_rect.visible  = true

	# Start camera centred on the play region (or full map if no region loaded).
	var vp_size := get_viewport_rect().size
	var view_center: Vector2
	var view_width:  float
	if _region_world_rect != Rect2():
		view_center = _region_world_rect.get_center()
		view_width  = _region_world_rect.size.x
	else:
		view_center = Vector2(_origin_x + map_w * 0.5, _origin_y + map_h * 0.5)
		view_width  = map_w
	_camera.position = view_center
	var fit_zoom := vp_size.x / view_width
	_camera.zoom = Vector2(fit_zoom, fit_zoom)

	# Create party marker (hidden until engine sends party_position)
	var MarkerScript := preload("res://scripts/PartyMarker.gd")
	_marker = MarkerScript.new()
	_marker.z_index = 10
	_marker.visible = false
	add_child(_marker)
	_marker.setup(_hex_size)

	$LoadingLabel.visible = false
	call_deferred("_start_engine_client")


func _start_engine_client() -> void:
	_client = ProtohackClientScript.new()
	add_child(_client)

	_client.handshake_done.connect(func():
		print("[WorldMap] Engine handshake complete"))

	_client.worldmap_end.connect(func():
		print("[WorldMap] Engine worldmap ready — waiting for party_position"))

	_client.engine_error.connect(func(code, msg):
		push_error("[WorldMap] Engine error: %s — %s" % [code, msg]))

	_client.party_position_received.connect(_on_party_position)
	_client.party_moved.connect(_on_party_moved)
	_client.movement_stopped.connect(_on_movement_stopped)

	var relay := ProjectSettings.globalize_path(RELAY_SCRIPT)
	if not _client.start(relay, ENGINE_PATH, WORLD_HEX_PATH, ENGINE_PORT):
		push_error("[WorldMap] Failed to start engine client")
		_client = null


func _on_party_position(q: int, r: int, mp: int, mp_max: int) -> void:
	print("[WorldMap] party_position q=%d r=%d mp=%d/%d" % [q, r, mp, mp_max])
	_mp_current = mp
	_mp_max     = mp_max
	_update_mp_hud()
	_sel_panel.visible = true
	var wpos := _hex_to_world(q, r)
	_party_world_pos = wpos
	_has_party_pos   = true
	_reveal_fog(q, r, _region_fog_rad)
	if _marker:
		print("[WorldMap] placing marker at world pos ", wpos)
		_marker.place_at(wpos)
	_camera_follow = false


func _on_party_moved(q: int, r: int, mp: int) -> void:
	_mp_current = mp
	_update_mp_hud()
	var dest := _hex_to_world(q, r)
	_party_world_pos = dest
	_has_party_pos   = true
	_reveal_fog(q, r, _region_fog_rad)
	if _marker:
		_marker.move_to(dest, _camera.zoom.x)
		# Smooth camera follow — lerp toward marker over next frames
		_camera_follow = true
		_camera_target = dest


func _on_movement_stopped(_reason: String) -> void:
	_camera_follow = false
	if _marker:
		_marker.flash()


func _load_region() -> void:
	var data := _load_json(REGIONS_PATH)
	if data.is_empty():
		return
	var active: String    = data.get("active", "")
	var regions: Dictionary = data.get("regions", {})
	var reg: Dictionary   = regions.get(active, {})
	if reg.is_empty():
		return
	_region_q_min   = int(reg.get("q_min",    -9999))
	_region_q_max   = int(reg.get("q_max",     9999))
	_region_r_min   = int(reg.get("r_min",    -9999))
	_region_r_max   = int(reg.get("r_max",     9999))
	_region_fog_rad = int(reg.get("fog_radius",    6))
	var corners := [
		_hex_to_world(_region_q_min, _region_r_min),
		_hex_to_world(_region_q_max, _region_r_min),
		_hex_to_world(_region_q_min, _region_r_max),
		_hex_to_world(_region_q_max, _region_r_max),
	]
	# Note: := can't infer type from Array element — must declare explicitly.
	var mn: Vector2 = corners[0]
	var mx: Vector2 = corners[0]
	for c: Vector2 in corners:
		mn = mn.min(c); mx = mx.max(c)
	_region_world_rect = Rect2(mn, mx - mn)


func _reveal_fog(q0: int, r0: int, radius: int) -> void:
	if _fog_img == null or _fog_tex == null:
		print("[WorldMap] _reveal_fog: fog image/tex null — skipping")
		return
	print("[WorldMap] _reveal_fog q=%d r=%d radius=%d" % [q0, r0, radius])
	for dq in range(-radius, radius + 1):
		var r1 := maxi(-radius, -dq - radius)
		var r2 := mini( radius, -dq + radius)
		for dr in range(r1, r2 + 1):
			_set_fog_pixel(q0 + dq, r0 + dr)
	_fog_tex.update(_fog_img)
	print("[WorldMap] _reveal_fog done, texture updated")


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


## Load a .hexbin file, populate _hex_img / _province_img_data / name dicts,
## and return a summary dict {tex_w, tex_h, map_w, map_h} on success, {} on error.
func _load_hexbin(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("WorldMap: not found: " + path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("WorldMap: cannot open: " + path)
		return {}

	# ── Header (72 bytes) ───────────────────────────────────────────────────
	var hdr_buf := f.get_buffer(72)
	if hdr_buf.size() < 72:
		push_error("WorldMap: hexbin header too short"); f.close(); return {}
	if hdr_buf.slice(0, 4).get_string_from_ascii() != "HXB1":
		push_error("WorldMap: hexbin bad magic"); f.close(); return {}

	# version     @ 4  (u16) — unused
	var biome_cnt    := hdr_buf.decode_u16(6)
	var hex_count    := hdr_buf.decode_u32(8)
	var strtab_size  := hdr_buf.decode_u32(12)
	var realm_cnt    := hdr_buf.decode_u16(16)
	var province_cnt := hdr_buf.decode_u16(18)
	var burg_cnt     := hdr_buf.decode_u16(20)
	var r_min_val    := hdr_buf.decode_s16(22)
	# r_max         @ 24 — not needed in GDScript
	var tex_w        := hdr_buf.decode_u16(26)
	var tex_h        := hdr_buf.decode_u16(28)
	# reserved      @ 30
	_hex_size  = hdr_buf.decode_double(32)
	_origin_x  = hdr_buf.decode_double(40)
	_origin_y  = hdr_buf.decode_double(48)
	var map_w  := hdr_buf.decode_double(56)
	var map_h  := hdr_buf.decode_double(64)
	_r_min_val = r_min_val

	# ── String table ────────────────────────────────────────────────────────
	var strtab := f.get_buffer(strtab_size)

	# ── Biome table (biome_cnt × 4 bytes) — skip, not needed in GDScript ───
	f.get_buffer(biome_cnt * 4)

	# ── Realm table (realm_cnt × 6 bytes) ───────────────────────────────────
	var realm_buf := f.get_buffer(realm_cnt * 6)
	for i in realm_cnt:
		var base := i * 6
		var rid  := realm_buf.decode_u16(base)
		var off  := realm_buf.decode_u32(base + 2)
		if rid > 0:
			_realm_names[rid] = _strtab_get(strtab, off)

	# ── Province table (province_cnt × 10 bytes) ────────────────────────────
	var prov_buf := f.get_buffer(province_cnt * 10)
	for i in province_cnt:
		var base     := i * 10
		var pid      := prov_buf.decode_u16(base)
		var name_off := prov_buf.decode_u32(base + 2)
		var cap_off  := prov_buf.decode_u32(base + 6)
		if pid > 0:
			_province_names[pid]    = _strtab_get(strtab, name_off)
			_province_capitals[pid] = _strtab_get(strtab, cap_off)

	# ── Burg table (burg_cnt × 4 bytes) — skip ──────────────────────────────
	f.get_buffer(burg_cnt * 4)

	# ── Hex records (hex_count × 10 bytes) ──────────────────────────────────
	var recs := f.get_buffer(hex_count * 10)
	f.close()

	# Build raw byte arrays for both textures, then create images in one call.
	# RGBA8: R=biome_id, G=realm_id, B=0, A=255 (A=0 means no data)
	# RG8:   R=province_id>>8, G=province_id&0xFF
	var img_data  := PackedByteArray(); img_data.resize(tex_w * tex_h * 4); img_data.fill(0)
	var burg_data := PackedByteArray(); burg_data.resize(tex_w * tex_h * 2); burg_data.fill(0)

	for i in hex_count:
		var base     := i * 10
		var q        := recs.decode_s16(base)
		var r        := recs.decode_s16(base + 2)
		var biome_id := recs.decode_u8(base + 4)
		var realm_id := recs.decode_u8(base + 5)
		var prov_id  := recs.decode_u16(base + 6)

		var q_left := -_floor_div2(r) - 2
		var q_off  := q - q_left
		var r_off  := r - r_min_val
		var pix    := r_off * tex_w + q_off

		img_data.encode_u8(pix * 4,     biome_id)
		img_data.encode_u8(pix * 4 + 1, realm_id)
		img_data.encode_u8(pix * 4 + 3, 255)       # alpha = 1 (has data)
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
			var old_zoom := _camera.zoom.x
			_camera.zoom = (_camera.zoom * 1.15).clamp(Vector2(0.1, 0.1), Vector2(50.0, 50.0))
			if _mat: _mat.set_shader_parameter("camera_zoom", _camera.zoom.x)
			if _has_party_pos:
				_camera.position = _party_world_pos + (_camera.position - _party_world_pos) * (old_zoom / _camera.zoom.x)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			var old_zoom := _camera.zoom.x
			_camera.zoom = (_camera.zoom / 1.15).clamp(Vector2(0.1, 0.1), Vector2(50.0, 50.0))
			if _mat: _mat.set_shader_parameter("camera_zoom", _camera.zoom.x)
			if _has_party_pos:
				_camera.position = _party_world_pos + (_camera.position - _party_world_pos) * (old_zoom / _camera.zoom.x)

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
	if _client:
		_client.send_command("> player.command action=world_move q=%d r=%d" % [hex.x, hex.y])


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
	var r_f := (world_pos.y - _origin_y) / (1.5 * _hex_size)
	var q_f := ((world_pos.x - _origin_x) / (sqrt3 * _hex_size)) - r_f * 0.5
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
