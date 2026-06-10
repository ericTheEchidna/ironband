extends Node2D

const HEX_GRID_PATH         := "res://worlds/cheia/hex_grid.hexbin"
const LOCALES_PATH          := "res://worlds/cheia/locales.json"
const TERRAIN_PATH          := "res://worlds/cheia/hex_terrain.bin"
const BURGS_PATH            := "res://worlds/cheia/burgs.bin"
const CULTURES_PATH         := "res://worlds/cheia/cultures.bin"
const RELIGIONS_PATH        := "res://worlds/cheia/religions.bin"
const SHADER_PATH           := "res://shaders/WorldMap.gdshader"
const ProtohackClientScript := preload("res://scripts/shared/ProtohackClient.gd")
const RELAY_SCRIPT          := "res://scripts/engine_relay.py"
const ENGINE_PATH           := "/home/eric/source/ibp-engine/build/app"
const WORLD_HEX_PATH        := "/home/eric/source/ibp-engine/worlds/cheia/hex_grid.hexbin"
const ENGINE_PORT           := 7373
const DEBUG_FOCUS_HEX       := Vector2i(373, 252)

@export var zoom_thresh_province: float = 3.0
@export var zoom_thresh_hex:      float = 25.0

var _camera: Camera2D
var _rect:   ColorRect
var _mat:    ShaderMaterial

# Set from hexbin header at startup (fast 72-byte read).
var _hex_size:      float = 1.0
var _origin_x:      float = 0.0
var _origin_y:      float = 0.0
var _r_min_val:     int   = 0
var _map_w:         float = 0.0
var _map_h:         float = 0.0
var _tex_w_global:  int   = 0
var _tex_h_global:  int   = 0

# Locale grid — from locales.json.
var _locales_cols:     int   = 5
var _locales_rows:     int   = 2
var _locale_col:       int   = -1
var _locale_row:       int   = -1
var _locale_world_rect: Rect2 = Rect2()
var _region_fog_rad:   int   = 6

var _hex_img:           Image = null
var _province_img_data: Image = null
var _realm_names:       Dictionary[int, String] = {}
var _province_names:    Dictionary[int, String] = {}
var _province_capitals: Dictionary[int, String] = {}

var _is_dragging  := false
var _drag_start   := Vector2.ZERO
var _camera_start := Vector2.ZERO
var _drag_dist    := 0.0

var _hover_label: Label
var _sel_panel:   PanelContainer
var _sel_label:   Label
var _mp_label:    Label
var _zoom_label:  Label
var _enter_btn:   Button

var _fog_img: Image        = null
var _fog_tex: ImageTexture = null

var _client = null
var _marker: Node2D = null
var _mp_current: int      = 0
var _mp_max:     int      = 6
var _camera_follow: bool  = false
var _camera_target: Vector2 = Vector2.ZERO
var _party_world_pos: Vector2 = Vector2.ZERO
var _has_party_pos:   bool    = false
var _selected_hex:       Vector2i = Vector2i(-9999, -9999)
var _pending_move_dest:  Vector2i = Vector2i(-9999, -9999)
var _startup_center_pending: bool = true

# Explore console
var _console_panel:   PanelContainer = null
var _console_history: RichTextLabel  = null
var _console_input:   LineEdit       = null
var _console_open:    bool           = false
var _explore_first:      bool           = true
var _explore_origin_hex: Vector2i      = Vector2i(-9999, -9999)
var _explore_prev_hex:   Vector2i      = Vector2i(-9999, -9999)
var _input_hist:         Array[String] = []
var _input_hist_pos:     int           = -1
var _chat_history:       Array         = []
const CHAT_HISTORY_MAX := 10

# Companion data (loaded at startup for explore prose context)
var _terrain_data:   HexTerrainLoader.TerrainData = null
var _burg_data:      BurgLoader.BurgData           = null
var _culture_data:   CultureLoader.CultureData     = null
var _religion_data:  ReligionLoader.ReligionData   = null

# Prose cache: Vector2i → String, capped at PROSE_CACHE_MAX entries
const PROSE_CACHE_MAX := 50
var _prose_cache:      Dictionary        = {}
var _prose_cache_keys: Array[Vector2i]   = []


func _ready() -> void:
	_camera = $Camera2D
	_camera.anchor_mode = Camera2D.ANCHOR_MODE_DRAG_CENTER
	_rect    = $WorldRect
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.visible = false
	_setup_hud()

	# Read world dimensions from hexbin header (72 bytes — instant).
	var hdr := _read_hexbin_header(HEX_GRID_PATH)
	if hdr.is_empty():
		$LoadingLabel.text = "Error: cannot read " + HEX_GRID_PATH
		return
	_hex_size     = hdr["hex_size"]
	_origin_x     = hdr["origin_x"]
	_origin_y     = hdr["origin_y"]
	_map_w        = hdr["map_w"]
	_map_h        = hdr["map_h"]
	_r_min_val    = hdr["r_min"]
	_tex_w_global = hdr["tex_w"]
	_tex_h_global = hdr["tex_h"]

	var lcfg := _load_json(LOCALES_PATH)
	_locales_cols   = int(lcfg.get("cols",       5))
	_locales_rows   = int(lcfg.get("rows",       2))
	_region_fog_rad = int(lcfg.get("fog_radius", 6))

	_terrain_data  = HexTerrainLoader.load_file(TERRAIN_PATH, _r_min_val, _tex_w_global)
	_burg_data     = BurgLoader.load_file(BURGS_PATH)
	_culture_data  = CultureLoader.load_file(CULTURES_PATH)
	_religion_data = ReligionLoader.load_file(RELIGIONS_PATH)

	$LoadingLabel.text = "Loading map…"
	$LoadingLabel.visible = true
	call_deferred("_load_static_map_preview")


