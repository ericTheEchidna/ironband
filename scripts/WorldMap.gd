extends Node2D

## WorldMap — loads hex_grid.json and renders the Cheia world map as a rasterized
## Image texture. Each hex is drawn as a colored pixel cluster by biome and realm.
## Camera2D handles pan and zoom.

const HEX_GRID_PATH := "res://worlds/cheia/hex_grid.json"

# Display scale: Azgaar map units → screen pixels.
# Map is ~1234x540 Azgaar units; at scale 2.0 the image is ~2468x1080.
const DISPLAY_SCALE := 2.0

# Pixel radius around each hex centroid to fill (in display pixels).
const HEX_PIXEL_RADIUS := 1

# Biome index → base color (Marine=0 … Wetland=12)
const BIOME_COLORS: Array[Color] = [
	Color(0.10, 0.25, 0.55),   #  0 Marine          deep blue
	Color(0.88, 0.79, 0.38),   #  1 Hot desert       sandy yellow
	Color(0.76, 0.72, 0.60),   #  2 Cold desert      pale tan
	Color(0.79, 0.78, 0.35),   #  3 Savanna          yellow-green
	Color(0.38, 0.65, 0.25),   #  4 Grassland        green
	Color(0.15, 0.52, 0.18),   #  5 Tropical seasonal forest  dark green
	Color(0.22, 0.52, 0.20),   #  6 Temperate deciduous forest medium green
	Color(0.05, 0.40, 0.10),   #  7 Tropical rainforest       very dark green
	Color(0.10, 0.42, 0.32),   #  8 Temperate rainforest      blue-green
	Color(0.30, 0.50, 0.45),   #  9 Taiga             cool blue-green
	Color(0.72, 0.78, 0.80),   # 10 Tundra            pale grey-blue
	Color(0.88, 0.94, 1.00),   # 11 Glacier           white-blue
	Color(0.18, 0.40, 0.35),   # 12 Wetland           dark teal
]

# Realm palette: hashed colors for up to 32 realms (0 = neutral/no tint)
const REALM_PALETTE: Array[Color] = [
	Color.TRANSPARENT,           # 0 neutral
	Color(0.80, 0.20, 0.20, 0.35),
	Color(0.20, 0.60, 0.80, 0.35),
	Color(0.80, 0.70, 0.10, 0.35),
	Color(0.60, 0.20, 0.80, 0.35),
	Color(0.20, 0.80, 0.40, 0.35),
	Color(0.90, 0.45, 0.10, 0.35),
	Color(0.10, 0.60, 0.60, 0.35),
	Color(0.80, 0.30, 0.60, 0.35),
	Color(0.50, 0.75, 0.20, 0.35),
	Color(0.20, 0.30, 0.80, 0.35),
	Color(0.75, 0.55, 0.20, 0.35),
	Color(0.40, 0.80, 0.70, 0.35),
	Color(0.80, 0.10, 0.40, 0.35),
	Color(0.30, 0.70, 0.30, 0.35),
	Color(0.70, 0.70, 0.30, 0.35),
	Color(0.50, 0.20, 0.70, 0.35),
	Color(0.80, 0.50, 0.50, 0.35),
	Color(0.30, 0.50, 0.70, 0.35),
	Color(0.70, 0.30, 0.20, 0.35),
	Color(0.20, 0.70, 0.60, 0.35),
	Color(0.60, 0.60, 0.10, 0.35),
	Color(0.30, 0.20, 0.70, 0.35),
]

var _camera: Camera2D
var _texture_rect: TextureRect
var _is_dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _camera_start: Vector2 = Vector2.ZERO


func _ready() -> void:
	_camera = $Camera2D
	_texture_rect = $TextureRect

	# Show loading label
	$LoadingLabel.visible = true
	$LoadingLabel.text = "Loading Cheia world map…"

	# Defer heavy work so the label renders first
	call_deferred("_load_and_render")


