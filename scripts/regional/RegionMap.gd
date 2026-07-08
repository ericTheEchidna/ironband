extends Node2D

const WORLD_NAME     := "cheia"
const WORLD_DIR      := "res://worlds/" + WORLD_NAME
const HEX_GRID_PATH  := WORLD_DIR + "/hex_grid.hexbin"
const LOCALES_PATH   := WORLD_DIR + "/locales.json"
const TERRAIN_PATH   := WORLD_DIR + "/hex_terrain.bin"
const BURGS_PATH     := WORLD_DIR + "/burgs.bin"
const CULTURES_PATH  := WORLD_DIR + "/cultures.bin"
const RELIGIONS_PATH := WORLD_DIR + "/religions.bin"
const ROUTES_PATH           := WORLD_DIR + "/routes.bin"
const RIVERS_PATH           := WORLD_DIR + "/rivers.bin"
const SHADER_PATH           := "res://shaders/WorldMap.gdshader"

const _RiverLoader := preload("res://scripts/loaders/RiverLoader.gd")
const _RouteLoader := preload("res://scripts/loaders/RouteLoader.gd")
const _BiomeColors := preload("res://scripts/shared/BiomeColors.gd")
const _WorldConfig := preload("res://scripts/shared/WorldConfig.gd")
# Active cell-graph world's locales.json — swap Azgaar exports by changing
# WorldConfig.CELL_WORLD_NAME, not this path.
const CELL_LOCALES_PATH := "res://worlds/" + _WorldConfig.CELL_WORLD_NAME + "/locales.json"

const ROAD_COLOR   := Color(0.75, 0.60, 0.30, 0.85)
const TRAIL_COLOR  := Color(0.65, 0.50, 0.25, 0.55)
const FERRY_COLOR  := Color(0.35, 0.60, 0.85, 0.55)
const RIVER_COLOR  := Color(0.28, 0.55, 0.90, 0.80)
const RIVER_SCALE  := 4.0  # Azgaar width units × hex_size × RIVER_SCALE = world pixels
const DEBUG_FOCUS_HEX       := Vector2i(373, 252)
const DEBUG_LOG             := "/tmp/ironband_debug.log"

@export var zoom_thresh_province: float = 3.0
@export var zoom_thresh_hex:      float = 25.0

var _camera: PanZoomCamera2D
var _rect:   ColorRect
var _mat:    ShaderMaterial

# Set from hexbin header at startup (fast 72-byte read).
var _hex_size:      float = 1.0
var _origin_x:      float = 0.0
var _origin_y:      float = 0.0
var _r_min_val:     int   = 0
var _map_w:         float = 0.0
var _map_h:         float = 0.0
var _fit_zoom:      float = 1.0
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

@onready var _engine := get_node("/root/IronbandEngine")
var _is_cellgraph: bool = false
var _cell_ids:     PackedInt64Array = PackedInt64Array()
var _cell_sites:   PackedVector2Array = PackedVector2Array()
var _cell_hash:    CellSpatialHash = null
var _cellgraph_member_ids: PackedInt64Array = PackedInt64Array()  # set by _resolve_cellgraph_province_membership
var _hovered_cell_id: int = -1

# Hex-mode locale membership (IRONBAND-062) — set by _resolve_hex_locale_membership,
# consumed by _load_static_map_preview's shader context-dimming uniforms.
var _locale_province_id:  int     = 0
var _locale_realm_id:     int     = 0
var _locale_is_wilderness: bool   = false
var _locale_center:       Vector2 = Vector2.ZERO
var _locale_radius:       float   = 0.0

var _hover_label: Label
var _sel_panel:   PanelContainer
var _sel_label:   Label
var _mp_label:    Label
var _zoom_label:  Label
var _enter_btn:   Button
var _info_panel:      PanelContainer = null
var _info_type_lbl:   Label          = null
var _info_name_lbl:   Label          = null
var _info_detail_lbl: Label          = null
var _info_locked:     bool           = false

var _route_layer: Node2D = null
var _river_layer: Node2D = null

var _fog_img: Image        = null
var _fog_tex: ImageTexture = null

var _marker: Node2D = null
var _mp_current: int      = 0
var _mp_max:     int      = 6
var _party_world_pos: Vector2 = Vector2.ZERO
var _entry_world: Vector2 = Vector2(-1e9, -1e9)
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

# Visited hex history — ordered arrival list, capped at VISITED_MAX
const VISITED_MAX := 50
var _visited_hexes: Array[Vector2i] = []
var _visited_set:   Dictionary      = {}  ## Vector2i → int (cumulative visit count)

# Inventory: lowercase item name → quantity
var _inventory: Dictionary = {}

# Ground items per hex (discovered on first visit, persist until taken)
var _ground_items: Dictionary = {}  ## Vector2i → Array[String]

# Hex event log: lasting things that happened here (encounters, player actions via MEMORY tag).
# Capped at HEX_EVENTS_MAX per hex; oldest entry evicted when full.
# Fed into _explore_context so Haiku acknowledges history on revisits.
var _hex_events: Dictionary = {}  ## Vector2i → Array[String]
const HEX_EVENTS_MAX := 8

# First-visit prose per hex — set once in _prose_cache_store, never overwritten.
# Gives Haiku a stable "first impression" anchor even after many revisits.
var _hex_lore: Dictionary = {}  ## Vector2i → String

# Pending event roll: set on arrival, consumed by prose callback
var _pending_event_roll: bool = false
const ITEM_CHANCE      := 0.22
const ENCOUNTER_CHANCE := 0.16

# State persistence — dirty flag + debounce (push at most once per 2 s)
var _state_dirty:       bool  = false
var _state_dirty_timer: float = 0.0
const STATE_DEBOUNCE_SEC := 2.0

# Companion data (loaded at startup for explore prose context)
var _terrain_data:   HexTerrainLoader.TerrainData = null
var _burg_data:      BurgLoader.BurgData           = null
var _burg_layer:     BurgMarkerLayer                = null
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

	if _engine.get_world_format() == "cellgraph":
		_ready_cellgraph()
		return

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

	if GameState.pending_locale_col >= 0:
		_locale_col = GameState.pending_locale_col
		_locale_row = GameState.pending_locale_row

	if GameState.has_pending_entry_world():
		_entry_world = GameState.consume_pending_entry_world()

	# Membership (and therefore the locale's bounding box) must be known
	# before _apply_fit_camera() runs, so the camera frames the actual
	# realm/province — not a generic grid square (IRONBAND-062).
	_resolve_hex_locale_membership()
	_apply_fit_camera()

	_terrain_data  = HexTerrainLoader.load_file(TERRAIN_PATH, HEX_GRID_PATH, _r_min_val, _tex_w_global)
	_burg_data     = BurgLoader.load_file(BURGS_PATH)
	_culture_data  = CultureLoader.load_file(CULTURES_PATH)
	_religion_data = ReligionLoader.load_file(RELIGIONS_PATH)

	$LoadingLabel.text = "Loading map…"
	$LoadingLabel.visible = true
	call_deferred("_load_static_map_preview")


func _ready_cellgraph() -> void:
	# Cell-graph regional zoom (subsystem 3, Task 7): true polygon borders
	# for viewport-visible cells, no fill (the global atlas already covers
	# fill; see the plan's Task 7 note on this being the lower-risk default),
	# no terrain/burg/culture/religion loaders (all hex-binary-format
	# specific — not applicable to cell worlds; regional-zoom cell-mode info
	# enrichment is out of scope for this plan).
	_is_cellgraph = true
	_hex_size = 1.0  # placeholder — only feeds _locale_hex_bounds' padding + debug logging

	var extent: Vector2 = _engine.get_world_extent()
	_map_w = extent.x
	_map_h = extent.y
	_origin_x = 0.0
	_origin_y = 0.0

	var lcfg := _load_json(CELL_LOCALES_PATH)
	_locales_cols   = int(lcfg.get("cols", 5))
	_locales_rows   = int(lcfg.get("rows", 2))

	if GameState.pending_locale_col >= 0:
		_locale_col = GameState.pending_locale_col
		_locale_row = GameState.pending_locale_row

	if GameState.has_pending_entry_world():
		_entry_world = GameState.consume_pending_entry_world()

	# Membership (and therefore the province's bounding box) must be known
	# before _apply_fit_camera() runs, so the camera frames the province
	# itself instead of the generic locale-grid square.
	_resolve_cellgraph_province_membership()
	_apply_fit_camera()

	$LoadingLabel.text = "Loading cells…"
	$LoadingLabel.visible = true
	call_deferred("_load_cellgraph_locale")


const _CELLGRAPH_PROVINCE_MAX_CELLS := 4000

## Adjacent non-selected cells rendered as greyed-out background context (not
## interactive — see _load_cellgraph_locale's context_layer). Tunable by eye;
## no automated way to verify the visual result, see plan doc.
const _CELLGRAPH_CONTEXT_BBOX_GROW  := 0.6                          # grow _locale_world_rect by this × its own max(w,h)
const _CELLGRAPH_CONTEXT_MAX_CELLS  := 4000                         # same cap style as the province BFS above
const _CELLGRAPH_CONTEXT_TINT       := Color(0.35, 0.35, 0.38, 1.0) # grey blend target
const _CELLGRAPH_CONTEXT_TINT_RATIO := 0.65                         # 0 = full biome color, 1 = full grey

## Finds the province (or realm, for provinceless wilderness) containing the
## entry point, BFS-collects every cell in it, and sets _locale_world_rect to
## that province's bounding box (with padding) — this is what makes the
## camera frame the province rather than the generic locale-grid square.
func _resolve_cellgraph_province_membership() -> void:
	var all_ids: PackedInt64Array = _engine.get_cell_ids()
	var all_sites: PackedVector2Array = _engine.get_cell_sites()

	var reference_point := _entry_world if _entry_world.x > -1e8 else Vector2(_map_w * 0.5, _map_h * 0.5)
	var reference_id := _nearest_cell(all_ids, all_sites, reference_point)

	_cellgraph_member_ids = PackedInt64Array()
	if reference_id == -1:
		return
	_cellgraph_member_ids = _bfs_same_province(reference_id, reference_point)

	var bbox := Rect2()
	var has_bbox := false
	for id in _cellgraph_member_ids:
		var poly: PackedVector2Array = _engine.get_cell_polygon(id)
		for p in poly:
			if not has_bbox:
				bbox = Rect2(p, Vector2.ZERO)
				has_bbox = true
			else:
				bbox = bbox.expand(p)
	if has_bbox:
		# Pad so the province isn't flush against the viewport edges; a flat
		# minimum keeps single-cell provinces from padding to near-nothing.
		var pad := maxf(maxf(bbox.size.x, bbox.size.y) * 0.2, 2.0)
		_locale_world_rect = bbox.grow(pad)