func _load_static_map_preview() -> void:
	var result := _load_hexbin(HEX_GRID_PATH,
		_origin_x, _origin_x + _map_w,
		_origin_y, _origin_y + _map_h,
		0.0)
	if result.is_empty():
		$LoadingLabel.text = "Error loading map"
		return

	_locale_world_rect = Rect2(Vector2(_origin_x, _origin_y), Vector2(_map_w, _map_h))

	if _fog_img == null:
		_fog_img = Image.create(_tex_w_global, _tex_h_global, false, Image.FORMAT_RGBA8)
		_fog_img.fill(Color(1, 0, 0, 1))
		_fog_tex = ImageTexture.create_from_image(_fog_img)

	var tex      := ImageTexture.create_from_image(_hex_img)
	var burg_tex := ImageTexture.create_from_image(_province_img_data)

	var shader := load(SHADER_PATH) as Shader
	_mat        = ShaderMaterial.new()
	_mat.shader = shader
	_mat.set_shader_parameter("hex_size",          _hex_size)
	_mat.set_shader_parameter("origin_x",          _origin_x)
	_mat.set_shader_parameter("origin_y",          _origin_y)
	_mat.set_shader_parameter("map_w",             _map_w)
	_mat.set_shader_parameter("map_h",             _map_h)
	_mat.set_shader_parameter("hex_data",          tex)
	_mat.set_shader_parameter("burg_data",         burg_tex)
	_mat.set_shader_parameter("tex_width",         _tex_w_global)
	_mat.set_shader_parameter("tex_height",        _tex_h_global)
	_mat.set_shader_parameter("r_min",             _r_min_val)
	_mat.set_shader_parameter("selected_q",        -9999)
	_mat.set_shader_parameter("selected_r",        -9999)
	_mat.set_shader_parameter("selected_realm_id", -1)
	_mat.set_shader_parameter("selected_burg_id",  -1)
	_mat.set_shader_parameter("selection_mode",     0)
	_mat.set_shader_parameter("fog_data",           _fog_tex)

	_rect.position = Vector2(_origin_x, _origin_y)
	_rect.size     = Vector2(_map_w, _map_h)
	_rect.material = _mat
	_rect.visible  = true

	var vp_size  := get_viewport_rect().size
	var fit_zoom := vp_size.x / maxf(_map_w, 1.0)
	var focus_world := _hex_to_world(DEBUG_FOCUS_HEX.x, DEBUG_FOCUS_HEX.y)
	_camera.position = focus_world
	_camera_target = focus_world
	_camera_follow = false
	_camera.zoom = Vector2(fit_zoom, fit_zoom)
	_mat.set_shader_parameter("camera_zoom", fit_zoom)
	_update_zoom_label(fit_zoom)

	if _marker == null:
		var MarkerScript := preload("res://scripts/shared/PartyMarker.gd")
		_marker = MarkerScript.new()
		_marker.z_index = 10
		add_child(_marker)
		_marker.setup(_hex_size)
	_marker.visible = false  # hidden until engine reports party position

	$LoadingLabel.visible = false
	call_deferred("_start_engine_client")


func _process(delta: float) -> void:
	if _client:
		_client.poll()
	if _camera_follow:
		_camera.position = _camera.position.lerp(_camera_target, 1.0 - pow(0.01, delta))
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

	_zoom_label = Label.new()
	_zoom_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_zoom_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_zoom_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_zoom_label.offset_right = -8
	_zoom_label.offset_top   = 8
	_zoom_label.add_theme_color_override("font_color", Color.WHITE)
	_zoom_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	_zoom_label.add_theme_constant_override("shadow_offset_x", 1)
	_zoom_label.add_theme_constant_override("shadow_offset_y", 1)
	hud.add_child(_zoom_label)

	_enter_btn = Button.new()
	_enter_btn.text = "Enter Hex →"
	_enter_btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_enter_btn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_enter_btn.grow_vertical   = Control.GROW_DIRECTION_BEGIN
	_enter_btn.offset_right  = -8
	_enter_btn.offset_bottom = -8
	_enter_btn.offset_left   = -140
	_enter_btn.offset_top    = -44
	_enter_btn.visible = false
	_enter_btn.pressed.connect(_enter_local)
	hud.add_child(_enter_btn)

	_setup_explore_console(hud)


# ── Explore console ────────────────────────────────────────────────────────────

func _setup_explore_console(hud: CanvasLayer) -> void:
	_console_panel = PanelContainer.new()
	_console_panel.anchor_left   = 0.0
	_console_panel.anchor_top    = 0.0
	_console_panel.anchor_right  = 0.38
	_console_panel.anchor_bottom = 1.0
	_console_panel.offset_right  = 0.0
	_console_panel.offset_bottom = 0.0
	_console_panel.visible       = false

	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.04, 0.04, 0.07, 0.96)
	bg.set_border_width_all(0)
	bg.set_border_width(SIDE_RIGHT, 2)
	bg.border_color = Color(0.22, 0.22, 0.32, 1.0)
	bg.set_content_margin_all(8.0)
	_console_panel.add_theme_stylebox_override("panel", bg)
	hud.add_child(_console_panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 4)
	_console_panel.add_child(vbox)

	_console_history = RichTextLabel.new()
	_console_history.bbcode_enabled    = true
	_console_history.scroll_following  = true
	_console_history.mouse_filter      = Control.MOUSE_FILTER_PASS
	_console_history.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_console_history.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_console_history.add_theme_color_override("default_color",     Color(0.82, 0.80, 0.72))
	_console_history.add_theme_font_size_override("normal_font_size", 14)
	vbox.add_child(_console_history)

	var input_bg := StyleBoxFlat.new()
	input_bg.bg_color = Color(0.07, 0.07, 0.11)
	input_bg.set_border_width_all(0)
	input_bg.set_border_width(SIDE_TOP, 1)
	input_bg.border_color = Color(0.22, 0.22, 0.32)
	input_bg.content_margin_left  = 8
	input_bg.content_margin_right = 8
	input_bg.content_margin_top   = 4
	input_bg.content_margin_bottom = 4

	_console_input = LineEdit.new()
	_console_input.placeholder_text    = "Enter command…  (` to close)"
	_console_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_console_input.custom_minimum_size   = Vector2(0, 32)
	_console_input.add_theme_stylebox_override("normal", input_bg)
	_console_input.add_theme_stylebox_override("focus",  input_bg)
	_console_input.add_theme_color_override("font_color",             Color(0.92, 0.88, 0.72))
	_console_input.add_theme_color_override("font_placeholder_color", Color(0.40, 0.40, 0.50))
	_console_input.text_submitted.connect(_explore_submit)
	_console_input.gui_input.connect(_on_console_gui_input)
	vbox.add_child(_console_input)


