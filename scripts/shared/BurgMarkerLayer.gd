## BurgMarkerLayer — renders settlement icon markers for a caller-supplied
## list of burgs. Does no filtering or zoom-tier logic itself; callers
## (GlobalMap.gd, RegionMap.gd) decide which burgs to pass to build().
class_name BurgMarkerLayer
extends Node2D

const _VILLAGE_ICON_PATH := "res://assets/village.png"
const _TOWN_ICON_PATH    := "res://assets/town.png"
const _CITY_ICON_PATH    := "res://assets/city.png"
const _HARBOR_ICON_PATH  := "res://assets/harbor.png"

# Local sprite scale at camera zoom = 1.0 — tuned against the icons' native
# sizes (village.png ~515px, town.png ~578px, city.png ~583px, harbor.png
# ~659px wide) to produce a readable village < town < city/capital size
# hierarchy, with the harbor badge small enough not to obscure the base icon.
const VILLAGE_SCALE := 0.05
const TOWN_SCALE    := 0.07
const CITY_SCALE    := 0.09
const NAVAL_SCALE   := 0.07
const BADGE_SCALE   := 0.035
const ACCENT_RADIUS := 5.0

static var _village_tex: ImageTexture = null
static var _town_tex:    ImageTexture = null
static var _city_tex:    ImageTexture = null
static var _harbor_tex:  ImageTexture = null
static var _textures_loaded := false

var _camera:  Camera2D    = null
var _markers: Array[Node2D] = []


## Pure selection logic — no rendering, no I/O. Unit-tested directly by
## scenes/smoke/BurgMarkerSmoke.gd.
static func marker_spec_for(burg: BurgLoader.Burg) -> Dictionary:
	var base := "village"
	var base_scale := VILLAGE_SCALE
	match burg.type:
		0:
			base = "village"; base_scale = VILLAGE_SCALE
		1:
			base = "town";    base_scale = TOWN_SCALE
		2:
			base = "city";    base_scale = CITY_SCALE
		3:
			base = "harbor";  base_scale = NAVAL_SCALE
		4:
			base = "city";    base_scale = CITY_SCALE
	var badge  := burg.is_port() and burg.type != 3  # naval already shows harbor.png as its base — no double-badge
	var accent := burg.type == 4
	return {"base": base, "base_scale": base_scale, "badge": badge, "accent": accent}


func set_camera(cam: Camera2D) -> void:
	_camera = cam


const _MARKER_SCENE := preload("res://scenes/shared/BurgMarker.tscn")

func build(burgs: Array[BurgLoader.Burg], hex_to_world: Callable) -> void:
	_ensure_textures_loaded()
	for m in _markers:
		m.queue_free()
	_markers.clear()

	for burg in burgs:
		var spec: Dictionary = marker_spec_for(burg)
		var marker: Node2D = _MARKER_SCENE.instantiate()
		marker.position = hex_to_world.call(burg.hex_q, burg.hex_r)

		var base_tex: ImageTexture = _texture_for(spec["base"])
		var base_scale: float = spec["base_scale"]
		var base_sprite: Sprite2D = marker.get_node("Base")
		if base_tex != null:
			base_sprite.texture = base_tex
			base_sprite.scale = Vector2.ONE * base_scale
		else:
			base_sprite.free()

		var badge_sprite: Sprite2D = marker.get_node("Badge")
		if spec["badge"] and _harbor_tex != null:
			badge_sprite.texture = _harbor_tex
			badge_sprite.scale = Vector2.ONE * BADGE_SCALE
			badge_sprite.position = _corner_offset(base_tex, base_scale, 1)
		else:
			badge_sprite.free()

		var accent_poly: Polygon2D = marker.get_node("Accent")
		if spec["accent"]:
			accent_poly.polygon = _star_points()
			accent_poly.position = _corner_offset(base_tex, base_scale, -1)
		else:
			accent_poly.free()

		add_child(marker)
		_markers.append(marker)


func _process(_delta: float) -> void:
	if _camera == null:
		return
	var s := Vector2.ONE / _camera.zoom.x
	for m in _markers:
		m.scale = s


static func _ensure_textures_loaded() -> void:
	if _textures_loaded:
		return
	_village_tex = _load_tex(_VILLAGE_ICON_PATH)
	_town_tex    = _load_tex(_TOWN_ICON_PATH)
	_city_tex    = _load_tex(_CITY_ICON_PATH)
	_harbor_tex  = _load_tex(_HARBOR_ICON_PATH)
	_textures_loaded = true


static func _load_tex(path: String) -> ImageTexture:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null:
		push_error("BurgMarkerLayer: failed to load " + path)
		return null
	return ImageTexture.create_from_image(img)


static func _texture_for(icon_name: String) -> ImageTexture:
	match icon_name:
		"village": return _village_tex
		"town":    return _town_tex
		"city":    return _city_tex
		"harbor":  return _harbor_tex
	return null


## corner_sign = 1 -> bottom-right corner (badge), corner_sign = -1 -> top-left corner (accent).
static func _corner_offset(base_tex: ImageTexture, base_scale: float, corner_sign: int) -> Vector2:
	if base_tex == null:
		return Vector2.ZERO
	return Vector2(base_tex.get_width(), base_tex.get_height()) * base_scale * 0.35 * float(corner_sign)


static func _star_points() -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 10:
		var r := ACCENT_RADIUS if i % 2 == 0 else ACCENT_RADIUS * 0.45
		var ang := deg_to_rad(-90 + i * 36)
		pts.append(Vector2(cos(ang), sin(ang)) * r)
	return pts