const _HEX_LOCALE_MAX_HEXES := 30000  # BFS safety cap — same style as _CELLGRAPH_PROVINCE_MAX_CELLS

const _HEX_NEIGHBOR_DIRS := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1),
	Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 1),
]

## Reads hex_grid.hexbin's realm_id/province_id for every hex, keyed by (q,r).
## Used only for locale-membership BFS below — skips the texture-writing work
## _load_hexbin does, since membership resolution needs random neighbor
## lookups across the whole map, not a windowed render.
func _load_hex_realm_province_index(path: String) -> Dictionary:
	var index := {}
	if not FileAccess.file_exists(path):
		return index
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return index
	var hdr := f.get_buffer(72)
	if hdr.size() < 72 or hdr.slice(0, 4).get_string_from_ascii() != "HXB1":
		f.close(); return index

	var hxb_version  := hdr.decode_u16(4)
	var biome_cnt    := hdr.decode_u16(6)
	var hex_count    := hdr.decode_u32(8)
	var strtab_size  := hdr.decode_u32(12)
	var realm_cnt    := hdr.decode_u16(16)
	var province_cnt := hdr.decode_u16(18)
	var burg_cnt     := hdr.decode_u16(20)
	var hex_rec_size := 11 if hxb_version >= 2 else 10

	f.get_buffer(strtab_size + biome_cnt * 4 + realm_cnt * 6 + province_cnt * 10 + burg_cnt * 4)
	var recs := f.get_buffer(hex_count * hex_rec_size)
	f.close()

	for i in hex_count:
		var base        := i * hex_rec_size
		var q           := recs.decode_s16(base)
		var r           := recs.decode_s16(base + 2)
		var realm_id    := recs.decode_u8(base + 5)
		var province_id := recs.decode_u16(base + 6)
		index[Vector2i(q, r)] = {"realm_id": realm_id, "province_id": province_id}
	return index


func _hex_center_world(q: int, r: int) -> Vector2:
	var sqrt3 := sqrt(3.0)
	return Vector2(
		_hex_size * sqrt3 * (q + r * 0.5) + _origin_x,
		_hex_size * 1.5   *  r             + _origin_y)


## Hex-mode counterpart to _resolve_cellgraph_province_membership(): BFS out
## from the entry hex over axial neighbors sharing the same province_id (or
## realm_id, for provinceless territory), so double-click-to-enter frames the
## actual realm/province instead of a generic locale-grid square
## (IRONBAND-062). Sets _locale_world_rect (consumed by _apply_fit_camera and
## _load_static_map_preview's windowing) plus _locale_province_id/
## _locale_realm_id/_locale_is_wilderness/_locale_center/_locale_radius
## (consumed by the shader's context-dimming uniforms).
func _resolve_hex_locale_membership() -> void:
	var index := _load_hex_realm_province_index(HEX_GRID_PATH)
	if index.is_empty():
		return

	var reference_point := _entry_world if _entry_world.x > -1e8 \
		else Vector2(_origin_x + _map_w * 0.5, _origin_y + _map_h * 0.5)
	var entry_hex: Vector2i = _world_to_hex(reference_point)
	var entry: Dictionary = index.get(entry_hex, {"realm_id": 0, "province_id": 0})
	var province_id: int = entry["province_id"]
	var realm_id: int    = entry["realm_id"]

	_locale_province_id  = province_id
	_locale_realm_id     = realm_id
	_locale_is_wilderness = province_id <= 0 and realm_id <= 0

	if _locale_is_wilderness:
		# No political region to frame — same fallback as cellgraph's
		# wilderness case: a radius-bounded patch around the entry point.
		_locale_center = reference_point
		_locale_radius = _cellgraph_wilderness_radius()
		var half := Vector2(_locale_radius, _locale_radius)
		_locale_world_rect = Rect2(reference_point - half, half * 2.0)
		return

	var visited := {entry_hex: true}
	var queue: Array[Vector2i] = [entry_hex]
	var member_hexes: Array[Vector2i] = [entry_hex]
	var qi := 0
	while qi < queue.size() and member_hexes.size() < _HEX_LOCALE_MAX_HEXES:
		var cur: Vector2i = queue[qi]
		qi += 1
		for d in _HEX_NEIGHBOR_DIRS:
			var nb: Vector2i = cur + d
			if visited.has(nb):
				continue
			visited[nb] = true
			var ninfo = index.get(nb)
			if ninfo == null:
				continue
			var same: bool = (ninfo["province_id"] == province_id) if province_id > 0 \
				else (ninfo["realm_id"] == realm_id)
			if same:
				member_hexes.append(nb)
				queue.append(nb)

	var bbox := Rect2()
	var has_bbox := false
	for h in member_hexes:
		var wp := _hex_center_world(h.x, h.y)
		if not has_bbox:
			bbox = Rect2(wp, Vector2.ZERO)
			has_bbox = true
		else:
			bbox = bbox.expand(wp)
	if has_bbox:
		var pad := maxf(maxf(bbox.size.x, bbox.size.y) * 0.2, _hex_size * 4.0)
		_locale_world_rect = bbox.grow(pad)


var _cell_grain_mat: ShaderMaterial = null

## Lazily builds the shared grain-overlay material for cell-graph biome
## fills — one material for every fill Polygon2D, with biome_id passed per
## instance (see shaders/CellBiomeGrain.gdshader) so the textures/shader
## only need setting up once regardless of cell count.
func _cell_grain_material() -> ShaderMaterial:
	if _cell_grain_mat != null:
		return _cell_grain_mat
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/CellBiomeGrain.gdshader")
	mat.set_shader_parameter("tex_grass",  load("res://material/aerial_grass_rock/aerial_grass_rock_diff_2k.png"))
	mat.set_shader_parameter("tex_forest", load("res://material/forest_ground/forest_ground_04_diff_2k.png"))
	mat.set_shader_parameter("tex_rocky",  load("res://material/rocky_terrain/rocky_terrain_02_diff_2k.png"))
	mat.set_shader_parameter("tex_snow",   load("res://material/snow/snow_02_diff_2k.png"))
	_cell_grain_mat = mat
	return _cell_grain_mat


func _load_cellgraph_locale() -> void:
	var member_ids := _cellgraph_member_ids
	var all_ids: PackedInt64Array = _engine.get_cell_ids()
	var all_sites: PackedVector2Array = _engine.get_cell_sites()

	var id_to_site := {}
	for i in range(all_ids.size()):
		id_to_site[all_ids[i]] = all_sites[i]
	var member_sites := PackedVector2Array()
	for id in member_ids:
		member_sites.push_back(id_to_site.get(id, Vector2.ZERO))

	_cell_ids = member_ids
	_cell_sites = member_sites
	_cell_hash = CellSpatialHash.new()
	if member_ids.size() > 0:
		var area: float = _locale_world_rect.size.x * _locale_world_rect.size.y
		var bucket_size: float = sqrt(area / float(member_ids.size())) * 2.0
		_cell_hash.build(member_ids, member_sites, bucket_size)

	# Backdrop behind the province fill — without it, the padding around the
	# province (and anything the camera can still pan/zoom past) shows the
	# viewport's raw clear color, which reads as a blue ocean rather than
	# neutral unmapped space.
	_rect.position = Vector2(_origin_x, _origin_y)
	_rect.size     = Vector2(_map_w, _map_h)
	_rect.color    = Color(0.25, 0.25, 0.25, 1.0)
	_rect.material = null
	_rect.z_index  = -2  # behind fill_layer's cell polygons (z_index -1)
	_rect.visible  = true

	# Fill only — no cell outlines. RegionMap is its own scene/viewport, not
	# an overlay on GlobalMap's atlas, so without a fill the locale was
	# rendering as a bare wireframe on nothing; outlines on top of that
	# looked like clutter once the province itself is the only thing shown.
	var fill_layer := Node2D.new()
	fill_layer.name = "CellFills"
	fill_layer.z_index = -1
	add_child(fill_layer)

	var grain_mat := _cell_grain_material()
	for id in member_ids:
		var poly: PackedVector2Array = _engine.get_cell_polygon(id)
		if poly.size() < 3:
			continue

		var info: Dictionary = _engine.get_location_info(id)
		var biome_id: int = int(info.get("biome_id", 0)) if not info.is_empty() else 0
		var fill := Polygon2D.new()
		fill.polygon = poly
		fill.color = _BiomeColors.color(biome_id)
		fill.material = grain_mat
		fill.set_instance_shader_parameter("biome_id", biome_id)
		fill_layer.add_child(fill)

	# Adjacent, non-selected cells rendered as flat greyed-out background —
	# purely visual context (never added to _cell_hash, so they stay
	# non-interactive). No material/grain shader on purpose: it helps them
	# recede versus the crisper textured member cells above, and avoids any
	# shader work for a cosmetic feature. Camera pan/zoom is untouched by this
	# block entirely — it only ever reads _locale_world_rect, never writes it.
	var member_set := {}
	for id in member_ids:
		member_set[id] = true

	var context_bbox := _locale_world_rect.grow(
		maxf(_locale_world_rect.size.x, _locale_world_rect.size.y) * _CELLGRAPH_CONTEXT_BBOX_GROW)

	var context_layer := Node2D.new()
	context_layer.name = "ContextFills"
	context_layer.z_index = -2  # same tier as _rect; added after it so it draws on top of the flat backdrop
	add_child(context_layer)

	var context_count := 0
	var capped := false
	for i in range(all_ids.size()):
		if context_count >= _CELLGRAPH_CONTEXT_MAX_CELLS:
			capped = true
			break
		var id: int = all_ids[i]
		if member_set.has(id):
			continue
		if not context_bbox.has_point(all_sites[i]):
			continue

		var poly: PackedVector2Array = _engine.get_cell_polygon(id)
		if poly.size() < 3:
			continue

		var info: Dictionary = _engine.get_location_info(id)
		var biome_id: int = int(info.get("biome_id", 0)) if not info.is_empty() else 0
		var fill := Polygon2D.new()
		fill.polygon = poly
		fill.color = _BiomeColors.color(biome_id).lerp(_CELLGRAPH_CONTEXT_TINT, _CELLGRAPH_CONTEXT_TINT_RATIO)
		context_layer.add_child(fill)
		context_count += 1

	if capped:
		print("RegionMap: cellgraph context cells capped at %d" % _CELLGRAPH_CONTEXT_MAX_CELLS)

	print("RegionMap: cellgraph locale loaded (%d/%d cells in selected province/realm, %d context cells)" %
		[member_ids.size(), all_ids.size(), context_count])
	$LoadingLabel.visible = false