func _toggle_explore() -> void:
	_console_open = not _console_open
	_console_panel.visible = _console_open
	if _console_open:
		_console_input.grab_focus()
		if _explore_first:
			_explore_first = false
			_explore_look()
	else:
		_console_input.release_focus()


func _explore_print(text: String) -> void:
	if _console_history == null:
		return
	_console_history.append_text(text + "\n")


func _explore_submit(raw: String) -> void:
	var cmd := raw.strip_edges().to_lower()
	_console_input.clear()
	if cmd.is_empty():
		return
	_input_hist.append(cmd)
	_input_hist_pos = -1
	_explore_print("[color=#555]> %s[/color]" % raw.strip_edges())
	var dir := _dir_offset(cmd)
	if dir != Vector2i.ZERO:
		_explore_move(dir)
		return
	match cmd:
		"look", "l":
			_explore_look()
		"where", "pos":
			if _has_party_pos:
				var hex := _world_to_hex(_party_world_pos)
				_explore_print("[color=#aaa]q=%d  r=%d[/color]" % [hex.x, hex.y])
			else:
				_explore_print("[color=#666]Position unknown.[/color]")
		"map":
			_toggle_explore()
		"help", "?":
			_explore_print("[color=#888]Commands:[/color]")
			_explore_print("[color=#888]  [b]look / l[/b]    describe current hex")
			_explore_print("  [b]where[/b]       show coordinates")
			_explore_print("  [b]map[/b]         close console")
			_explore_print("  Directions:  [b]nw  ne  e  se  sw  w[/b]  (or full names)")
			_explore_print("  Anything else: talk to the narrator.[/color]")
		_:
			_explore_chat(raw.strip_edges())


func _explore_move(dir: Vector2i) -> void:
	if not _has_party_pos:
		_explore_print("[color=#666]You have no position.[/color]")
		return
	if _client == null:
		_explore_print("[color=#666]Engine not connected.[/color]")
		return
	_explore_origin_hex = _world_to_hex(_party_world_pos)
	_explore_prev_hex   = _explore_origin_hex
	var dest := _explore_origin_hex + dir
	_move_party_to(_hex_to_world(dest.x, dest.y))


static func _dir_offset(cmd: String) -> Vector2i:
	match cmd:
		"nw", "northwest": return Vector2i(0,  -1)
		"ne", "northeast": return Vector2i(1,  -1)
		"e",  "east":      return Vector2i(1,   0)
		"se", "southeast": return Vector2i(0,   1)
		"sw", "southwest": return Vector2i(-1,  1)
		"w",  "west":      return Vector2i(-1,  0)
	return Vector2i.ZERO


func _explore_look() -> void:
	if not _has_party_pos:
		_explore_print("[color=#666]You are nowhere.[/color]")
		return
	var hex      := _world_to_hex(_party_world_pos)
	var biome_id := _get_biome_id(hex)
	_explore_print("[color=#c8b870][b]%s[/b][/color]  [color=#444]q=%d r=%d[/color]" % [
		_biome_name(biome_id), hex.x, hex.y])
	# Consume prev before the async fetch so a stale value can't leak into a
	# subsequent look() call if the player moves again before prose returns.
	var prev := _explore_prev_hex
	_explore_prev_hex = Vector2i(-9999, -9999)
	if _prose_cache.has(hex) and prev.x == -9999:
		_explore_print(_prose_cache[hex])
		_explore_print(_explore_exits(hex))
		_explore_print("")
		_console_input.grab_focus()
	else:
		_explore_fetch_prose(hex, prev)


func _explore_fetch_prose(hex: Vector2i, prev_hex: Vector2i = Vector2i(-9999, -9999)) -> void:
	var api_key := OS.get_environment("ANTHROPIC_API_KEY")
	if api_key.is_empty():
		_explore_print(_biome_flavor(_get_biome_id(hex)))
		_explore_print(_explore_exits(hex))
		_explore_print("")
		_console_input.grab_focus()
		return

	var ctx  := _explore_context(hex, prev_hex)
	var body := JSON.stringify({
		"model":      "claude-haiku-4-5-20251001",
		"max_tokens": 100,
		"system":     "You are a terse narrator for a fantasy exploration game. Write 1-2 sentences only. If given 'Traveling from', open with one brief arrival sentence. Then one sentence of local atmosphere. No lists, no game mechanics.",
		"messages":   [{"role": "user", "content": ctx}]
	})

	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(
		func(result, code, _hdrs, resp_body):
			_on_prose_response(result, code, resp_body, hex, http))

	var err := http.request(
		"https://api.anthropic.com/v1/messages",
		["Content-Type: application/json",
		 "x-api-key: " + api_key,
		 "anthropic-version: 2023-06-01"],
		HTTPClient.METHOD_POST, body)

	if err != OK:
		http.queue_free()
		_explore_print(_biome_flavor(_get_biome_id(hex)))
		_explore_print(_explore_exits(hex))
		_explore_print("")
		_console_input.grab_focus()


func _on_prose_response(result: int, code: int, body: PackedByteArray,
                        hex: Vector2i, http: HTTPRequest) -> void:
	http.queue_free()
	var prose := ""
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var parsed := JSON.new()
		if parsed.parse(body.get_string_from_utf8()) == OK and parsed.data is Dictionary:
			var data: Dictionary = parsed.data
			var content: Array = data.get("content", [])
			if content.size() > 0 and content[0] is Dictionary:
				var first := content[0] as Dictionary
				prose = str(first.get("text", ""))
	if prose.is_empty():
		prose = _biome_flavor(_get_biome_id(hex))
	_prose_cache_store(hex, prose)
	if _has_party_pos and _world_to_hex(_party_world_pos) == hex:
		_explore_print(prose)
		_explore_print(_explore_exits(hex))
		_explore_print("")
		if _console_open:
			_console_input.grab_focus()


