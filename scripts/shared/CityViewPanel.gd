class_name CityViewPanel
extends CanvasLayer

## CityViewPanel — modal settlement detail view, shown on double-clicking a
## burg's hex/icon. Built dynamically (same convention as CommonHud) rather
## than as a .tscn, since the whole layout is simple boxes/labels.
##
## Features shown are inferred straight from Azgaar's per-burg flags
## (BurgLoader.Burg — capital/port/walls/citadel/plaza/temple/shanty), not
## invented: e.g. "Market Square" reflects Azgaar's "plaza" attribute, which
## is what Azgaar itself uses to mean a burg has a market square.

var _bg:          ColorRect
var _panel:       PanelContainer
var _title_lbl:   Label
var _subtitle_lbl: Label
var _stats_lbl:   Label
var _features_lbl: Label


func _ready() -> void:
	layer = 20
	visible = false

	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, 0.55)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_bg.gui_input.connect(_on_bg_input)
	add_child(_bg)

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(320, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.12, 0.95)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(14.0)
	_panel.add_theme_stylebox_override("panel", sb)
	_bg.add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	_panel.add_child(vb)

	_title_lbl = Label.new()
	_title_lbl.add_theme_color_override("font_color", Color.WHITE)
	_title_lbl.add_theme_font_size_override("font_size", 20)
	vb.add_child(_title_lbl)

	_subtitle_lbl = Label.new()
	_subtitle_lbl.add_theme_color_override("font_color", Color(0.60, 0.70, 0.85, 1.0))
	_subtitle_lbl.add_theme_font_size_override("font_size", 12)
	vb.add_child(_subtitle_lbl)

	var sep1 := HSeparator.new()
	sep1.add_theme_color_override("color", Color(1, 1, 1, 0.15))
	vb.add_child(sep1)

	_stats_lbl = Label.new()
	_stats_lbl.add_theme_color_override("font_color", Color(0.82, 0.85, 0.90, 1.0))
	_stats_lbl.add_theme_font_size_override("font_size", 13)
	vb.add_child(_stats_lbl)

	var sep2 := HSeparator.new()
	sep2.add_theme_color_override("color", Color(1, 1, 1, 0.15))
	vb.add_child(sep2)

	_features_lbl = Label.new()
	_features_lbl.add_theme_color_override("font_color", Color(0.82, 0.85, 0.90, 1.0))
	_features_lbl.add_theme_font_size_override("font_size", 13)
	_features_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_features_lbl)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(hide_panel)
	vb.add_child(close_btn)


func _on_bg_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		# Only the dimmed backdrop itself should close it — clicks on the
		# panel already stop here via MOUSE_FILTER_STOP before reaching _bg.
		hide_panel()


## realm_name/province_name/culture_name/religion_name may be "" if unknown
## (e.g. no matching entry, or the lookup tables aren't loaded).
func show_city(burg: BurgLoader.Burg, realm_name: String, province_name: String,
		culture_name: String, religion_name: String) -> void:
	_title_lbl.text = burg.name
	_subtitle_lbl.text = burg.type_name().to_upper()

	var stats: Array[String] = []
	stats.append("Population: %s" % _format_population(burg.population))
	if not realm_name.is_empty():    stats.append("Realm: "    + realm_name)
	if not province_name.is_empty(): stats.append("Province: " + province_name)
	if not culture_name.is_empty():  stats.append("Culture: "  + culture_name)
	if not religion_name.is_empty(): stats.append("Religion: " + religion_name)
	_stats_lbl.text = "\n".join(stats)

	var features: Array[String] = []
	if burg.is_capital():  features.append("Capital")
	if burg.is_port():     features.append("⚓ Port")
	if burg.has_walls():   features.append("City Walls")
	if burg.has_citadel(): features.append("Citadel")
	if burg.has_plaza():   features.append("Market Square")
	if burg.has_temple():  features.append("Temple")
	if burg.has_shanty():  features.append("Shanty Town")
	_features_lbl.text = "Features: " + (", ".join(features) if not features.is_empty() else "none notable")

	visible = true


func hide_panel() -> void:
	visible = false


static func _format_population(pop: float) -> String:
	var digits := str(int(pop))
	var grouped := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			grouped += ","
		grouped += digits[i]
	return grouped