## Brute-force nearest-site search — used once per locale load (before
## _cell_hash exists yet, since that's built from the result of this call),
## so an O(n) scan over all cells is cheap enough not to need a spatial index.
func _nearest_cell(ids: PackedInt64Array, sites: PackedVector2Array, point: Vector2) -> int:
	var best_id := -1
	var best_dist := INF
	for i in range(ids.size()):
		var d := point.distance_squared_to(sites[i])
		if d < best_dist:
			best_dist = d
			best_id = ids[i]
	return best_id


## Radius used to bound the local patch rendered around a click that lands on
## unclaimed wilderness/ocean (realm_id <= 0 has no meaningful group — see
## _bfs_same_province) — sized to roughly one locale-grid cell so the patch
## reads as "the area around here", not the whole contiguous wilderness mass.
## Shared by _resolve_hex_locale_membership() (IRONBAND-062) — the math is
## generic map-size/grid-config arithmetic, not cellgraph-specific.
func _cellgraph_wilderness_radius() -> float:
	return minf(_map_w / maxf(float(_locales_cols), 1.0),
	            _map_h / maxf(float(_locales_rows), 1.0)) * 0.5


## BFS out from `cell_id`, collecting every cell in the same province (or
## realm, for owned-but-provinceless territory) — mirrors
## GlobalMap._rebuild_boundary_highlight's membership walk, since both need
## "everything in this territory" from the same per-cell
## province_id/realm_id/get_location_neighbors data.
##
## realm_id <= 0 is Azgaar's "no owner" sentinel, not a real realm — on the
## cheia map every unclaimed wilderness/ocean cell shares realm_id 0, so
## grouping by realm there would BFS across effectively the whole map (capped
## by _CELLGRAPH_PROVINCE_MAX_CELLS into an arbitrary, adjacency-order-
## dependent chunk rather than a compact area — see GlobalMap's group_key,
## which treats this case as "no group" for the same reason). RegionMap still
## needs to render *something* around the click, so it falls back to a
## radius-bounded BFS instead of a same-realm one.
func _bfs_same_province(cell_id: int, reference_point: Vector2) -> PackedInt64Array:
	var info: Dictionary = _engine.get_location_info(cell_id)
	var province_id: int = int(info.get("province_id", 0)) if not info.is_empty() else 0
	var realm_id: int    = int(info.get("realm_id", 0))    if not info.is_empty() else 0
	var is_wilderness := province_id <= 0 and realm_id <= 0
	var radius := _cellgraph_wilderness_radius()

	var id_to_site := {}
	if is_wilderness:
		var all_ids: PackedInt64Array = _engine.get_cell_ids()
		var all_sites: PackedVector2Array = _engine.get_cell_sites()
		for i in range(all_ids.size()):
			id_to_site[all_ids[i]] = all_sites[i]

	var visited := {cell_id: true}
	var members := PackedInt64Array([cell_id])
	var queue: Array = [cell_id]
	var qi := 0
	while qi < queue.size() and members.size() < _CELLGRAPH_PROVINCE_MAX_CELLS:
		var cur: int = queue[qi]
		qi += 1
		for nb in _engine.get_location_neighbors(cur):
			var nb_id := int(nb)
			if visited.has(nb_id):
				continue
			visited[nb_id] = true
			var same: bool
			if is_wilderness:
				var site: Vector2 = id_to_site.get(nb_id, reference_point)
				same = reference_point.distance_to(site) <= radius
			else:
				var ninfo: Dictionary = _engine.get_location_info(nb_id)
				if ninfo.is_empty():
					continue
				same = (province_id > 0 and int(ninfo.get("province_id", 0)) == province_id) \
					or (province_id <= 0 and int(ninfo.get("realm_id", 0)) == realm_id)
			if same:
				members.push_back(nb_id)
				queue.append(nb_id)
	return members


func _apply_fit_camera() -> void:
	var view_w  := _map_w
	var view_h  := _map_h
	var view_cx := _origin_x + _map_w * 0.5
	var view_cy := _origin_y + _map_h * 0.5
	# _locale_world_rect is set before this runs by whichever membership
	# resolver applies: _resolve_cellgraph_province_membership() (cellgraph)
	# or _resolve_hex_locale_membership() (hex, IRONBAND-062) — both give the
	# selected realm/province's (or wilderness patch's) padded bounding box.
	if _locale_world_rect != Rect2():
		view_w  = _locale_world_rect.size.x
		view_h  = _locale_world_rect.size.y
		view_cx = _locale_world_rect.position.x + view_w * 0.5
		view_cy = _locale_world_rect.position.y + view_h * 0.5

	var vp_size  := get_viewport_rect().size
	var fit_zoom := minf(vp_size.x / maxf(view_w, 1.0), vp_size.y / maxf(view_h, 1.0))
	_fit_zoom = fit_zoom

	# Always show the entire padded locale region, centered — matches both
	# cellgraph provinces and hex-mode realm/province-shaped locales
	# (IRONBAND-062). Zooming toward the click instead of framing the whole
	# region was only right for the old hex-mode fixed-grid-square locales
	# (much larger than a realm/province, so tight click-zoom made sense
	# there); those no longer exist.
	var entry_zoom := fit_zoom
	var cam_x := view_cx
	var cam_y := view_cy

	var vp_half_x  := vp_size.x * 0.5 / entry_zoom
	var vp_half_y  := vp_size.y * 0.5 / entry_zoom
	var lo_x := _locale_world_rect.position.x + vp_half_x
	var hi_x := _locale_world_rect.end.x      - vp_half_x
	var lo_y := _locale_world_rect.position.y + vp_half_y
	var hi_y := _locale_world_rect.end.y      - vp_half_y

	_camera.position = Vector2(
		clampf(cam_x, minf(lo_x, hi_x), maxf(lo_x, hi_x)),
		clampf(cam_y, minf(lo_y, hi_y), maxf(lo_y, hi_y)))
	_camera.zoom     = Vector2(entry_zoom, entry_zoom)
	_clamp_camera_to_locale()
	_dbg("=== RegionMap _apply_fit_camera ===")
	_dbg("  locale_col/row : (%d, %d)" % [_locale_col, _locale_row])
	_dbg("  entry_world    : (%.2f, %.2f)" % [_entry_world.x, _entry_world.y])
	_dbg("  locale_rect    : pos=(%.2f,%.2f)  size=(%.2f,%.2f)" % [
		_locale_world_rect.position.x, _locale_world_rect.position.y,
		_locale_world_rect.size.x, _locale_world_rect.size.y])
	_dbg("  fit_zoom       : %.6f  entry_zoom: %.6f" % [fit_zoom, entry_zoom])
	_dbg("  clamp_x        : lo=%.2f  hi=%.2f  raw=%.2f  -> %.2f" % [lo_x, hi_x, cam_x, _camera.position.x])
	_dbg("  clamp_y        : lo=%.2f  hi=%.2f  raw=%.2f  -> %.2f" % [lo_y, hi_y, cam_y, _camera.position.y])
	_dbg("  camera.pos     : (%.2f, %.2f)  [after clamp]" % [_camera.position.x, _camera.position.y])
	_dbg("  viewport       : (%.0f, %.0f)" % [get_viewport_rect().size.x, get_viewport_rect().size.y])
	_dbg("  map origin     : (%.2f, %.2f)  size: %.2f x %.2f" % [_origin_x, _origin_y, _map_w, _map_h])
	_dbg("  hex_size       : %.4f  tex: %dx%d" % [_hex_size, _tex_w_global, _tex_h_global])
	if _mat:
		_mat.set_shader_parameter("camera_zoom", entry_zoom)
	_update_zoom_label(entry_zoom)