func _prose_cache_store(hex: Vector2i, prose: String) -> void:
	if not _prose_cache.has(hex):
		_prose_cache_keys.append(hex)
		if _prose_cache_keys.size() > PROSE_CACHE_MAX:
			var evict: Vector2i = _prose_cache_keys[0]
			_prose_cache_keys.remove_at(0)
			_prose_cache.erase(evict)
	_prose_cache[hex] = prose


func _explore_context(hex: Vector2i, prev_hex: Vector2i = Vector2i(-9999, -9999)) -> String:
	var lines: Array[String] = []
	if prev_hex.x != -9999:
		lines.append("Traveling from: %s" % _biome_name(_get_biome_id(prev_hex)))
	var biome_id := _get_biome_id(hex)
	lines.append("Arriving at: %s" % _biome_name(biome_id))

	if _terrain_data and not _terrain_data.is_empty():
		var t := _terrain_data.get_hex(hex.x, hex.y)
		if t != null:
			lines.append("Elevation: %dm" % int(t.height * 4000.0 / 255.0))
			var feats: Array[String] = []
			if t.has_river(): feats.append("river")
			var has_road := false
			var has_trail := false
			for d in 6:
				if t.has_road_on_dir(d):  has_road  = true
				if t.has_trail_on_dir(d): has_trail = true
			if has_road:  feats.append("road")
			if has_trail: feats.append("trail")
			if t.is_port(): feats.append("port")
			if not feats.is_empty():
				lines.append("Features: " + ", ".join(feats))
			if _culture_data and not _culture_data.is_empty():
				var cult := _culture_data.lookup(t.culture_id)
				if cult != null:
					lines.append("Culture: %s" % cult.name)
			if _religion_data and not _religion_data.is_empty():
				var rel := _religion_data.lookup(t.religion_id)
				if rel != null:
					lines.append("Religion: %s" % rel.name)

	if _burg_data and not _burg_data.is_empty():
		var burg: BurgLoader.Burg = _burg_data.by_hex.get(hex, null)
		if burg != null:
			lines.append("Settlement: %s (pop. %d)" % [burg.name, burg.population])

	var dir_names:   Array[String]   = ["NW", "NE",       "E",      "SE",    "SW",       "W"]
	var dir_offsets: Array[Vector2i] = [
		Vector2i(0,-1), Vector2i(1,-1), Vector2i(1,0),
		Vector2i(0,1),  Vector2i(-1,1), Vector2i(-1,0)]
	var exits: Array[String] = []
	for i in 6:
		exits.append("%s: %s" % [dir_names[i], _biome_name(_get_biome_id(hex + dir_offsets[i]))])
	lines.append("Adjacent terrain: " + ", ".join(exits))

	return "\n".join(lines)


func _explore_exits(hex: Vector2i) -> String:
	var dir_names:   Array[String]   = ["NW", "NE",       "E",      "SE",     "SW",      "W"]
	var dir_offsets: Array[Vector2i] = [
		Vector2i(0,-1), Vector2i(1,-1), Vector2i(1,0),
		Vector2i(0,1),  Vector2i(-1,1), Vector2i(-1,0)]
	var parts: Array[String] = []
	for i in 6:
		var nb      := hex + dir_offsets[i]
		var biome_b := _get_biome_id(nb)
		parts.append("[b]%s[/b] [color=#888]%s[/color]" % [dir_names[i], _biome_name(biome_b)])
	return "[color=#555]Exits:[/color]  " + "  ".join(parts)


func _explore_chat(text: String) -> void:
	var api_key := OS.get_environment("ANTHROPIC_API_KEY")
	if api_key.is_empty():
		_explore_print("[color=#555]The narrator is silent. (ANTHROPIC_API_KEY not set)[/color]")
		_console_input.grab_focus()
		return

	# Prepend biome so Haiku has location context without a separate system message.
	var loc_ctx := ""
	if _has_party_pos:
		var hex := _world_to_hex(_party_world_pos)
		loc_ctx = "[%s] " % _biome_name(_get_biome_id(hex))

	_chat_history.append({"role": "user", "content": loc_ctx + text})
	if _chat_history.size() > CHAT_HISTORY_MAX:
		_chat_history.remove_at(0)

	var body := JSON.stringify({
		"model":      "claude-haiku-4-5-20251001",
		"max_tokens": 150,
		"system":     "You are a terse, atmospheric narrator and companion for a fantasy exploration game. Answer questions and banter in character. 1-3 sentences. No meta-language about games or systems.",
		"messages":   _chat_history
	})

	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(
		func(result, code, _hdrs, resp_body):
			_on_chat_response(result, code, resp_body, http))

	var err := http.request(
		"https://api.anthropic.com/v1/messages",
		["Content-Type: application/json",
		 "x-api-key: " + api_key,
		 "anthropic-version: 2023-06-01"],
		HTTPClient.METHOD_POST, body)

	if err != OK:
		http.queue_free()
		_chat_history.pop_back()
		_explore_print("[color=#555]Could not reach narrator.[/color]")
		_console_input.grab_focus()


func _on_chat_response(result: int, code: int, body: PackedByteArray,
                       http: HTTPRequest) -> void:
	http.queue_free()
	var reply := ""
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var parsed := JSON.new()
		if parsed.parse(body.get_string_from_utf8()) == OK and parsed.data is Dictionary:
			var data: Dictionary = parsed.data
			var content: Array = data.get("content", [])
			if content.size() > 0 and content[0] is Dictionary:
				var first := content[0] as Dictionary
				reply = str(first.get("text", ""))
	if reply.is_empty():
		reply = "..."
	_chat_history.append({"role": "assistant", "content": reply})
	if _chat_history.size() > CHAT_HISTORY_MAX:
		_chat_history.remove_at(0)
	_explore_print("[color=#b0c8e0]%s[/color]" % reply)
	_explore_print("")
	if _console_open:
		_console_input.grab_focus()


