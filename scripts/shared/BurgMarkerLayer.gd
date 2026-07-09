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

# The source PNGs have non-symmetric padding baked in (transparent margin
# thicker on one side than the other), so Sprite2D's default canvas-center
# pivot doesn't land on the visible artwork's center. Offsets below (native
# pixel space, measured off each PNG's opaque bounding box vs. its canvas
# center) recenter the drawn content instead of the raw canvas.
const _CONTENT_OFFSET := {
	"village": Vector2(4.5, 14.0),
	"town":    Vector2(2.5, 9.5),
	"city":    Vector2(0.0, 0.0),
	"harbor":  Vector2(17.5, 25.5),
}

static var _village_tex: ImageTexture = null
static var _town_tex:    ImageTexture = null
static var _city_tex:    ImageTexture = null
static var _harbor_tex:  ImageTexture = null
static var _textures_loaded := false

var _camera:    Camera2D    = null
var _markers:   Array[Node2D] = []
var _base_zoom: float = 1.0
var _zoom_growth_exp: float = 0.0  ## 0 = constant on-screen size; 1 = fully world-scaled. Small value = grows/shrinks "a little" with zoom.


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


## Enables mild on-screen growth/shrink with zoom instead of a perfectly flat
## marker size. base_zoom should be the zoom level markers look "right" at
## (e.g. the locale's entry/fit zoom) — growth is measured relative to it.
func configure_zoom_scaling(growth_exponent: float, base_zoom: float) -> void:
	_zoom_growth_exp = growth_exponent
	_base_zoom = maxf(base_zoom, 0.0001)


const _MARKER_SCENE := preload("res://scenes/shared/BurgMarker.tscn")
const _LABEL_FONT_SIZE := 13
const _LABEL_MARGIN    := 4.0
const _LABEL_HEIGHT    := 20.0
# The marker's zoom-compensation scale (_process) can shrink a label to a
# tiny fraction of its footprint — chasing that with a matching font_size
# either rounds to an unrasterizable ~1px (invisible) or, floored to stay
# legible, blows the apparent size back up. Instead render the font once at
# a higher fixed resolution and shrink it back down with a constant local
# scale: net apparent size/position is identical to a plain 13px label, but
# downsampling from more source detail looks crisp instead of blurry.
const _LABEL_SUPERSAMPLE := 4

func build(burgs: Array[BurgLoader.Burg], hex_to_world: Callable, show_labels: bool = false) -> void:
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
		var half_height := 0.0 if base_tex == null else base_tex.get_height() * base_scale * 0.5

		var label_shown := show_labels and not burg.name.is_empty()
		var label_block_height := (_LABEL_MARGIN + _LABEL_HEIGHT) if label_shown else 0.0
		# Icon alone is centered on the hex, but with a label appended below it
		# the combined icon+label group would visually sit low in the hex —
		# shift the whole group up so its bounding box (icon ∪ label) is what's
		# centered on the hex, not the icon alone.
		var group_offset := Vector2(0, -label_block_height * 0.5)

		var base_sprite: Sprite2D = marker.get_node("Base")
		if base_tex != null:
			base_sprite.texture = base_tex
			base_sprite.scale = Vector2.ONE * base_scale
			base_sprite.offset = -_CONTENT_OFFSET.get(spec["base"], Vector2.ZERO)
			base_sprite.position = group_offset
		else:
			base_sprite.free()

		var badge_sprite: Sprite2D = marker.get_node("Badge")
		if spec["badge"] and _harbor_tex != null:
			badge_sprite.texture = _harbor_tex
			badge_sprite.scale = Vector2.ONE * BADGE_SCALE
			badge_sprite.position = _corner_offset(base_tex, base_scale, 1) + group_offset
		else:
			badge_sprite.free()

		var accent_poly: Polygon2D = marker.get_node("Accent")
		if spec["accent"]:
			accent_poly.polygon = _star_points()
			accent_poly.position = _corner_offset(base_tex, base_scale, -1) + group_offset
		else:
			accent_poly.free()

		var name_label: Label = marker.get_node("NameLabel")
		if label_shown:
			# footprint is the label's apparent size/position, exactly as before
			# supersampling — size/position math below must keep using this, not
			# the larger internal rect the oversampled font actually needs.
			var footprint := Vector2(200, _LABEL_HEIGHT)
			name_label.text = burg.name
			name_label.add_theme_font_size_override("font_size", _LABEL_FONT_SIZE * _LABEL_SUPERSAMPLE)
			name_label.add_theme_color_override("font_color", Color.WHITE)
			name_label.add_theme_color_override("font_outline_color", Color.BLACK)
			name_label.add_theme_constant_override("outline_size", 3 * _LABEL_SUPERSAMPLE)
			name_label.size  = footprint * _LABEL_SUPERSAMPLE
			name_label.scale = Vector2.ONE / _LABEL_SUPERSAMPLE
			name_label.position = Vector2(-footprint.x * 0.5, half_height + _LABEL_MARGIN) + group_offset
		else:
			name_label.free()

		add_child(marker)
		_markers.append(marker)


func _process(_delta: float) -> void:
	if _camera == null:
		return
	# Base compensation keeps markers a constant on-screen size; raising the
	# zoom-relative-to-base ratio to a small exponent layers in a slight
	# grow-when-zoomed-in / shrink-when-zoomed-out feel instead of a flat size.
	# NameLabel's own constant supersample-compensation scale (see build())
	# composes with this automatically — nothing label-specific needed here.
	var zoom_ratio := _camera.zoom.x / _base_zoom
	var s := (Vector2.ONE / _camera.zoom.x) * pow(zoom_ratio, _zoom_growth_exp)
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