func _load_static_map_preview() -> void:
	var wx_min := _origin_x
	var wx_max := _origin_x + _map_w
	var wy_min := _origin_y
	var wy_max := _origin_y + _map_h

	# _locale_world_rect is already set by _resolve_hex_locale_membership()
	# (IRONBAND-062) — the selected realm/province's (or wilderness patch's)
	# bounding box. Use it directly for the render window instead of
	# recomputing a generic grid square from _locale_col/_locale_row.
	if _locale_world_rect != Rect2():
		wx_min = _locale_world_rect.position.x
		wx_max = _locale_world_rect.end.x
		wy_min = _locale_world_rect.position.y
		wy_max = _locale_world_rect.end.y

	var pad := _hex_size * 2.0
	_dbg("=== _load_static_map_preview ===")
	_dbg("  load bounds    : wx=[%.2f, %.2f]  wy=[%.2f, %.2f]  pad=%.2f" % [wx_min, wx_max, wy_min, wy_max, pad])

	var result := _load_hexbin(HEX_GRID_PATH, wx_min, wx_max, wy_min, wy_max, pad)
	if result.is_empty():
		$LoadingLabel.text = "Error loading map"
		return

	# Don't overwrite _locale_world_rect here: it was set to the true
	# membership bbox above, tighter than the render window's pad — that's
	# what camera clamping and the shader's context-dimming test should use.
	if _locale_world_rect == Rect2():
		_locale_world_rect = Rect2(Vector2(wx_min, wy_min), Vector2(wx_max - wx_min, wy_max - wy_min))

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
	_mat.set_shader_parameter("use_tile_texture", true)
	_mat.set_shader_parameter("tex_grass",  load("res://material/aerial_grass_rock/aerial_grass_rock_diff_2k.png") as Texture2D)
	_mat.set_shader_parameter("tex_forest", load("res://material/forest_ground/forest_ground_04_diff_2k.png")      as Texture2D)
	_mat.set_shader_parameter("tex_rocky",  load("res://material/rocky_terrain/rocky_terrain_02_diff_2k.png")      as Texture2D)
	_mat.set_shader_parameter("tex_snow",   load("res://material/snow/snow_02_diff_2k.png")                        as Texture2D)
	_apply_locale_context_uniforms(_mat)

	_rect.position = Vector2(_origin_x, _origin_y)
	_rect.size     = Vector2(_map_w, _map_h)
	_rect.material = _mat
	_rect.visible  = true

	_mat.set_shader_parameter("camera_zoom", _camera.zoom.x)
	_update_zoom_label(_camera.zoom.x)

	if _marker == null:
		var MarkerScene := preload("res://scenes/shared/PartyMarker.tscn")
		_marker = MarkerScene.instantiate()
		_marker.z_index = 10
		add_child(_marker)
		_marker.setup(_hex_size)
	_marker.visible = false  # hidden until engine reports party position

	_load_routes()
	_load_rivers()
	_load_burg_markers()
	$LoadingLabel.visible = false


## Passes hex-mode locale membership (IRONBAND-062) to the shader so it can
## grey out hexes outside the selected realm/province (or wilderness radius)
## as visual context — the hex-mode counterpart to cellgraph's separate
## greyed-out ContextFills layer (_load_cellgraph_locale). Cellgraph doesn't
## use this at all; it's a no-op there (_is_cellgraph never calls this).
func _apply_locale_context_uniforms(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("locale_context_active", true)
	mat.set_shader_parameter("locale_province_id",    _locale_province_id)
	mat.set_shader_parameter("locale_realm_id",        _locale_realm_id)
	mat.set_shader_parameter("locale_wilderness",      _locale_is_wilderness)
	mat.set_shader_parameter("locale_center",          _locale_center)
	mat.set_shader_parameter("locale_radius",          _locale_radius)


func _load_routes() -> void:
	if _route_layer != null:
		return
	var routes := _RouteLoader.load_file(ROUTES_PATH)
	if routes["roads"].is_empty() and routes["trails"].is_empty() and routes["searoutes"].is_empty():
		return

	_route_layer = Node2D.new()
	_route_layer.name = "RouteLayer"
	_route_layer.z_index = 5
	add_child(_route_layer)

	var filter := _locale_world_rect if _locale_world_rect != Rect2() \
		else Rect2(_origin_x, _origin_y, _map_w, _map_h)
	filter = filter.grow(_hex_size * 4.0)

	_draw_ferry_group(routes["searoutes"], FERRY_COLOR, 0.35, filter, _hex_size * 0.8, _hex_size * 0.8)
	_draw_route_group(routes["trails"],    TRAIL_COLOR, 0.4,  filter, _hex_size * 0.5, _hex_size * 1.5)
	_draw_route_group(routes["roads"],     ROAD_COLOR,  0.45, filter, _hex_size * 1.8, _hex_size * 0.8)


func _load_rivers() -> void:
	if _river_layer != null:
		return
	var rivers := _RiverLoader.load_file(RIVERS_PATH)
	if rivers.is_empty():
		return

	_river_layer = Node2D.new()
	_river_layer.name = "RiverLayer"
	_river_layer.z_index = 3
	add_child(_river_layer)

	var filter := _locale_world_rect if _locale_world_rect != Rect2() \
		else Rect2(_origin_x, _origin_y, _map_w, _map_h)
	filter = filter.grow(_hex_size * 4.0)

	_draw_rivers(rivers, filter)


func _load_burg_markers() -> void:
	if _burg_data == null or _burg_data.is_empty():
		return
	# Regional zoom: all settlement types — far fewer burgs are visible per
	# locale than at global zoom, so no clutter filter is needed here.
	var filtered: Array[BurgLoader.Burg] = []
	for b in _burg_data.all:
		var wp := _hex_to_world(b.hex_q, b.hex_r)
		if _locale_world_rect == Rect2() or _locale_world_rect.has_point(wp):
			filtered.append(b)

	if _burg_layer == null:
		var LayerScript := preload("res://scripts/shared/BurgMarkerLayer.gd")
		_burg_layer = LayerScript.new()
		_burg_layer.z_index = 6  # above routes(5)/rivers(3), below party marker(10)
		add_child(_burg_layer)
		_burg_layer.set_camera(_camera)
		# Regional zoom only: markers grow/shrink mostly in sync with the view
		# zoom (unlike GlobalMap's perfectly flat marker size), so they read
		# as part of the map rather than a fixed screen-space overlay.
		_burg_layer.configure_zoom_scaling(0.85, _camera.zoom.x)

	_burg_layer.build(filtered, Callable(self, "_hex_to_world"), true)


func _draw_rivers(rivers: Array, bounds: Rect2) -> void:
	for rv in rivers:
		var pts: Array[Vector2] = rv["points"]
		if pts.size() < 2:
			continue

		var in_bounds := false
		for pt in pts:
			if bounds.has_point(pt):
				in_bounds = true
				break
		if not in_bounds:
			continue

		# Hex-snap the path.
		var hex_path: Array[Vector2i] = []
		var prev_hex := _world_to_hex(pts[0])
		hex_path.append(prev_hex)
		for i in range(1, pts.size()):
			var cur_hex := _world_to_hex(pts[i])
			if cur_hex == prev_hex:
				continue
			for h in _hex_line(prev_hex, cur_hex).slice(1):
				if hex_path[-1] != h:
					hex_path.append(h)
			prev_hex = cur_hex

		if hex_path.size() < 2:
			continue

		# Truncate at coastline — stop at the first ocean hex (biome_id == 0).
		var world_pts := PackedVector2Array()
		for h in hex_path:
			var c := _sample_hex_pixel(h)
			if c.a < 0.5 or int(c.r * 255.0 + 0.5) == 0:
				break
			world_pts.append(_hex_to_world(h.x, h.y))

		if world_pts.size() < 2:
			continue

		var sw     : float = rv["source_width"]
		var mw     : float = rv["mouth_width"]
		var mouth_px := mw * _hex_size * RIVER_SCALE

		var line := Line2D.new()
		line.default_color  = RIVER_COLOR
		line.width          = mouth_px
		line.begin_cap_mode = Line2D.LINE_CAP_ROUND
		line.end_cap_mode   = Line2D.LINE_CAP_ROUND
		line.points         = world_pts

		if mw > 0.0 and sw < mw:
			var c := Curve.new()
			c.add_point(Vector2(0.0, sw / mw))
			c.add_point(Vector2(1.0, 1.0))
			line.width_curve = c

		_river_layer.add_child(line)


func _draw_route_group(polys: Array, color: Color, width: float, bounds: Rect2,
					   dash: float, gap: float) -> void:
	for poly in polys:
		if poly.size() < 2:
			continue
		var in_bounds := false
		for pt in poly:
			if bounds.has_point(pt):
				in_bounds = true
				break
		if not in_bounds:
			continue
		var hex_path: Array[Vector2i] = []
		var prev_hex := _world_to_hex(poly[0])
		hex_path.append(prev_hex)
		for i in range(1, poly.size()):
			var cur_hex := _world_to_hex(poly[i])
			if cur_hex == prev_hex:
				continue
			for h in _hex_line(prev_hex, cur_hex).slice(1):
				if hex_path[-1] != h:
					hex_path.append(h)
			prev_hex = cur_hex

		const BRIDGE_GAP := 3  # snap-artifact ocean hexes to skip in land routes
		var seg: Array[Vector2] = []
		var i := 0
		while i < hex_path.size():
			var hex := hex_path[i]
			if _get_biome_id(hex) != 0:
				seg.append(_hex_to_world(hex.x, hex.y))
				i += 1
			else:
				var gap_end := i + 1
				while gap_end < hex_path.size() and _get_biome_id(hex_path[gap_end]) == 0:
					gap_end += 1
				if gap_end - i <= BRIDGE_GAP and gap_end < hex_path.size():
					pass  # skip ocean hexes silently; segment continues to next land hex
				else:
					_emit_dashes(seg, color, width, dash, gap)
					seg = []
				i = gap_end
		_emit_dashes(seg, color, width, dash, gap)


func _draw_ferry_group(polys: Array, color: Color, width: float, bounds: Rect2,
					   dash: float, gap: float) -> void:
	for poly in polys:
		if poly.size() < 2:
			continue
		var in_bounds := false
		for pt in poly:
			if bounds.has_point(pt):
				in_bounds = true
				break
		if not in_bounds:
			continue
		var hex_path: Array[Vector2i] = []
		var prev_hex := _world_to_hex(poly[0])
		hex_path.append(prev_hex)
		for i in range(1, poly.size()):
			var cur_hex := _world_to_hex(poly[i])
			if cur_hex == prev_hex:
				continue
			for h in _hex_line(prev_hex, cur_hex).slice(1):
				if hex_path[-1] != h:
					hex_path.append(h)
			prev_hex = cur_hex

		var seg: Array[Vector2] = []
		for hex in hex_path:
			if _get_biome_id(hex) != 0:
				_emit_dashes(seg, color, width, dash, gap)
				seg = []
			else:
				seg.append(_hex_to_world(hex.x, hex.y))
		_emit_dashes(seg, color, width, dash, gap)


func _emit_dashes(pts: Array[Vector2], color: Color, width: float,
				  dash: float, gap: float) -> void:
	if pts.size() < 2:
		return
	var drawing := true
	var phase   := 0.0
	var cur     := PackedVector2Array()

	for i in pts.size() - 1:
		var a      := pts[i]
		var b      := pts[i + 1]
		var remain := a.distance_to(b)
		if remain < 1e-6:
			continue
		var dir := (b - a) / remain
		var pos := a

		while remain > 1e-6:
			var period := dash if drawing else gap
			var step   := minf(period - phase, remain)
			if drawing:
				if cur.is_empty():
					cur.append(pos)
				cur.append(pos + dir * step)
			pos    += dir * step
			remain -= step
			phase  += step
			if phase >= period - 1e-9:
				if drawing and cur.size() >= 2:
					_make_line(cur, color, width)
					cur = PackedVector2Array()
				phase   = 0.0
				drawing = not drawing

	if drawing and cur.size() >= 2:
		_make_line(cur, color, width)


func _make_line(pts: PackedVector2Array, color: Color, width: float) -> void:
	var line := Line2D.new()
	line.default_color  = color
	line.width          = width
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode   = Line2D.LINE_CAP_ROUND
	line.points         = pts
	_route_layer.add_child(line)


static func _hex_line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var n := maxi(1, (abs(a.x - b.x) + abs(a.x + a.y - b.x - b.y) + abs(a.y - b.y)) / 2)
	var result: Array[Vector2i] = []
	for i in n + 1:
		var t := float(i) / float(n)
		result.append(_hex_round(lerpf(a.x, b.x, t), lerpf(a.y, b.y, t)))
	return result


func _process(delta: float) -> void:
	if _marker and _marker.visible:
		_marker.scale = Vector2.ONE / _camera.zoom.x
	# Re-grab focus every frame while console is open — simpler than chasing all the
	# ways Godot's input system can silently steal it from a LineEdit.
	if _console_open and _console_input and not _console_input.has_focus():
		_console_input.grab_focus()
	if _state_dirty:
		_state_dirty_timer -= delta
		if _state_dirty_timer <= 0.0:
			_state_dirty       = false
			_state_dirty_timer = 0.0
			_push_state_sync()


func _notification(_what: int) -> void:
	pass


func _setup_hud() -> void:
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)

	var common := CommonHud.build(hud)
	_hover_label     = common.hover_label
	_sel_panel       = common.sel_panel
	_sel_label       = common.sel_label
	_mp_label        = common.mp_label
	_zoom_label      = common.zoom_label
	_info_panel      = common.info_panel
	_info_type_lbl   = common.info_type_lbl
	_info_name_lbl   = common.info_name_lbl
	_info_detail_lbl = common.info_detail_lbl

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
	# STOP so scroll-wheel events don't leak through to the map zoom handler.
	_console_history.mouse_filter      = Control.MOUSE_FILTER_STOP
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
	# Re-claim focus whenever something steals it while the console is open.
	# Deferred so the current event finishes processing before we re-grab.
	_console_input.focus_exited.connect(func():
		if _console_open:
			_console_input.call_deferred("grab_focus"))
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

	# Local shortcuts that need no AI round-trip.
	if cmd.begins_with("mark ") or cmd == "mark":
		var note := raw.strip_edges().substr(5).strip_edges()
		if note.is_empty():
			_explore_print("[color=#666]Mark what?[/color]")
		else:
			_explore_mark(note)
	else:
		match cmd:
			"look", "l":
				_explore_look()
			"where", "pos":
				if _has_party_pos:
					var hex := _world_to_hex(_party_world_pos)
					_explore_print("[color=#aaa]q=%d  r=%d[/color]" % [hex.x, hex.y])
				else:
					_explore_print("[color=#666]Position unknown.[/color]")
			"inv", "i", "inventory":
				_explore_inventory()
			"map":
				_toggle_explore()
			"help", "?":
				_explore_print("[color=#888]Commands:[/color]")
				_explore_print("[color=#888]  [b]look / l[/b]       describe current hex")
				_explore_print("  [b]inv / i[/b]        show inventory")
				_explore_print("  [b]mark [note][/b]   record something here")
				_explore_print("  [b]where[/b]          show coordinates")
				_explore_print("  [b]map[/b]            close console")
				_explore_print("  Anything else (directions, actions, questions): just say it.[/color]")
			_:
				# Everything else — directions, take/drop, natural language — goes to AI.
				_explore_ai_dispatch(raw.strip_edges())