func _load_and_render() -> void:
	var hex_data := _load_hex_grid(HEX_GRID_PATH)
	if hex_data.is_empty():
		$LoadingLabel.text = "Error: could not load " + HEX_GRID_PATH
		return

	var img := _rasterize(hex_data)
	var tex := ImageTexture.create_from_image(img)
	_texture_rect.texture = tex
	_texture_rect.position = Vector2.ZERO
	_texture_rect.size = Vector2(img.get_width(), img.get_height())

	# Center camera on map
	_camera.position = _texture_rect.size / 2.0
	_camera.zoom = Vector2(
		get_viewport_rect().size.x / _texture_rect.size.x,
		get_viewport_rect().size.x / _texture_rect.size.x
	)

	$LoadingLabel.visible = false


func _load_hex_grid(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("WorldMap: hex grid not found: " + path)
		return {}

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("WorldMap: cannot open " + path)
		return {}

	var raw := f.get_as_text()
	f.close()

	var json := JSON.new()
	var err := json.parse(raw)
	if err != OK:
		push_error("WorldMap: JSON parse error: " + json.get_error_message())
		return {}

	return json.get_data()


func _rasterize(data: Dictionary) -> Image:
	var hex_size: float = data.get("hex_size", 1.0)
	var origin: Dictionary = data.get("map_origin", {"x": 0.0, "y": 0.0})
	var extent: Dictionary = data.get("map_extent", {"w": 1234.0, "h": 540.0})
	var origin_x: float = origin.get("x", 0.0)
	var origin_y: float = origin.get("y", 0.0)

	var img_w := int(ceil(extent.get("w", 1234.0) * DISPLAY_SCALE)) + 4
	var img_h := int(ceil(extent.get("h", 540.0) * DISPLAY_SCALE)) + 4

	var img := Image.create(img_w, img_h, false, Image.FORMAT_RGB8)
	img.fill(Color(0.05, 0.05, 0.10))  # void/background

	var sqrt3: float = sqrt(3.0)
	var hexes: Array = data.get("hexes", [])

	for hex in hexes:
		var q: int = int(hex.get("q", 0))
		var r: int = int(hex.get("r", 0))
		var biome_id: int = int(hex.get("biome_id", 0))
		var realm_id: int = int(hex.get("realm_id", 0))

		# Pointy-top hex centroid in Azgaar coords
		var ax: float = hex_size * sqrt3 * (q + r * 0.5) + origin_x
		var ay: float = hex_size * 1.5 * r + origin_y

		# Scale to display
		var px: int = int(ax * DISPLAY_SCALE)
		var py: int = int(ay * DISPLAY_SCALE)

		# Base color from biome
		var base: Color = BIOME_COLORS[biome_id] if biome_id < BIOME_COLORS.size() else Color.MAGENTA

		# Blend realm tint
		var final_color: Color = base
		if realm_id > 0:
			var tint: Color = REALM_PALETTE[realm_id % REALM_PALETTE.size()]
			if tint.a > 0.0:
				final_color = base.lerp(Color(tint.r, tint.g, tint.b), tint.a)

		# Fill pixel cluster
		for dy in range(-HEX_PIXEL_RADIUS, HEX_PIXEL_RADIUS + 1):
			for dx in range(-HEX_PIXEL_RADIUS, HEX_PIXEL_RADIUS + 1):
				var ix := px + dx
				var iy := py + dy
				if ix >= 0 and ix < img_w and iy >= 0 and iy < img_h:
					img.set_pixel(ix, iy, final_color)

	return img


# ── Camera controls ────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_is_dragging = mb.pressed
			if mb.pressed:
				_drag_start = mb.position
				_camera_start = _camera.position
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_camera.zoom *= 1.15
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_camera.zoom /= 1.15
			_camera.zoom = _camera.zoom.clamp(Vector2(0.05, 0.05), Vector2(20.0, 20.0))

	elif event is InputEventMouseMotion and _is_dragging:
		var delta := (event as InputEventMouseMotion).position - _drag_start
		_camera.position = _camera_start - delta / _camera.zoom.x