func _on_console_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed:
		return
	match k.keycode:
		KEY_QUOTELEFT, KEY_ESCAPE:
			_toggle_explore()
			get_viewport().set_input_as_handled()
		KEY_UP:
			if _input_hist.size() > 0:
				_input_hist_pos = clampi(_input_hist_pos + 1, 0, _input_hist.size() - 1)
				_console_input.text = _input_hist[_input_hist.size() - 1 - _input_hist_pos]
				_console_input.set_caret_column(_console_input.text.length())
			get_viewport().set_input_as_handled()
		KEY_DOWN:
			if _input_hist_pos > 0:
				_input_hist_pos -= 1
				_console_input.text = _input_hist[_input_hist.size() - 1 - _input_hist_pos]
				_console_input.set_caret_column(_console_input.text.length())
			elif _input_hist_pos == 0:
				_input_hist_pos = -1
				_console_input.text = ""
			get_viewport().set_input_as_handled()


static func _biome_name(id: int) -> String:
	match id:
		0:  return "Marine"
		1:  return "Hot Desert"
		2:  return "Cold Desert"
		3:  return "Savanna"
		4:  return "Grassland"
		5:  return "Tropical Forest"
		6:  return "Temperate Forest"
		7:  return "Boreal Forest"
		8:  return "Wetland"
		9:  return "Tundra"
		10: return "Glacier"
		11: return "Snow"
		12: return "Mangrove"
	return "Unknown"


static func _biome_flavor(id: int) -> String:
	match id:
		0:  return "Dark water stretches to every horizon. The air tastes of brine and distance."
		1:  return "A relentless sun scorches cracked earth. Heat shimmers on the far ridgeline."
		2:  return "Wind-scoured gravel plains under a pale sky. The cold arrives without warning at night."
		3:  return "Dry grassland broken by flat-topped trees. Dust rises with every footfall."
		4:  return "Rolling hills of grass, green where rain came recently. Insects work the warm air."
		5:  return "Dense canopy blots out the sky. The air is wet and loud with unseen life."
		6:  return "Old oaks and ash, heavy with years. The forest floor is deep with fallen leaves."
		7:  return "Dark spruce press close on all sides. The silence here is broken only by wind."
		8:  return "Reed-choked water in every direction. Your boots sink into black mud."
		9:  return "Frozen ground yields slightly underfoot. Low scrub bends in an endless wind."
		10: return "A vast sheet of blue-white ice, blinding in direct sun. The cold is absolute."
		11: return "Fresh snow has buried all landmarks. Your breath hangs in the still air."
		12: return "Gnarled roots twist into brackish water. The insects here show no mercy."
	return "Unremarkable terrain stretches in every direction."


# ── Engine client ──────────────────────────────────────────────────────────────

func _start_engine_client() -> void:
	_client = ProtohackClientScript.new()
	add_child(_client)
	_client.handshake_done.connect(func():
		print("[RegionMap] Engine handshake complete"))
	_client.worldmap_end.connect(func():
		print("[RegionMap] Engine worldmap ready"))
	_client.engine_error.connect(func(code, msg):
		push_error("[RegionMap] Engine error: %s — %s" % [code, msg]))
	_client.party_position_received.connect(_on_party_position)
	_client.party_moved.connect(_on_party_moved)
	_client.movement_stopped.connect(_on_movement_stopped)
	var relay := ProjectSettings.globalize_path(RELAY_SCRIPT)
	if not _client.start(relay, ENGINE_PATH, WORLD_HEX_PATH, ENGINE_PORT):
		push_error("[RegionMap] Failed to start engine client")
		_client = null


# ── Party position callbacks ───────────────────────────────────────────────────

func _on_party_position(q: int, r: int, mp: int, mp_max: int) -> void:
	_mp_current = mp
	_mp_max     = mp_max
	var loc := _hex_to_locale(q, r)
	if _mat == null:
		# First load is always centered on map center, not party position.
		var c_loc := _world_to_locale(_map_center_world())
		_locale_col = c_loc.x
		_locale_row = c_loc.y
		$LoadingLabel.text = "Loading locale (%d, %d)…" % [c_loc.x, c_loc.y]
		$LoadingLabel.visible = true
		call_deferred("_load_locale_then_place_party", q, r, mp, mp_max)
	else:
		_finish_party_setup(q, r, mp, mp_max)


func _on_party_moved(q: int, r: int, mp: int) -> void:
	_pending_move_dest = Vector2i(-9999, -9999)
	_mp_current = mp
	_update_mp_hud()
	var loc := _hex_to_locale(q, r)
	if loc != Vector2i(_locale_col, _locale_row):
		# Party crossed a locale boundary — reload.
		_locale_col = loc.x
		_locale_row = loc.y
		if _marker:
			_marker.visible = false
		$LoadingLabel.text = "Loading locale (%d, %d)…" % [loc.x, loc.y]
		$LoadingLabel.visible = true
		call_deferred("_load_locale_then_place_party", q, r, mp, _mp_max)
		return
	var dest := _hex_to_world(q, r)
	_party_world_pos = dest
	_has_party_pos   = true
	_reveal_fog(q, r, _region_fog_rad)
	# Engine can emit all moved events + movement_stopped in one poll cycle,
	# so lerp follow may never get a frame. Snap to keep marker centered.
	_camera.position = dest
	_camera_target = dest
	_camera_follow = false
	if _marker:
		_marker.place_at(_camera.position)


func _on_movement_stopped(_reason: String) -> void:
	# If engine never sent world.party_moved, snap marker to commanded destination.
	if _pending_move_dest.x != -9999:
		var dest := _hex_to_world(_pending_move_dest.x, _pending_move_dest.y)
		_party_world_pos = dest
		_has_party_pos   = true
		_reveal_fog(_pending_move_dest.x, _pending_move_dest.y, _region_fog_rad)
		_camera.position = dest
		_camera_target   = dest
		if _marker:
			_marker.place_at(dest)
		if _mat:
			_mat.set_shader_parameter("selected_q", _pending_move_dest.x)
			_mat.set_shader_parameter("selected_r", _pending_move_dest.y)
		_update_sel_panel("Party", "q=%d  r=%d" % [_pending_move_dest.x, _pending_move_dest.y])
		_pending_move_dest = Vector2i(-9999, -9999)
	elif _has_party_pos:
		_camera.position = _party_world_pos
		_camera_target   = _party_world_pos
	_camera_follow = false
	if _marker:
		_marker.flash()
	if _enter_btn and _has_party_pos:
		_enter_btn.visible = true
	if _console_open:
		var current_hex := _world_to_hex(_party_world_pos)
		if _explore_origin_hex.x != -9999 and current_hex == _explore_origin_hex:
			_explore_print("[color=#666]You cannot go that way.[/color]\n")
			_explore_prev_hex = Vector2i(-9999, -9999)
			_console_input.grab_focus()
		else:
			_explore_look()
		_explore_origin_hex = Vector2i(-9999, -9999)


