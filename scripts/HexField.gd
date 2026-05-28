extends Node2D

const REGION_SCENE := "res://scenes/RegionMap.tscn"
const HEX_RADIUS   := 200.0   # pixels, pointy-top vertex-to-center

var _hex_q:    int = 0
var _hex_r:    int = 0
var _biome_id: int = 0


func _ready() -> void:
	_hex_q    = Engine.get_meta("hex_q",       0)
	_hex_r    = Engine.get_meta("hex_r",       0)
	_biome_id = Engine.get_meta("hex_biome_id", 0)
	_build_scene()


func _build_scene() -> void:
	var vp_size := get_viewport_rect().size
	var center  := vp_size * 0.5
	var col     := _biome_color(_biome_id)

	var bg := ColorRect.new()
	bg.color    = col.darkened(0.35)
	bg.size     = vp_size
	add_child(bg)

	var border := Polygon2D.new()
	border.polygon  = _hex_points(HEX_RADIUS + 6.0)
	border.color    = Color(0.0, 0.0, 0.0, 0.7)
	border.position = center
	add_child(border)

	var fill := Polygon2D.new()
	fill.polygon  = _hex_points(HEX_RADIUS)
	fill.color    = col
	fill.position = center
	add_child(fill)

	var MarkerScript := preload("res://scripts/PartyMarker.gd")
	var marker: Node2D = MarkerScript.new()
	marker.z_index = 10
	add_child(marker)
	marker.setup(1.0)
	marker.place_at(center)

	var hud := CanvasLayer.new()
	add_child(hud)

	var info := Label.new()
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.text = "Hex  q=%d  r=%d" % [_hex_q, _hex_r]
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
	get_tree().change_scene_to_file(REGION_SCENE)


static func _hex_points(radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var angle := deg_to_rad(60.0 * i + 30.0)
		pts.append(Vector2(cos(angle), -sin(angle)) * radius)
	return pts


static func _biome_color(id: int) -> Color:
	match id:
		0:  return Color(0.10, 0.25, 0.55)
		1:  return Color(0.88, 0.79, 0.38)
		2:  return Color(0.76, 0.72, 0.60)
		3:  return Color(0.79, 0.78, 0.35)
		4:  return Color(0.38, 0.65, 0.25)
		5:  return Color(0.15, 0.52, 0.18)
		6:  return Color(0.22, 0.52, 0.20)
		7:  return Color(0.05, 0.40, 0.10)
		8:  return Color(0.10, 0.42, 0.32)
		9:  return Color(0.30, 0.50, 0.45)
		10: return Color(0.72, 0.78, 0.80)
		11: return Color(0.88, 0.94, 1.00)
		12: return Color(0.18, 0.40, 0.35)
	return Color(0.5, 0.5, 0.5)
