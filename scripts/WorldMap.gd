extends Node2D

## WorldMap — loads hex_grid.json, builds a compact data texture (biome_id,
## realm_id per hex), and displays the world via a fragment shader that does
## analytical hex inverse-mapping. Scales cleanly at any zoom level.

const HEX_GRID_PATH := "res://worlds/cheia/hex_grid.json"
const SHADER_PATH    := "res://shaders/WorldMap.gdshader"

var _camera: Camera2D
var _rect: ColorRect

var _is_dragging := false
var _drag_start  := Vector2.ZERO
var _camera_start := Vector2.ZERO


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

	var hex_size: float = data.get("hex_size", 1.0)
	var origin: Dictionary = data.get("map_origin", {})
	var extent: Dictionary = data.get("map_extent", {})
	var origin_x: float   = origin.get("x", 0.0)
	var origin_y: float   = origin.get("y", 0.0)
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
	var mat    := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("hex_size",  hex_size)
	mat.set_shader_parameter("origin_x",  origin_x)
	mat.set_shader_parameter("origin_y",  origin_y)
	mat.set_shader_parameter("map_w",     map_w)
	mat.set_shader_parameter("map_h",     map_h)
	mat.set_shader_parameter("hex_data",  tex)
	mat.set_shader_parameter("tex_width",  tex_w)
	mat.set_shader_parameter("tex_height", tex_h)
	mat.set_shader_parameter("r_min",      r_min)

	# Size the ColorRect to the map in Azgaar coordinate units.
	# Camera2D zoom handles the screen scaling.
	_rect.position = Vector2(origin_x, origin_y)
	_rect.size     = Vector2(map_w, map_h)
	_rect.material = mat

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
			_is_dragging = mb.pressed
			if mb.pressed:
				_drag_start   = mb.position
				_camera_start = _camera.position
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_camera.zoom = (_camera.zoom * 1.15).clamp(Vector2(0.1, 0.1), Vector2(50.0, 50.0))
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_camera.zoom = (_camera.zoom / 1.15).clamp(Vector2(0.1, 0.1), Vector2(50.0, 50.0))

	elif event is InputEventMouseMotion and _is_dragging:
		var delta := (event as InputEventMouseMotion).position - _drag_start
		_camera.position = _camera_start - delta / _camera.zoom.x