# ── Locale loading ─────────────────────────────────────────────────────────────

func _load_locale_then_place_party(q: int, r: int, mp: int, mp_max: int) -> void:
	await get_tree().process_frame
	var bounds := _locale_hex_bounds(_locale_col, _locale_row)

	var result := _load_hexbin(HEX_GRID_PATH,
		bounds["wx_min"], bounds["wx_max"],
		bounds["wy_min"], bounds["wy_max"],
		bounds["pad_world"])
	if result.is_empty():
		$LoadingLabel.text = "Error loading locale"
		return

	_locale_world_rect = Rect2(
		Vector2(bounds["wx_min"], bounds["wy_min"]),
		Vector2(bounds["world_w"], bounds["world_h"]))

	# Fog: allocate once per locale (full world dims so fog persists across locales).
	if _fog_img == null:
		_fog_img = Image.create(_tex_w_global, _tex_h_global, false, Image.FORMAT_RGBA8)
		_fog_img.fill(Color(0, 0, 0, 0))
		_fog_tex = ImageTexture.create_from_image(_fog_img)

	var tex      := ImageTexture.create_from_image(_hex_img)
	var burg_tex := ImageTexture.create_from_image(_province_img_data)

	var shader := load(SHADER_PATH) as Shader
	_mat        = ShaderMaterial.new()
	_mat.shader = shader
	# Always pass global origin + full world dims to the shader.
	# The shader uses origin_x/y for both UV→world and world→hex, so they must
	# be consistent. The ColorRect covers the full world; the camera bounds to
	# the locale so the user only sees locale data.
	_mat.set_shader_parameter("hex_size",          _hex_size)
	_mat.set_shader_parameter("origin_x",          _origin_x)
	_mat.set_shader_parameter("origin_y",          _origin_y)
	_mat.set_shader_parameter("map_w",             _map_w)
	_mat.set_shader_parameter("map_h",             _map_h)
	_mat.set_shader_parameter("hex_data",          tex)
	_mat.set_shader_parameter("burg_data",         burg_tex)
	_mat.set_shader_parameter("tex_width",         _tex_w_global)
	_mat.set_shader_parameter("tex_height",        _tex_h_global)
	_mat.set_shader_parameter("r_min",             _r_min_val)
	_mat.set_shader_parameter("selected_q",        -9999)
	_mat.set_shader_parameter("selected_r",        -9999)
	_mat.set_shader_parameter("selected_realm_id", -1)
	_mat.set_shader_parameter("selected_burg_id",  -1)
	_mat.set_shader_parameter("selection_mode",     0)
	_mat.set_shader_parameter("fog_data",           _fog_tex)

	_rect.position = Vector2(_origin_x, _origin_y)
	_rect.size     = Vector2(_map_w, _map_h)
	_rect.material = _mat
	_rect.visible  = true

	# Camera: fit locale width to viewport, centered on locale for now.
	# _finish_party_setup will immediately re-center on the party marker.
	var vp_size  := get_viewport_rect().size
	var fit_zoom := vp_size.x / float(bounds["world_w"])
	_camera.zoom = Vector2(fit_zoom, fit_zoom)
	_mat.set_shader_parameter("camera_zoom", fit_zoom)
	_update_zoom_label(fit_zoom)

	# Party marker (create once, reuse on locale transitions).
	if _marker == null:
		var MarkerScript := preload("res://scripts/shared/PartyMarker.gd")
		_marker = MarkerScript.new()
		_marker.z_index = 10
		add_child(_marker)
		_marker.setup(_hex_size)

	$LoadingLabel.visible = false
	_finish_party_setup(q, r, mp, mp_max)


func _finish_party_setup(q: int, r: int, mp: int, mp_max: int) -> void:
	_mp_current = mp
	_mp_max     = mp_max
	_update_mp_hud()
	_sel_panel.visible = true
	var party_wpos := _hex_to_world(q, r)
	_party_world_pos = party_wpos   # always the actual party hex, never map center
	_has_party_pos   = true
	_reveal_fog(q, r, _region_fog_rad)
	var cam_pos := party_wpos
	if _startup_center_pending:
		cam_pos = _map_center_world()  # only the camera starts at map center
		_startup_center_pending = false
	_camera.position = cam_pos
	_camera_target = cam_pos
	_camera_follow = false
	if _marker:
		_marker.place_at(party_wpos)  # marker always at party hex
		_marker.visible = true
	if _enter_btn:
		_enter_btn.visible = true
		_update_sel_panel("Party", "q=%d  r=%d" % [q, r])


# ── Locale helpers ─────────────────────────────────────────────────────────────

func _hex_to_locale(q: int, r: int) -> Vector2i:
	var wpos := _hex_to_world(q, r)
	return _world_to_locale(wpos)


func _world_to_locale(wpos: Vector2) -> Vector2i:
	var col  := int(floor((wpos.x - _origin_x) / (_map_w / _locales_cols)))
	var row  := int(floor((wpos.y - _origin_y) / (_map_h / _locales_rows)))
	return Vector2i(clampi(col, 0, _locales_cols - 1),
	                clampi(row, 0, _locales_rows - 1))


func _map_center_world() -> Vector2:
	return Vector2(_origin_x + _map_w * 0.5, _origin_y + _map_h * 0.5)


func _viewport_center_world() -> Vector2:
	var center_px := get_viewport_rect().size * 0.5
	return get_viewport().get_canvas_transform().affine_inverse() * center_px