func _explore_move(dir: Vector2i) -> void:
	if not _has_party_pos:
		_explore_print("[color=#666]You have no position.[/color]")
		return
	_explore_origin_hex = _world_to_hex(_party_world_pos)
	_explore_prev_hex   = _explore_origin_hex
	var dest := _explore_origin_hex + dir
	_move_party_to(_hex_to_world(dest.x, dest.y))


static func _dir_offset(cmd: String) -> Vector2i:
	# Scan each word so natural-language input ("go west", "head ne") works.
	for word in cmd.split(" ", false):
		if   word in ["nw", "northwest"]: return Vector2i( 0, -1)
		elif word in ["ne", "northeast"]: return Vector2i( 1, -1)
		elif word in ["e",  "east"]:      return Vector2i( 1,  0)
		elif word in ["se", "southeast"]: return Vector2i( 0,  1)
		elif word in ["sw", "southwest"]: return Vector2i(-1,  1)
		elif word in ["w",  "west"]:      return Vector2i(-1,  0)
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
		if _pending_event_roll:
			_pending_event_roll = false
			_roll_hex_events(hex)
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
			if _pending_event_roll:
				_pending_event_roll = false
				_roll_hex_events(hex)
			_console_input.grab_focus()


func _prose_cache_store(hex: Vector2i, prose: String) -> void:
	if not _prose_cache.has(hex):
		_prose_cache_keys.append(hex)
		if _prose_cache_keys.size() > PROSE_CACHE_MAX:
			var evict: Vector2i = _prose_cache_keys[0]
			_prose_cache_keys.remove_at(0)
			_prose_cache.erase(evict)
	_prose_cache[hex] = prose
	# Persist the first prose ever generated for this hex as its lore seed.
	if not _hex_lore.has(hex):
		_hex_lore[hex] = prose
		_mark_state_dirty()


func _explore_context(hex: Vector2i, prev_hex: Vector2i = Vector2i(-9999, -9999)) -> String:
	var lines: Array[String] = []
	if prev_hex.x != -9999:
		lines.append("Traveling from: %s" % _biome_name(_get_biome_id(prev_hex)))
	var biome_id := _get_biome_id(hex)
	lines.append("Arriving at: %s" % _biome_name(biome_id))

	# Stable lore seed — prose from the very first visit.
	var lore: String = _hex_lore.get(hex, "")
	if not lore.is_empty():
		lines.append("First impression: " + lore)

	# Accumulated events — encounters, chat exchanges, player marks.
	var events: Array = _hex_events.get(hex, [])
	if not events.is_empty():
		lines.append("Notable at this location:")
		for ev in events:
			lines.append("  - " + str(ev))

	# Visit history — helps narrator acknowledge revisits and continuity.
	var visits: int = _visited_set.get(hex, 0)
	if visits > 1:
		lines.append("Previously visited (%d times)." % visits)
	if _visited_hexes.size() >= 2:
		var recent: Array[String] = []
		var last_b := -1
		for idx in range(_visited_hexes.size() - 1, maxi(-1, _visited_hexes.size() - 8), -1):
			var b := _get_biome_id(_visited_hexes[idx])
			if b != last_b:
				recent.insert(0, _biome_name(b))
				last_b = b
			if recent.size() >= 4:
				break
		if recent.size() > 1:
			lines.append("Recent journey: " + " → ".join(recent))

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
			if t.has_ferry(): feats.append("ferry")
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
			var port_note := "  ⚓ Port" if burg.is_port() else ""
			lines.append("Settlement: %s — %s, pop. %d%s" %
				[burg.name, burg.type_name(), burg.population, port_note])

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


func _explore_ai_dispatch(text: String) -> void:
	var api_key := OS.get_environment("ANTHROPIC_API_KEY")
	if api_key.is_empty():
		# No API: fall back to local parsing for the most common intents.
		var dir := _dir_offset(text.to_lower())
		if dir != Vector2i.ZERO:
			_explore_move(dir)
		else:
			var words := text.to_lower().split(" ", false)
			if words.size() > 0 and words[0] in ["take", "get", "grab", "pick"]:
				_explore_take(" ".join(words.slice(1)))
			elif words.size() > 0 and words[0] in ["drop", "discard"]:
				_explore_drop(" ".join(words.slice(1)))
			else:
				_explore_print("[color=#555]Narrator unavailable. (set ANTHROPIC_API_KEY)[/color]")
		return

	# Build world context prefix for the user message.
	var ctx := ""
	if _has_party_pos:
		var hex := _world_to_hex(_party_world_pos)
		ctx = "[%s] " % _biome_name(_get_biome_id(hex))
		if not _inventory.is_empty():
			ctx += "[Carries: %s] " % ", ".join(_inventory.keys())
		if _ground_items.has(hex) and not (_ground_items[hex] as Array).is_empty():
			ctx += "[On ground: %s] " % ", ".join(_ground_items[hex] as Array)

	# Tools Haiku can call to interact with the game.
	var tools := [
		{"name": "move",
		 "description": "Move the party one hex. Directions: nw ne e se sw w.",
		 "input_schema": {"type": "object",
		   "properties": {"direction": {"type": "string", "enum": ["nw","ne","e","se","sw","w"]}},
		   "required": ["direction"]}},
		{"name": "take",
		 "description": "Pick up an item from the ground at the current location.",
		 "input_schema": {"type": "object",
		   "properties": {"item": {"type": "string"}}, "required": ["item"]}},
		{"name": "drop",
		 "description": "Drop an item from the party inventory.",
		 "input_schema": {"type": "object",
		   "properties": {"item": {"type": "string"}}, "required": ["item"]}},
		{"name": "look",
		 "description": "Describe the current hex.",
		 "input_schema": {"type": "object", "properties": {}}},
		{"name": "inventory",
		 "description": "List carried items.",
		 "input_schema": {"type": "object", "properties": {}}},
	]

	# Don't modify _chat_history yet — only commit once we know the response type.
	var messages: Array = _chat_history.duplicate()
	messages.append({"role": "user", "content": ctx + text})

	var body := JSON.stringify({
		"model":      "claude-haiku-4-5-20251001",
		"max_tokens": 200,
		"tools":      tools,
		"system":     "You are the narrator and game interface for a hex-based fantasy RPG. Use the provided tools when the player intends a game action (movement, taking/dropping items, looking around, checking inventory). For banter, questions, or roleplay use text only — 1-3 terse sentences. No meta-language. Directions: nw ne e se sw w (hex grid, no pure north/south). If the player performs a lasting physical action, append [MEMORY: brief third-person summary] to your text response.",
		"messages":   messages
	})

	var http := HTTPRequest.new()
	http.timeout = 15.0
	add_child(http)
	http.request_completed.connect(
		func(result, code, _hdrs, resp_body):
			_on_dispatch_response(result, code, resp_body, text, ctx, http))

	var err := http.request(
		"https://api.anthropic.com/v1/messages",
		["Content-Type: application/json",
		 "x-api-key: " + api_key,
		 "anthropic-version: 2023-06-01"],
		HTTPClient.METHOD_POST, body)

	if err != OK:
		http.queue_free()
		_explore_print("[color=#555]Could not reach narrator.[/color]")


