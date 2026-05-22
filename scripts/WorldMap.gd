extends Node2D

## WorldMap — loads hex_grid.json, builds a compact data texture (biome_id,
## realm_id per hex), and displays the world via a fragment shader that does
## analytical hex inverse-mapping. Scales cleanly at any zoom level.

const HEX_GRID_PATH := "res://worlds/cheia/hex_grid.json"
const SHADER_PATH    := "res://shaders/WorldMap.gdshader"

signal hex_selected(q: int, r: int)

var _camera: Camera2D
var _rect: ColorRect
var _mat: ShaderMaterial

var _hex_size: float = 1.0
var _origin_x: float = 0.0
var _origin_y: float = 0.0

var _is_dragging  := false
var _drag_start   := Vector2.ZERO
var _camera_start := Vector2.ZERO
var _drag_dist    := 0.0


func _ready() -> void:
	_camera = $Camera2D
	_rect    = $WorldRect

	$LoadingLabel.visible = true
	call_deferred("_load_and_render")


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

	$LoadingLabel.text = "Building data texture (%d×%d)…" % [tex_w, tex_h]
	await get_tree().process_frame

	var img := Image.create(tex_w, tex_h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))  # alpha=0 sentinel for empty cells

	for hex in hexes:
		var r: int      = int(hex.r)
		var q_left: int = -_floor_div2(r) - 2
		var q_off: int  = int(hex.q) - q_left
		var r_off: int  = r - r_min
		var biome_f: float = clamp(float(int(hex.biome_id)) / 255.0, 0.0, 1.0)
		var realm_f: float = clamp(float(int(hex.realm_id)) / 255.0, 0.0, 1.0)
		img.set_pixel(q_off, r_off, Color(biome_f, realm_f, 0.0, 1.0))

	var tex := ImageTexture.create_from_image(img)

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
	_mat.set_shader_parameter("tex_width",  tex_w)
	_mat.set_shader_parameter("tex_height", tex_h)
	_mat.set_shader_parameter("r_min",      r_min)
	_mat.set_shader_parameter("selected_q", -9999)
	_mat.set_shader_parameter("selected_r", -9999)

	_rect.position = Vector2(origin_x, origin_y)
	_rect.size     = Vector2(map_w, map_h)
	_rect.material = _mat

	# Start camera centred on the map, zoomed to fit viewport width.
	var vp_size := get_viewport_rect().size
	_camera.position = Vector2(origin_x + map_w * 0.5, origin_y + map_h * 0.5)
	var fit_zoom := vp_size.x / map_w
	_camera.zoom = Vector2(fit_zoom, fit_zoom)

	$LoadingLabel.visible = false


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
					_select_hex(_world_to_hex(world_pos))
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_camera.zoom = (_camera.zoom * 1.15).clamp(Vector2(0.1, 0.1), Vector2(50.0, 50.0))
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_camera.zoom = (_camera.zoom / 1.15).clamp(Vector2(0.1, 0.1), Vector2(50.0, 50.0))

	elif event is InputEventMouseMotion and _is_dragging:
		var mm := event as InputEventMouseMotion
		_drag_dist += mm.relative.length()
		var delta := mm.position - _drag_start
		_camera.position = _camera_start - delta / _camera.zoom.x


func _select_hex(hex: Vector2i) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selected_q", hex.x)
	_mat.set_shader_parameter("selected_r", hex.y)
	hex_selected.emit(hex.x, hex.y)
	print("Hex selected: q=%d r=%d" % [hex.x, hex.y])


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