func _locale_hex_bounds(col: int, row: int) -> Dictionary:
	var lw   := _map_w / _locales_cols
	var lh   := _map_h / _locales_rows
	var wx0  := _origin_x + col * lw
	var wy0  := _origin_y + row * lh
	var wx1  := wx0 + lw
	var wy1  := wy0 + lh
	# World-space padding avoids sheared clipping from fixed q/r range filtering.
	var pad_world := _hex_size * 2.0
	return {
		"wx_min":    wx0,
		"wy_min":    wy0,
		"wx_max":    wx1,
		"wy_max":    wy1,
		"world_w":   lw,
		"world_h":   lh,
		"pad_world": pad_world,
	}


# ── Fog ────────────────────────────────────────────────────────────────────────

func _reveal_fog(q0: int, r0: int, radius: int) -> void:
	if _fog_img == null or _fog_tex == null:
		return
	for dq in range(-radius, radius + 1):
		var r1 := maxi(-radius, -dq - radius)
		var r2 := mini( radius, -dq + radius)
		for dr in range(r1, r2 + 1):
			_set_fog_pixel(q0 + dq, r0 + dr)
	_fog_tex.update(_fog_img)


func _set_fog_pixel(q: int, r: int) -> void:
	var q_left := -_floor_div2(r) - 2
	var q_off  := q - q_left
	var r_off  := r - _r_min_val
	if q_off < 0 or q_off >= _fog_img.get_width() or r_off < 0 or r_off >= _fog_img.get_height():
		return
	_fog_img.set_pixel(q_off, r_off, Color(1.0, 0.0, 0.0))


# ── File loading ───────────────────────────────────────────────────────────────

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