func _on_dispatch_response(result: int, code: int, body: PackedByteArray,
                           user_text: String, ctx: String,
                           http: HTTPRequest) -> void:
	http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_explore_print("[color=#555]Narrator unavailable.[/color]")
		return

	var parsed := JSON.new()
	if parsed.parse(body.get_string_from_utf8()) != OK or not (parsed.data is Dictionary):
		return

	var data:    Dictionary = parsed.data
	var content: Array      = data.get("content", [])
	var got_text := false

	for block in content:
		if not (block is Dictionary):
			continue
		var b := block as Dictionary
		match b.get("type", ""):
			"text":
				var reply := str(b.get("text", "")).strip_edges()
				if reply.is_empty():
					continue
				# Extract [MEMORY: ...] tag — only save lasting physical actions.
				var memory := ""
				var ts := reply.find("[MEMORY:")
				if ts >= 0:
					var te := reply.find("]", ts)
					if te > ts:
						memory = reply.substr(ts + 8, te - ts - 8).strip_edges()
						reply  = reply.substr(0, ts).strip_edges()
				if not reply.is_empty():
					_explore_print("[color=#b0c8e0]%s[/color]" % reply)
					_explore_print("")
					# Commit this exchange to chat history only for text responses,
					# so tool-only turns don't leave dangling user messages.
					if not got_text:
						got_text = true
						_chat_history.append({"role": "user",      "content": ctx + user_text})
						_chat_history.append({"role": "assistant", "content": reply})
						while _chat_history.size() > CHAT_HISTORY_MAX * 2:
							_chat_history.remove_at(0)
				if not memory.is_empty() and _has_party_pos:
					_add_hex_event(_world_to_hex(_party_world_pos), memory)
					_mark_state_dirty()
			"tool_use":
				_execute_tool(b.get("name", ""), b.get("input", {}) as Dictionary)


func _execute_tool(tool_name: String, input: Dictionary) -> void:
	match tool_name:
		"move":
			var dir := _dir_offset(input.get("direction", ""))
			if dir != Vector2i.ZERO:
				_explore_move(dir)
		"take":
			var item := str(input.get("item", "")).strip_edges()
			if not item.is_empty():
				_explore_take(item)
		"drop":
			var item := str(input.get("item", "")).strip_edges()
			if not item.is_empty():
				_explore_drop(item)
		"look":
			_explore_look()
		"inventory":
			_explore_inventory()


func _record_visit(hex: Vector2i) -> void:
	if not _visited_set.has(hex):
		_visited_hexes.append(hex)
		if _visited_hexes.size() > VISITED_MAX:
			var evict: Vector2i = _visited_hexes[0]
			_visited_hexes.remove_at(0)
			_visited_set.erase(evict)
	_visited_set[hex] = _visited_set.get(hex, 0) + 1
	_mark_state_dirty()


func _explore_inventory() -> void:
	if _inventory.is_empty():
		_explore_print("[color=#888]You carry nothing.[/color]")
		return
	_explore_print("[color=#c8b870][b]Inventory[/b][/color]")
	for item: String in _inventory:
		var qty: int = _inventory[item]
		if qty > 1:
			_explore_print("  %s  [color=#555]×%d[/color]" % [item, qty])
		else:
			_explore_print("  %s" % item)
	_explore_print("")


func _explore_take(item: String) -> void:
	var key := item.to_lower()
	_inventory[key] = _inventory.get(key, 0) + 1
	# Remove from ground if it was a discovered item
	if _has_party_pos:
		var hex := _world_to_hex(_party_world_pos)
		if _ground_items.has(hex):
			(_ground_items[hex] as Array).erase(key)
	_mark_state_dirty()
	_explore_fetch_take_flavor(item)


func _explore_mark(note: String) -> void:
	if not _has_party_pos:
		_explore_print("[color=#666]You have no position to mark.[/color]")
		return
	var hex := _world_to_hex(_party_world_pos)
	_add_hex_event(hex, note)
	_prose_cache.erase(hex)  # bust cache so next look regenerates with the new note
	_explore_print("[color=#a8a870]Noted.[/color]")
	_mark_state_dirty()


func _add_hex_event(hex: Vector2i, text: String) -> void:
	if not _hex_events.has(hex):
		_hex_events[hex] = []
	var evs := _hex_events[hex] as Array
	evs.append(text)
	if evs.size() > HEX_EVENTS_MAX:
		evs.remove_at(0)
	# Bust prose cache so next movement-look regenerates with updated context.
	_prose_cache.erase(hex)


func _explore_drop(item: String) -> void:
	var key := item.to_lower()
	if not _inventory.has(key):
		_explore_print("[color=#666]You are not carrying %s.[/color]" % item)
		return
	_inventory[key] -= 1
	if _inventory[key] <= 0:
		_inventory.erase(key)
	_mark_state_dirty()
	_explore_print("[color=#888]Dropped.[/color]")


