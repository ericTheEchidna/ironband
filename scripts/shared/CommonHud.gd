class_name CommonHud
extends RefCounted

## HUD elements shared byte-for-byte between GlobalMap and RegionMap: hover
## label, selection panel (with MP readout), zoom label, and the
## province/realm/settlement info panel. Callers add their own
## screen-specific elements (mode label, enter button, explore console, ...)
## to the same CanvasLayer afterward.

var hover_label:     Label
var sel_panel:       PanelContainer
var sel_label:       Label
var mp_label:        Label
var zoom_label:      Label
var info_panel:      PanelContainer
var info_type_lbl:   Label
var info_name_lbl:   Label
var info_detail_lbl: Label


static func build(hud: CanvasLayer) -> CommonHud:
	var result := CommonHud.new()

	result.hover_label = Label.new()
	result.hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result.hover_label.visible = false
	result.hover_label.add_theme_color_override("font_color", Color.WHITE)
	result.hover_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	result.hover_label.add_theme_constant_override("shadow_offset_x", 1)
	result.hover_label.add_theme_constant_override("shadow_offset_y", 1)
	hud.add_child(result.hover_label)

	result.sel_panel = PanelContainer.new()
	result.sel_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result.sel_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	result.sel_panel.visible = false
	hud.add_child(result.sel_panel)

	result.sel_label = Label.new()
	result.sel_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result.sel_panel.add_child(result.sel_label)

	result.mp_label = Label.new()
	result.mp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result.mp_label.text = "MP: – / –"
	result.sel_panel.add_child(result.mp_label)

	result.zoom_label = Label.new()
	result.zoom_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result.zoom_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	result.zoom_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	result.zoom_label.offset_right = -8
	result.zoom_label.offset_top   = 8
	result.zoom_label.add_theme_color_override("font_color", Color.WHITE)
	result.zoom_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	result.zoom_label.add_theme_constant_override("shadow_offset_x", 1)
	result.zoom_label.add_theme_constant_override("shadow_offset_y", 1)
	hud.add_child(result.zoom_label)

	var ip := PanelContainer.new()
	ip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ip.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	ip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ip.grow_vertical   = Control.GROW_DIRECTION_END
	ip.offset_right = -8
	ip.offset_top   = 48
	ip.offset_left  = -276
	ip.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.12, 0.88)
	sb.set_corner_radius_all(5)
	sb.set_content_margin_all(10.0)
	ip.add_theme_stylebox_override("panel", sb)
	hud.add_child(ip)
	result.info_panel = ip

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	ip.add_child(vb)

	result.info_type_lbl = Label.new()
	result.info_type_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result.info_type_lbl.add_theme_color_override("font_color", Color(0.60, 0.70, 0.85, 1.0))
	result.info_type_lbl.add_theme_font_size_override("font_size", 10)
	vb.add_child(result.info_type_lbl)

	result.info_name_lbl = Label.new()
	result.info_name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result.info_name_lbl.add_theme_color_override("font_color", Color.WHITE)
	result.info_name_lbl.add_theme_font_size_override("font_size", 15)
	result.info_name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(result.info_name_lbl)

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", Color(1, 1, 1, 0.15))
	vb.add_child(sep)

	result.info_detail_lbl = Label.new()
	result.info_detail_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result.info_detail_lbl.add_theme_color_override("font_color", Color(0.82, 0.85, 0.90, 1.0))
	result.info_detail_lbl.add_theme_font_size_override("font_size", 12)
	result.info_detail_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(result.info_detail_lbl)

	return result