func _read_hexbin_header(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("RegionMap: not found: " + path); return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("RegionMap: cannot open: " + path); return {}
	var buf := f.get_buffer(72)
	f.close()
	if buf.size() < 72:
		push_error("RegionMap: header too short"); return {}
	if buf.slice(0, 4).get_string_from_ascii() != "HXB1":
		push_error("RegionMap: bad magic"); return {}
	return {
		"tex_w":    buf.decode_u16(26),
		"tex_h":    buf.decode_u16(28),
		"r_min":    buf.decode_s16(22),
		"hex_size": buf.decode_double(32),
		"origin_x": buf.decode_double(40),
		"origin_y": buf.decode_double(48),
		"map_w":    buf.decode_double(56),
		"map_h":    buf.decode_double(64),
	}


func _load_hexbin(path: String,
				  wx_min: float, wx_max: float,
				  wy_min: float, wy_max: float,
				  pad_world: float) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("RegionMap: not found: " + path); return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("RegionMap: cannot open: " + path); return {}

	var hdr := f.get_buffer(72)
	if hdr.size() < 72:
		push_error("RegionMap: header too short"); f.close(); return {}
	if hdr.slice(0, 4).get_string_from_ascii() != "HXB1":
		push_error("RegionMap: bad magic"); f.close(); return {}

	var biome_cnt    := hdr.decode_u16(6)
	var hex_count    := hdr.decode_u32(8)
	var strtab_size  := hdr.decode_u32(12)
	var realm_cnt    := hdr.decode_u16(16)
	var province_cnt := hdr.decode_u16(18)
	var burg_cnt     := hdr.decode_u16(20)

	var strtab := f.get_buffer(strtab_size)
	f.get_buffer(biome_cnt * 4)

	var realm_buf := f.get_buffer(realm_cnt * 6)
	_realm_names.clear()
	for i in realm_cnt:
		var base := i * 6
		var rid  := realm_buf.decode_u16(base)
		var off  := realm_buf.decode_u32(base + 2)
		if rid > 0:
			_realm_names[rid] = _strtab_get(strtab, off)

	var prov_buf := f.get_buffer(province_cnt * 10)
	_province_names.clear()
	_province_capitals.clear()
	for i in province_cnt:
		var base     := i * 10
		var pid      := prov_buf.decode_u16(base)
		var name_off := prov_buf.decode_u32(base + 2)
		var cap_off  := prov_buf.decode_u32(base + 6)
		if pid > 0:
			_province_names[pid]    = _strtab_get(strtab, name_off)
			_province_capitals[pid] = _strtab_get(strtab, cap_off)

	f.get_buffer(burg_cnt * 4)
	var recs := f.get_buffer(hex_count * 10)
	f.close()

	# Use full-world texture dimensions so fog and shader indexing stay consistent.
	var tw := _tex_w_global
	var th := _tex_h_global
	var img_data  := PackedByteArray(); img_data.resize(tw * th * 4); img_data.fill(0)
	var burg_data := PackedByteArray(); burg_data.resize(tw * th * 2); burg_data.fill(0)

	var loaded := 0
	var sqrt3 := sqrt(3.0)
	var wx_lo := wx_min - pad_world
	var wx_hi := wx_max + pad_world
	var wy_lo := wy_min - pad_world
	var wy_hi := wy_max + pad_world
	for i in hex_count:
		var base     := i * 10
		var q        := recs.decode_s16(base)
		var r        := recs.decode_s16(base + 2)
		# Filter by locale world-space rect to avoid axial shear clipping.
		var wx := _hex_size * sqrt3 * (q + r * 0.5) + _origin_x
		var wy := _hex_size * 1.5   *  r             + _origin_y
		if wx < wx_lo or wx > wx_hi or wy < wy_lo or wy > wy_hi:
			continue
		var biome_id := recs.decode_u8(base + 4)
		var realm_id := recs.decode_u8(base + 5)
		var prov_id  := recs.decode_u16(base + 6)
		var q_left   := -_floor_div2(r) - 2
		var q_off    := q - q_left
		var r_off    := r - _r_min_val
		if q_off < 0 or q_off >= tw or r_off < 0 or r_off >= th:
			continue
		var pix      := r_off * tw + q_off
		img_data.encode_u8(pix * 4,     biome_id)
		img_data.encode_u8(pix * 4 + 1, realm_id)
		img_data.encode_u8(pix * 4 + 3, 255)
		burg_data.encode_u8(pix * 2,     prov_id >> 8)
		burg_data.encode_u8(pix * 2 + 1, prov_id & 0xFF)
		loaded += 1

	print("[RegionMap] locale (%d,%d): loaded %d / %d hexes" % [_locale_col, _locale_row, loaded, hex_count])
	_hex_img           = Image.create_from_data(tw, th, false, Image.FORMAT_RGBA8, img_data)
	_province_img_data = Image.create_from_data(tw, th, false, Image.FORMAT_RG8,   burg_data)
	return {"tex_w": tw, "tex_h": th}


static func _strtab_get(strtab: PackedByteArray, offset: int) -> String:
	if offset >= strtab.size():
		return ""
	var end := strtab.find(0, offset)
	if end < 0: end = strtab.size()
	return strtab.slice(offset, end).get_string_from_utf8()


static func _floor_div2(r: int) -> int:
	return r >> 1


# ── Input ──────────────────────────────────────────────────────────────────────

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
					_move_party_to(world_pos)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var world_pos := get_viewport().get_canvas_transform().affine_inverse() * mb.position
			_select_by_zoom(world_pos)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_toward_marker(1.15)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_toward_marker(1.0 / 1.15)

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _is_dragging:
			_drag_dist += mm.relative.length()
			var delta := mm.position - _drag_start
			_camera.position = _camera_start - delta / _camera.zoom.x
			_clamp_camera_to_locale()
		_update_hover(mm.position)

	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			if k.keycode == KEY_X and _has_party_pos:
				_camera.position = _party_world_pos
				_camera_follow   = false
			elif k.keycode == KEY_QUOTELEFT:
				_toggle_explore()


# ── Selection ──────────────────────────────────────────────────────────────────

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
	_selected_hex = hex
	_update_sel_panel("Hex", "q=%d  r=%d" % [hex.x, hex.y])


func _move_party_to(world_pos: Vector2) -> void:
	var hex := _world_to_hex(world_pos)
	if _mat:
		_mat.set_shader_parameter("selection_mode", 0)
		_mat.set_shader_parameter("selected_q", hex.x)
		_mat.set_shader_parameter("selected_r", hex.y)
	_selected_hex = hex
	_pending_move_dest = hex
	_update_sel_panel("→", "q=%d  r=%d" % [hex.x, hex.y])
	if _client:
		_client.send_command("> player.command action=world_move q=%d r=%d" % [hex.x, hex.y])


func _select_province(province_id: int) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selection_mode",   1)
	_mat.set_shader_parameter("selected_burg_id", province_id)
	if _enter_btn:
		_enter_btn.visible = false
	var pname: String   = _province_names.get(province_id, "")
	var capital: String = _province_capitals.get(province_id, "")
	_update_sel_panel("Province", pname if capital.is_empty() else pname + "  ·  " + capital)


func _select_realm(realm_id: int) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selection_mode",    2)
	_mat.set_shader_parameter("selected_realm_id", realm_id)
	if _enter_btn:
		_enter_btn.visible = false
	_update_sel_panel("Realm", _realm_names.get(realm_id, ""))


func _enter_local() -> void:
	if not _has_party_pos:
		return
	var hex := _world_to_hex(_party_world_pos)
	GameState.go_local(hex.x, hex.y, _get_biome_id(hex))


func _get_biome_id(hex: Vector2i) -> int:
	var c := _sample_hex_pixel(hex)
	return int(c.r * 255.0 + 0.5) if c.a >= 0.5 else 0


# ── HUD helpers ────────────────────────────────────────────────────────────────

func _update_sel_panel(type: String, label: String) -> void:
	_sel_label.text = type + "  —  " + label


func _update_mp_hud() -> void:
	if _mp_label:
		_mp_label.text = "MP: %d / %d" % [_mp_current, _mp_max]
	_sel_panel.visible = true
	_sel_panel.reset_size()


func _update_zoom_label(zoom: float) -> void:
	if _zoom_label:
		_zoom_label.text = "zoom: %.2f×" % zoom


func _update_hover(screen_pos: Vector2) -> void:
	if _mat == null:
		_hover_label.visible = false
		return
	var world_pos := get_viewport().get_canvas_transform().affine_inverse() * screen_pos
	var hex  := _world_to_hex(world_pos)
	var text := "px=(%.0f, %.0f)  hex=(%d, %d)" % [screen_pos.x, screen_pos.y, hex.x, hex.y]
	_hover_label.visible = not text.is_empty()
	if not text.is_empty():
		_hover_label.text = text
		_hover_label.position = screen_pos + Vector2(14, -22)


# ── Coordinate helpers ─────────────────────────────────────────────────────────

func _hex_to_world(q: int, r: int) -> Vector2:
	var sqrt3 := sqrt(3.0)
	return Vector2(
		_hex_size * sqrt3 * (q + r * 0.5) + _origin_x,
		_hex_size * 1.5   *  r             + _origin_y
	)


func _world_to_hex(world_pos: Vector2) -> Vector2i:
	var sqrt3 := sqrt(3.0)
	var r_f := (world_pos.y - _origin_y) / (1.5 * _hex_size)
	var q_f := ((world_pos.x - _origin_x) / (sqrt3 * _hex_size)) - r_f * 0.5
	return _hex_round(q_f, r_f)


func _zoom_toward_marker(factor: float) -> void:
	var old_zoom := _camera.zoom.x
	var new_zoom := clampf(old_zoom * factor, 0.1, 50.0)
	if _has_party_pos:
		_camera.position = _party_world_pos - (_party_world_pos - _camera.position) * (old_zoom / new_zoom)
	_camera.zoom = Vector2(new_zoom, new_zoom)
	if _mat: _mat.set_shader_parameter("camera_zoom", new_zoom)
	_update_zoom_label(new_zoom)
	_clamp_camera_to_locale()


func _clamp_camera_to_locale() -> void:
	if _locale_world_rect == Rect2():
		return
	var vp_half := get_viewport_rect().size * 0.5 / _camera.zoom.x
	var lo := _locale_world_rect.position + vp_half
	var hi := _locale_world_rect.end      - vp_half
	if lo.x <= hi.x:
		_camera.position.x = clamp(_camera.position.x, lo.x, hi.x)
	if lo.y <= hi.y:
		_camera.position.y = clamp(_camera.position.y, lo.y, hi.y)


# ── Texture sampling ───────────────────────────────────────────────────────────

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
	return Vector2i(rx, rz)