func _explore_fetch_take_flavor(item: String) -> void:
	var api_key := OS.get_environment("ANTHROPIC_API_KEY")
	if api_key.is_empty():
		_explore_print("[color=#a8c870]You take the %s.[/color]" % item)
		return
	var loc := ""
	if _has_party_pos:
		loc = " Location: %s." % _biome_name(_get_biome_id(_world_to_hex(_party_world_pos)))
	var prompt := "Player picks up: %s.%s One sentence, present tense, second person." % [item, loc]
	var body := JSON.stringify({
		"model":      "claude-haiku-4-5-20251001",
		"max_tokens": 60,
		"system":     "Terse atmospheric narrator for a fantasy game. One sentence only.",
		"messages":   [{"role": "user", "content": prompt}]
	})
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(func(result, code, _hdrs, resp_body):
		_on_take_response(result, code, resp_body, item, http))
	var err := http.request(
		"https://api.anthropic.com/v1/messages",
		["Content-Type: application/json",
		 "x-api-key: " + api_key,
		 "anthropic-version: 2023-06-01"],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		_explore_print("[color=#a8c870]You take the %s.[/color]" % item)


func _on_take_response(result: int, code: int, body: PackedByteArray,
                       item: String, http: HTTPRequest) -> void:
	http.queue_free()
	var reply := ""
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var parsed := JSON.new()
		if parsed.parse(body.get_string_from_utf8()) == OK and parsed.data is Dictionary:
			var data: Dictionary = parsed.data
			var content: Array = data.get("content", [])
			if content.size() > 0 and content[0] is Dictionary:
				reply = str((content[0] as Dictionary).get("text", ""))
	if reply.is_empty():
		reply = "You take the %s." % item
	_explore_print("[color=#a8c870]%s[/color]" % reply)
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


# ── Events (items & encounters) ───────────────────────────────────────────────

func _roll_hex_events(hex: Vector2i) -> void:
	var visits: int = _visited_set.get(hex, 0)
	# Item drops: first visit only, one roll per hex
	if visits == 1 and not _ground_items.has(hex):
		if randf() < ITEM_CHANCE:
			_generate_item_discovery(hex)
	elif _ground_items.has(hex) and not (_ground_items[hex] as Array).is_empty():
		# Remind player items are still on the ground
		_explore_print("[color=#8ab870]On the ground: %s[/color]" % \
			", ".join(_ground_items[hex] as Array))
		_explore_print("[color=#555](take [item] to pick up)[/color]\n")
	# Encounters: full chance first visit, half on revisits
	var enc_roll := ENCOUNTER_CHANCE if visits <= 1 else ENCOUNTER_CHANCE * 0.5
	if randf() < enc_roll:
		_generate_encounter(hex)


func _generate_item_discovery(hex: Vector2i) -> void:
	var items := _biome_items(_get_biome_id(hex))
	if items.is_empty():
		return
	var item: String = items[randi() % items.size()]
	_ground_items[hex] = [item]
	_mark_state_dirty()

	var api_key := OS.get_environment("ANTHROPIC_API_KEY")
	if api_key.is_empty():
		_explore_print("[color=#8ab870]You notice %s on the ground.[/color]" % item)
		_explore_print("[color=#555](take %s)[/color]\n" % item)
		_console_input.grab_focus()
		return

	var biome := _biome_name(_get_biome_id(hex))
	var prompt := "A traveler spots a %s in a %s. One sentence noticing it. Second person." % [item, biome]
	var body := JSON.stringify({
		"model":      "claude-haiku-4-5-20251001",
		"max_tokens": 60,
		"system":     "Terse atmospheric narrator for a fantasy game. One sentence only.",
		"messages":   [{"role": "user", "content": prompt}]
	})
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(func(result, code, _hdrs, resp_body):
		_on_item_discovery_response(result, code, resp_body, item, http))
	var err := http.request(
		"https://api.anthropic.com/v1/messages",
		["Content-Type: application/json",
		 "x-api-key: " + api_key,
		 "anthropic-version: 2023-06-01"],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		_explore_print("[color=#8ab870]You notice %s on the ground.[/color]" % item)
		_explore_print("[color=#555](take %s)[/color]\n" % item)
		_console_input.grab_focus()


func _on_item_discovery_response(result: int, code: int, body: PackedByteArray,
                                  item: String, http: HTTPRequest) -> void:
	http.queue_free()
	var reply := ""
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var parsed := JSON.new()
		if parsed.parse(body.get_string_from_utf8()) == OK and parsed.data is Dictionary:
			var data: Dictionary = parsed.data
			var content: Array = data.get("content", [])
			if content.size() > 0 and content[0] is Dictionary:
				reply = str((content[0] as Dictionary).get("text", ""))
	if reply.is_empty():
		reply = "You notice %s on the ground." % item
	_explore_print("[color=#8ab870]%s[/color]" % reply)
	_explore_print("[color=#555](take %s)[/color]\n" % item)
	if _console_open:
		_console_input.grab_focus()


func _generate_encounter(hex: Vector2i) -> void:
	var api_key := OS.get_environment("ANTHROPIC_API_KEY")
	var biome_id := _get_biome_id(hex)
	if api_key.is_empty():
		_explore_print("[color=#9070c0]%s[/color]\n" % _encounter_fallback(biome_id))
		_console_input.grab_focus()
		return

	var ctx := _explore_context(hex)
	var prompt := "Location:\n%s\n\nGenerate a brief non-combat encounter (wandering NPC, discovery, wonder, or weather). 1-2 sentences. Second person. End with a natural interactive hook." % ctx
	var body := JSON.stringify({
		"model":      "claude-haiku-4-5-20251001",
		"max_tokens": 120,
		"system":     "Fantasy RPG narrator. Generate atmospheric non-combat encounters: travelers, ruins, weather, animals, mysteries. No monsters. Vivid and concise.",
		"messages":   [{"role": "user", "content": prompt}]
	})
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(func(result, code, _hdrs, resp_body):
		_on_encounter_response(result, code, resp_body, http))
	var err := http.request(
		"https://api.anthropic.com/v1/messages",
		["Content-Type: application/json",
		 "x-api-key: " + api_key,
		 "anthropic-version: 2023-06-01"],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		_explore_print("[color=#9070c0]%s[/color]\n" % _encounter_fallback(biome_id))
		_console_input.grab_focus()


func _on_encounter_response(result: int, code: int, body: PackedByteArray,
                             http: HTTPRequest) -> void:
	http.queue_free()
	var reply := ""
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var parsed := JSON.new()
		if parsed.parse(body.get_string_from_utf8()) == OK and parsed.data is Dictionary:
			var data: Dictionary = parsed.data
			var content: Array = data.get("content", [])
			if content.size() > 0 and content[0] is Dictionary:
				reply = str((content[0] as Dictionary).get("text", ""))
	if reply.is_empty():
		return
	# Save encounter so revisits and future sessions can reference it.
	if _has_party_pos:
		var hex := _world_to_hex(_party_world_pos)
		_add_hex_event(hex, reply)
		_mark_state_dirty()
	_explore_print("[color=#9070c0]%s[/color]\n" % reply)
	if _console_open:
		_console_input.grab_focus()


static func _biome_items(biome_id: int) -> Array[String]:
	match biome_id:
		0:  return ["waterlogged chest", "fisherman's net", "driftwood carving", "sea-glass bottle"]
		1:  return ["sun-bleached skull", "broken compass", "cracked waterskin", "carved bone token"]
		2:  return ["frozen coin pouch", "shattered lantern", "wolf-tooth necklace", "map fragment"]
		3:  return ["iron arrowhead", "leather satchel", "carved walking stick", "dried herb bundle"]
		4:  return ["clay pipe", "shepherd's crook", "rolled wool blanket", "copper ring"]
		5:  return ["poison dart", "carved wooden mask", "exotic feather", "vine rope coil"]
		6:  return ["rusted hunting knife", "old flask", "forester's axe head", "rabbit snare"]
		7:  return ["pine resin torch", "bear claw", "hunter's journal", "steel trap"]
		8:  return ["reed flute", "reed basket", "mussel shell charm", "iron fishing hook"]
		9:  return ["bone needle", "frost-cracked ring", "leather pouch", "antler carving"]
		10: return ["frozen gauntlet", "ice-pick handle", "carved ice totem", "frozen gold coin"]
		11: return ["cloak pin", "rune stone", "buried boot", "crystallized amber"]
		12: return ["mangrove carving", "crab trap", "salt-crusted trinket", "woven reed hat"]
	return ["old coin", "leather strip", "worn button", "cracked flint"]


static func _encounter_fallback(biome_id: int) -> String:
	match biome_id:
		0:  return "A fishing boat drifts past, the crew watching you from a cautious distance."
		1:  return "A lone merchant hunkers by a dead fire, his camel loaded with wrapped goods."
		2:  return "A hooded figure crosses the horizon without acknowledging you."
		3:  return "A herd of antelopes passes within arrow range, indifferent to your presence."
		4:  return "A shepherd waves from a distant hill, then turns back to his flock."
		5:  return "Something large shifts in the canopy above — watching, then gone."
		6:  return "Smoke curls between the trees ahead. Someone camped here very recently."
		7:  return "Wolf tracks circle the clearing. They are fresh."
		8:  return "A flat-bottomed boat is beached in the reeds, oars still inside."
		9:  return "A cairn of stacked stones marks a grave. No name. No date."
		10: return "A figure in white furs stands motionless on the ice ahead."
		11: return "Tracks in the fresh snow lead in a slow circle, then stop."
		12: return "A child's wooden toy bobs past in the brackish water."
	return "A crow lands nearby and regards you with unsettling intelligence."


# ── State persistence ─────────────────────────────────────────────────────────

func _on_player_state_received(data: Dictionary) -> void:
	# Inventory: supports both {qty, type, condition} objects and bare ints.
	var inv = data.get("inventory", {})
	if inv is Dictionary:
		for key in inv:
			var entry = inv[key]
			if entry is Dictionary:
				_inventory[str(key)] = int((entry as Dictionary).get("qty", 1))
			elif entry is float or entry is int:
				_inventory[str(key)] = int(entry)

	# Ground items: keys are "q,r" strings.
	var ground = data.get("ground_items", {})
	if ground is Dictionary:
		for hex_str in ground:
			var parts := (hex_str as String).split(",")
			if parts.size() == 2:
				var hex := Vector2i(int(parts[0]), int(parts[1]))
				var items = ground[hex_str]
				if items is Array:
					_ground_items[hex] = items

	# Hex lore (first-visit prose seed).
	var loremap = data.get("hex_lore", {})
	if loremap is Dictionary:
		for hex_str in loremap:
			var parts := (hex_str as String).split(",")
			if parts.size() == 2:
				var hex := Vector2i(int(parts[0]), int(parts[1]))
				_hex_lore[hex] = str(loremap[hex_str])

	# Hex events (encounters + chat + player marks).
	var evmap = data.get("hex_events", {})
	if evmap is Dictionary:
		for hex_str in evmap:
			var parts := (hex_str as String).split(",")
			if parts.size() == 2:
				var hex := Vector2i(int(parts[0]), int(parts[1]))
				var evs = evmap[hex_str]
				if evs is Array:
					_hex_events[hex] = evs

	# Visited hexes: [{q, r, count}, ...].
	var visited = data.get("visited_hexes", [])
	if visited is Array:
		for entry in visited:
			if entry is Dictionary:
				var d := entry as Dictionary
				var hex   := Vector2i(int(d.get("q", 0)), int(d.get("r", 0)))
				var count := int(d.get("count", 1))
				if not _visited_set.has(hex):
					_visited_hexes.append(hex)
				_visited_set[hex] = count

	print("[RegionMap] State restored: %d items, %d hexes, %d ground stashes, %d event hexes" % [
		_inventory.size(), _visited_hexes.size(), _ground_items.size(), _hex_events.size()])


func _mark_state_dirty() -> void:
	_state_dirty       = true
	_state_dirty_timer = STATE_DEBOUNCE_SEC


func _push_state_sync() -> void:
	pass  # state sync via IronbandEngine signals, not Protohack


func _serialize_player_state() -> Dictionary:
	var inv_data := {}
	for key in _inventory:
		inv_data[key] = {"qty": _inventory[key], "type": "trinket", "condition": "worn"}

	var ground_data := {}
	for hex in _ground_items:
		var items: Array = _ground_items[hex]
		if not items.is_empty():
			ground_data["%d,%d" % [(hex as Vector2i).x, (hex as Vector2i).y]] = items

	var events_data := {}
	for hex in _hex_events:
		var evs: Array = _hex_events[hex]
		if not evs.is_empty():
			events_data["%d,%d" % [(hex as Vector2i).x, (hex as Vector2i).y]] = evs

	var lore_data := {}
	for hex in _hex_lore:
		lore_data["%d,%d" % [(hex as Vector2i).x, (hex as Vector2i).y]] = _hex_lore[hex]

	var visited_data: Array = []
	for hex in _visited_hexes:
		visited_data.append({
			"q":     (hex as Vector2i).x,
			"r":     (hex as Vector2i).y,
			"count": _visited_set.get(hex, 1),
		})

	return {
		"schema_version":  1,
		"inventory":       inv_data,
		"ground_items":    ground_data,
		"hex_events":      events_data,
		"hex_lore":        lore_data,
		"visited_hexes":   visited_data,
		"npcs":            {},
		"quests":          [],
		"journal":         [],
		"journal_summary": "",
		"chat_summary":    "",
	}


func _restore_fog_from_visits() -> void:
	for hex in _visited_hexes:
		_reveal_fog((hex as Vector2i).x, (hex as Vector2i).y, _region_fog_rad)


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
	_mat.set_shader_parameter("use_tile_texture", true)
	_mat.set_shader_parameter("tex_grass",  load("res://material/aerial_grass_rock/aerial_grass_rock_diff_2k.png") as Texture2D)
	_mat.set_shader_parameter("tex_forest", load("res://material/forest_ground/forest_ground_04_diff_2k.png")      as Texture2D)
	_mat.set_shader_parameter("tex_rocky",  load("res://material/rocky_terrain/rocky_terrain_02_diff_2k.png")      as Texture2D)
	_mat.set_shader_parameter("tex_snow",   load("res://material/snow/snow_02_diff_2k.png")                        as Texture2D)

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
		var MarkerScene := preload("res://scenes/shared/PartyMarker.tscn")
		_marker = MarkerScene.instantiate()
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
	if _marker:
		_marker.place_at(party_wpos)  # marker always at party hex
		_marker.visible = true
	if _enter_btn:
		_enter_btn.visible = true
		_update_sel_panel("Party", "q=%d  r=%d" % [q, r])
	_restore_fog_from_visits()


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

	var hxb_version  := hdr.decode_u16(4)
	var biome_cnt    := hdr.decode_u16(6)
	var hex_count    := hdr.decode_u32(8)
	var strtab_size  := hdr.decode_u32(12)
	var realm_cnt    := hdr.decode_u16(16)
	var province_cnt := hdr.decode_u16(18)
	var burg_cnt     := hdr.decode_u16(20)
	var hex_rec_size := 11 if hxb_version >= 2 else 10

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
	var recs := f.get_buffer(hex_count * hex_rec_size)
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
		var base     := i * hex_rec_size
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
				_camera.begin_drag(mb.position)
			else:
				if _camera.end_drag():
					var world_pos := get_viewport().get_canvas_transform().affine_inverse() * mb.position
					if _is_cellgraph:
						_select_cellgraph_cell(world_pos)
					else:
						_select_hex(_world_to_hex(world_pos))
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			GameState.go_global()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			if not _console_open:
				_zoom_toward_marker(1.15)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if not _console_open:
				_zoom_toward_marker(1.0 / 1.15)

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _camera.is_dragging():
			_camera.drag_to(mm.position, mm.relative)
			_clamp_camera_to_locale()
		_update_hover(mm.position)

	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			if k.keycode == KEY_X and _has_party_pos:
				_camera.position = _party_world_pos
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
	_info_locked = false  # reset so _build_hex_info can call _show_info
	_mat.set_shader_parameter("selection_mode", 0)
	_mat.set_shader_parameter("selected_q", hex.x)
	_mat.set_shader_parameter("selected_r", hex.y)
	_selected_hex = hex
	_update_sel_panel("Hex", "q=%d  r=%d" % [hex.x, hex.y])
	_build_hex_info(hex)
	_info_locked = true


## Cell-graph counterpart to _select_hex: locks the info panel on the
## clicked cell instead of whatever's currently hovered.
func _select_cellgraph_cell(world_pos: Vector2) -> void:
	if _cell_hash == null:
		return
	var id := _cell_hash.nearest(world_pos)
	if id == -1:
		return
	_info_locked = false  # reset so _show_cellgraph_info can call _show_info
	_hovered_cell_id = id
	_show_cellgraph_info(id, _world_to_hex(world_pos))
	_info_locked = true


func _move_party_to(world_pos: Vector2) -> void:
	var hex := _world_to_hex(world_pos)
	if _mat:
		_mat.set_shader_parameter("selection_mode", 0)
		_mat.set_shader_parameter("selected_q", hex.x)
		_mat.set_shader_parameter("selected_r", hex.y)
	_selected_hex = hex
	_pending_move_dest = hex
	_update_sel_panel("→", "q=%d  r=%d" % [hex.x, hex.y])


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


func _burg_at(hex: Vector2i) -> BurgLoader.Burg:
	if _burg_data == null or _burg_data.is_empty():
		return null
	return _burg_data.by_hex.get(hex, null)


func _show_info(type: String, display_name: String, detail: String) -> void:
	if _info_panel == null:
		return
	_info_type_lbl.text = type.to_upper()
	_info_name_lbl.text = display_name
	_info_detail_lbl.text = detail
	_info_detail_lbl.visible = not detail.is_empty()
	_info_panel.visible = true


## Cell-graph counterpart to _build_hex_info — mirrors
## GlobalMap._show_cellgraph_info exactly (same get_location_info fields),
## since RegionMap's cellgraph mode had never wired hover/click info at all.
func _show_cellgraph_info(id: int, hex: Vector2i = Vector2i(-9999, -9999)) -> bool:
	var info: Dictionary = _engine.get_location_info(id)
	if info.is_empty():
		return false
	var biome_id: int = info.get("biome_id", 0)
	var is_water: bool = info.get("is_water", false)
	var realm_name: String = info.get("realm_name", "")
	var province_name: String = info.get("province_name", "")
	var elevation: int = info.get("elevation", 0)

	var detail := "Cell: %d\nElevation: %d" % [id, elevation]
	if not realm_name.is_empty():    detail += "\nRealm: "    + realm_name
	if not province_name.is_empty(): detail += "\nProvince: " + province_name

	var type_label := "Ocean" if is_water else _biome_name(biome_id)
	var name_label := province_name if not province_name.is_empty() else \
		(realm_name if not realm_name.is_empty() else "Wilderness")

	var burg := _burg_at(hex)
	if burg != null:
		var port_note := "  ⚓ Port" if burg.is_port() else ""
		detail += "\nSettlement: %s, pop. %d%s" % [burg.name, burg.population, port_note]
		type_label = burg.type_name()
		name_label = burg.name

	_show_info(type_label, name_label, detail)
	return true


func _build_hex_info(hex: Vector2i) -> void:
	var c := _sample_hex_pixel(hex)
	if c.a < 0.5:
		return
	var biome_id    := int(c.r * 255.0 + 0.5)
	var realm_id    := int(c.g * 255.0 + 0.5)
	var province_id := _sample_province_id(hex)

	var type_str: String = _biome_name(biome_id)
	var name_str: String = ""
	var detail_parts: Array[String] = []

	if province_id > 0:
		name_str = _province_names.get(province_id, "Unknown Province")
		var capital: String = _province_capitals.get(province_id, "")
		if not capital.is_empty():
			detail_parts.append("Capital: " + capital)
	elif realm_id > 0:
		name_str = _realm_names.get(realm_id, "Unknown Realm")
	else:
		name_str = type_str
		type_str = "Wilderness"

	if realm_id > 0:
		var rname: String = _realm_names.get(realm_id, "")
		detail_parts.append("Realm: " + rname)

	if _terrain_data and not _terrain_data.is_empty():
		var t := _terrain_data.get_hex(hex.x, hex.y)
		if t != null:
			var features: Array[String] = []
			if t.has_river():               features.append("river")
			if t.route_flags & 0x3F:        features.append("road")
			elif t.route_flags >> 6 & 0x3F: features.append("trail")
			if t.has_ferry():               features.append("ferry")
			if t.is_harbor():               features.append("harbor")
			if not features.is_empty():
				detail_parts.append("Features: " + ", ".join(features))

	var flavor: String = _biome_flavor(biome_id)
	if not flavor.is_empty():
		detail_parts.append("")
		detail_parts.append(flavor)

	var visits: int = _visited_set.get(hex, 0)
	if visits > 0:
		detail_parts.append("")
		detail_parts.append("Visited %d time%s" % [visits, "s" if visits != 1 else ""])

	var lore: String = _hex_lore.get(hex, "")
	if not lore.is_empty():
		detail_parts.append("")
		detail_parts.append(lore)

	var burg := _burg_at(hex)
	if burg != null:
		var port_note := "  ⚓ Port" if burg.is_port() else ""
		detail_parts.append("Settlement: %s, pop. %d%s" % [burg.name, burg.population, port_note])
		type_str = burg.type_name()
		name_str = burg.name

	_show_info(type_str, name_str, "\n".join(detail_parts))


## Cell-graph counterpart to _update_hover — mirrors
## GlobalMap._update_hover_cellgraph, since RegionMap builds a _cell_hash for
## its province's cells at load time but had never queried it for hover info.
func _update_hover_cellgraph(screen_pos: Vector2) -> void:
	var world_pos := get_viewport().get_canvas_transform().affine_inverse() * screen_pos
	var text := "  [%.0f, %.0f]" % [world_pos.x, world_pos.y]
	_hover_label.visible = true
	_hover_label.text = text
	_hover_label.position = screen_pos + Vector2(14, -22)

	if _cell_hash == null:
		return
	var id := _cell_hash.nearest(world_pos)
	if id == -1:
		return
	if id == _hovered_cell_id:
		return  # no change, skip rebuilding the info every frame
	_hovered_cell_id = id
	if not _info_locked:
		_show_cellgraph_info(id, _world_to_hex(world_pos))


func _update_hover(screen_pos: Vector2) -> void:
	if _is_cellgraph:
		_update_hover_cellgraph(screen_pos)
		return
	if _mat == null:
		_hover_label.visible = false
		return
	var world_pos := get_viewport().get_canvas_transform().affine_inverse() * screen_pos
	var hex  := _world_to_hex(world_pos)

	# Tooltip: raw debug coords
	var text := "hex=(%d, %d)  world=(%.1f, %.1f)" % [hex.x, hex.y, world_pos.x, world_pos.y]
	_hover_label.visible = true
	_hover_label.text = text
	_hover_label.position = screen_pos + Vector2(14, -22)

	if _info_locked:
		return

	_build_hex_info(hex)


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
	var new_zoom := clampf(old_zoom * factor, _fit_zoom, 50.0)
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
	# When lo >= hi the locale fits (or exactly fills) the viewport on that axis —
	# snap to the midpoint so there is never empty space past the locale edge.
	_camera.position.x = clamp(_camera.position.x, minf(lo.x, hi.x), maxf(lo.x, hi.x))
	_camera.position.y = clamp(_camera.position.y, minf(lo.y, hi.y), maxf(lo.y, hi.y))


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


func _dbg(msg: String) -> void:
	var f := FileAccess.open(DEBUG_LOG, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(DEBUG_LOG, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(msg)
	f.close()
