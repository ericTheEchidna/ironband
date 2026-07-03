# Burg Markers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render settlement markers (village/town/city/capital/naval, with a port badge) on both `GlobalMap.gd` and
`RegionMap.gd`, using the new icon art in `assets/`, with click-to-inspect wired to show settlement info.

**Architecture:** One new shared component, `scripts/shared/BurgMarkerLayer.gd`, instantiated by both map scenes.
It exposes a pure, unit-testable icon-selection function (`marker_spec_for`) and a `build()` method that draws
whatever burg list its caller hands it — the layer itself does no filtering or zoom-tier logic. Both scenes already
load `burgs.bin` via the existing `BurgLoader` (`RegionMap.gd` already does; `GlobalMap.gd` needs it added) and
already have a `_hex_to_world(q, r) -> Vector2` helper the layer reuses.

**Tech Stack:** GDScript, Godot 4.6. No engine (C++/GDExtension) changes — this is a pure frontend rendering
feature.

## Global Constraints

- Icons load via `Image.load_from_file(ProjectSettings.globalize_path(path))` + `ImageTexture.create_from_image()`,
  **not** `preload()`/`load()` on the raw `.png` — the new asset files have no `.import` metadata yet (Godot
  generates that on editor scan), and `preload()` on an un-imported resource fails. This exact pattern is already
  used in this codebase for `cell_terrain.png` (`GlobalMap.gd`'s `_load_cellgraph_texture`) for the same reason.
- Cell-graph worlds (`_is_cellgraph == true` / `_ready_cellgraph()` / `_select_cellgraph()` paths) are untouched —
  out of scope per the spec's Non-Goals.
- No new shared coordinate/hex-math module: `GlobalMap.gd` and `RegionMap.gd` each keep their own
  `_hex_to_world()` — this repo already accepts that duplication (see the freeform-worldmap spec's File Structure
  note) and this plan doesn't change that.
- Testing convention: headless `SceneTree` smoke scripts under `scenes/smoke/`, run via
  `/home/eric/bin/Godot_v4.6.2-stable_linux.x86_64 --headless --script <path>`. No GUT/gdUnit addon exists in this
  repo.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.
- Godot binary: **`godot` is NOT on `PATH`** in this environment — use the full path
  `/home/eric/bin/Godot_v4.6.2-stable_linux.x86_64` for every headless invocation (confirmed via baseline check
  before implementation started; `which godot` fails, the binary only resolves at this exact path).

---

## File Structure

- **Create:** `scripts/shared/BurgMarkerLayer.gd` — the marker rendering component.
- **Create:** `scenes/smoke/BurgMarkerSmoke.gd` — headless test for icon-selection logic + real burg-count sanity.
- **Modify:** `scripts/global/GlobalMap.gd` — add `BURGS_PATH` const, `_burg_data`/`_burg_layer` vars, load burgs,
  build markers, extend `_select_hex` to show settlement info.
- **Modify:** `scripts/regional/RegionMap.gd` — add `_burg_layer` var, build markers (locale-filtered), extend
  `_build_hex_info`'s existing burg text.

---

### Task 1: `BurgMarkerLayer.gd` — icon selection logic + rendering component

**Files:**
- Create: `scripts/shared/BurgMarkerLayer.gd`
- Create: `scenes/smoke/BurgMarkerSmoke.gd`

**Interfaces:**
- Produces: `class_name BurgMarkerLayer extends Node2D` with:
  - `static func marker_spec_for(burg: BurgLoader.Burg) -> Dictionary` — pure function, returns
    `{"base": String, "base_scale": float, "badge": bool, "accent": bool}`. `base` is one of
    `"village"|"town"|"city"|"harbor"`.
  - `func set_camera(cam: Camera2D) -> void` — must be called once before `build()`.
  - `func build(burgs: Array[BurgLoader.Burg], hex_to_world: Callable) -> void` — clears any existing markers,
    creates one per burg in the input array, positioned via `hex_to_world.call(burg.hex_q, burg.hex_r)`.
- Consumes: `BurgLoader.Burg` (existing, `scripts/loaders/BurgLoader.gd` — `type: int`, `flags: int`, `hex_q: int`,
  `hex_r: int`, `is_port() -> bool`).

- [ ] **Step 1: Write the failing smoke test**

Create `scenes/smoke/BurgMarkerSmoke.gd`:

```gdscript
extends SceneTree

const BurgMarkerLayer = preload("res://scripts/shared/BurgMarkerLayer.gd")

func _initialize() -> void:
	var failures := 0

	# type/flags -> expected {base, badge, accent} coverage.
	var cases := [
		{"type": 0, "flags": 0, "want_base": "village", "want_badge": false, "want_accent": false},
		{"type": 0, "flags": 2, "want_base": "village", "want_badge": true,  "want_accent": false},
		{"type": 1, "flags": 0, "want_base": "town",    "want_badge": false, "want_accent": false},
		{"type": 1, "flags": 2, "want_base": "town",    "want_badge": true,  "want_accent": false},
		{"type": 2, "flags": 0, "want_base": "city",    "want_badge": false, "want_accent": false},
		{"type": 2, "flags": 2, "want_base": "city",    "want_badge": true,  "want_accent": false},
		{"type": 3, "flags": 0, "want_base": "harbor",  "want_badge": false, "want_accent": false},
		{"type": 3, "flags": 2, "want_base": "harbor",  "want_badge": false, "want_accent": false},
		{"type": 4, "flags": 0, "want_base": "city",    "want_badge": false, "want_accent": true},
		{"type": 4, "flags": 2, "want_base": "city",    "want_badge": true,  "want_accent": true},
	]
	for c in cases:
		var b := BurgLoader.Burg.new()
		b.type  = c["type"]
		b.flags = c["flags"]
		var spec := BurgMarkerLayer.marker_spec_for(b)
		if spec["base"] != c["want_base"] or spec["badge"] != c["want_badge"] or spec["accent"] != c["want_accent"]:
			push_error("SMOKE FAIL: type=%d flags=%d -> %s, want base=%s badge=%s accent=%s" %
				[c["type"], c["flags"], str(spec), c["want_base"], c["want_badge"], c["want_accent"]])
			failures += 1

	var burgs := BurgLoader.load_file("/home/eric/source/ironband/worlds/ancient/burgs.bin")
	if burgs.all.size() != 1847:
		push_error("SMOKE FAIL: ancient burgs.bin count = %d, want 1847" % burgs.all.size())
		failures += 1

	if failures == 0:
		print("SMOKE PASS: marker_spec_for() covers all type/flag combinations, ancient burg count correct")
		quit(0)
	else:
		push_error("SMOKE FAIL: %d failures" % failures)
		quit(1)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/eric/source/ironband && /home/eric/bin/Godot_v4.6.2-stable_linux.x86_64 --headless --script scenes/smoke/BurgMarkerSmoke.gd`
Expected: parse/load error — `scripts/shared/BurgMarkerLayer.gd` does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `scripts/shared/BurgMarkerLayer.gd`:

```gdscript
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
const ACCENT_COLOR  := Color(1.0, 0.85, 0.2, 1.0)

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


func build(burgs: Array[BurgLoader.Burg], hex_to_world: Callable) -> void:
	_ensure_textures_loaded()
	for m in _markers:
		m.queue_free()
	_markers.clear()

	for burg in burgs:
		var spec: Dictionary = marker_spec_for(burg)
		var marker := Node2D.new()
		marker.position = hex_to_world.call(burg.hex_q, burg.hex_r)

		var base_tex: ImageTexture = _texture_for(spec["base"])
		var base_scale: float = spec["base_scale"]
		if base_tex != null:
			var sprite := Sprite2D.new()
			sprite.texture = base_tex
			sprite.scale = Vector2.ONE * base_scale
			marker.add_child(sprite)

		if spec["badge"] and _harbor_tex != null:
			var badge := Sprite2D.new()
			badge.texture = _harbor_tex
			badge.scale = Vector2.ONE * BADGE_SCALE
			badge.position = _corner_offset(base_tex, base_scale, 1)
			marker.add_child(badge)

		if spec["accent"]:
			var star := _make_star()
			star.position = _corner_offset(base_tex, base_scale, -1)
			marker.add_child(star)

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


static func _texture_for(name: String) -> ImageTexture:
	match name:
		"village": return _village_tex
		"town":    return _town_tex
		"city":    return _city_tex
		"harbor":  return _harbor_tex
	return null


## sign = 1 -> bottom-right corner (badge), sign = -1 -> top-left corner (accent).
static func _corner_offset(base_tex: ImageTexture, base_scale: float, sign: int) -> Vector2:
	if base_tex == null:
		return Vector2.ZERO
	return Vector2(base_tex.get_width(), base_tex.get_height()) * base_scale * 0.35 * float(sign)


static func _make_star() -> Polygon2D:
	var pts := PackedVector2Array()
	for i in 10:
		var r := ACCENT_RADIUS if i % 2 == 0 else ACCENT_RADIUS * 0.45
		var ang := deg_to_rad(-90 + i * 36)
		pts.append(Vector2(cos(ang), sin(ang)) * r)
	var poly := Polygon2D.new()
	poly.polygon = pts
	poly.color = ACCENT_COLOR
	return poly
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/eric/source/ironband && /home/eric/bin/Godot_v4.6.2-stable_linux.x86_64 --headless --script scenes/smoke/BurgMarkerSmoke.gd`
Expected: `SMOKE PASS: marker_spec_for() covers all type/flag combinations, ancient burg count correct`, exit 0.

If the burg-count assertion fails with a different number, re-check `worlds/ancient/burgs.bin` is the file merged
in the `fix/ancient-world-data-refresh` PR (1847 burgs) — not a stale copy.

- [ ] **Step 5: Commit**

```bash
cd /home/eric/source/ironband
git add scripts/shared/BurgMarkerLayer.gd scenes/smoke/BurgMarkerSmoke.gd
git commit -m "$(cat <<'EOF'
feat(frontend): BurgMarkerLayer — settlement icon rendering component

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `GlobalMap.gd` — load burgs, render filtered markers, click-to-inspect

**Files:**
- Modify: `scripts/global/GlobalMap.gd`

**Interfaces:**
- Consumes: `BurgMarkerLayer.set_camera(cam)`, `BurgMarkerLayer.build(burgs, hex_to_world)` (Task 1).
  `BurgLoader.load_file(path) -> BurgLoader.BurgData` (existing, `scripts/loaders/BurgLoader.gd`).
- Produces: clicking a hex with a settlement now shows its name/type/population/port status in the info panel,
  taking priority over the existing "Hex q=.. r=.." text at that zoom tier.

- [ ] **Step 1: Add the `BURGS_PATH` constant and burg-related fields**

In `scripts/global/GlobalMap.gd`, near the existing path constants (after line 13, `const RIVERS_PATH`):

```gdscript
const BURGS_PATH             := WORLD_DIR + "/burgs.bin"
```

Near the other `var _route_layer: Node2D = null` / `var _river_layer: Node2D = null` declarations (around line
87-88):

```gdscript
var _burg_data:  BurgLoader.BurgData = null
var _burg_layer: BurgMarkerLayer     = null
```

- [ ] **Step 2: Load burg data and build markers in `_load_and_render`**

In `_load_and_render()` (the hex-world path, not `_load_and_render_cellgraph`), find `_load_locales()` (around
line 248) and add the burg load right after it:

```gdscript
	_load_locales()

	_burg_data = BurgLoader.load_file(BURGS_PATH)
```

Then find the two `call_deferred` lines near the end of `_load_and_render()` (around line 302-303):

```gdscript
	call_deferred("_load_routes")
	call_deferred("_load_rivers")
```

Add a third:

```gdscript
	call_deferred("_load_routes")
	call_deferred("_load_rivers")
	call_deferred("_load_burg_markers")
```

- [ ] **Step 3: Implement `_load_burg_markers`**

Add this new function anywhere near `_load_rivers()`:

```gdscript
func _load_burg_markers() -> void:
	if _burg_data == null or _burg_data.is_empty():
		return
	# Global zoom: city/naval/capital only — ~1800 burgs would clutter the
	# world overview otherwise. Village/town appear at regional zoom instead.
	var visible_types := [2, 3, 4]
	var filtered: Array[BurgLoader.Burg] = []
	for b in _burg_data.all:
		if b.type in visible_types:
			filtered.append(b)

	if _burg_layer == null:
		var LayerScript := preload("res://scripts/shared/BurgMarkerLayer.gd")
		_burg_layer = LayerScript.new()
		_burg_layer.z_index = 6  # above routes(5)/rivers(3), below party marker(10)
		add_child(_burg_layer)
		_burg_layer.set_camera(_camera)

	_burg_layer.build(filtered, Callable(self, "_hex_to_world"))
```

- [ ] **Step 4: Extend `_select_hex` to show settlement info**

Find `_select_hex(hex: Vector2i)` (around line 877):

```gdscript
func _select_hex(hex: Vector2i) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selection_mode", 0)
	_mat.set_shader_parameter("selected_q", hex.x)
	_mat.set_shader_parameter("selected_r", hex.y)
	hex_selected.emit(hex.x, hex.y)
	_update_sel_panel("Hex", "q=%d  r=%d" % [hex.x, hex.y])
	_engine.move_party(PackedVector2Array([Vector2(hex.x, hex.y)]))
	_engine.set_time_scale(1.0)
```

Add a call to a new helper at the end:

```gdscript
func _select_hex(hex: Vector2i) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("selection_mode", 0)
	_mat.set_shader_parameter("selected_q", hex.x)
	_mat.set_shader_parameter("selected_r", hex.y)
	hex_selected.emit(hex.x, hex.y)
	_update_sel_panel("Hex", "q=%d  r=%d" % [hex.x, hex.y])
	_engine.move_party(PackedVector2Array([Vector2(hex.x, hex.y)]))
	_engine.set_time_scale(1.0)
	_show_burg_info_if_present(hex)


func _show_burg_info_if_present(hex: Vector2i) -> bool:
	if _burg_data == null or _burg_data.is_empty():
		return false
	var burg: BurgLoader.Burg = _burg_data.by_hex.get(hex, null)
	if burg == null:
		return false
	var detail := "%s · pop %d" % [burg.type_name(), int(burg.population)]
	if burg.is_port():
		detail += "  ⚓ Port"
	_show_info("Settlement", burg.name, detail)
	return true
```

- [ ] **Step 5: Manual verification**

Open the project in Godot 4.6, run the main scene (loads `ancient` by default). Confirm:
- City/capital/naval settlement icons appear scattered across the world map, sized larger than a single hex.
- Zooming in/out keeps marker size visually constant (not shrinking/growing with the map).
- Clicking directly on/near a city or capital shows "SETTLEMENT" / the burg's name / type + population + port
  status (if applicable) in the info panel, instead of the plain "Hex q=.. r=.." text.
- No console errors on load (check via `mcp__godot__get_debug_output` if driving through the Godot MCP tools, or
  the editor's own Output panel).

- [ ] **Step 6: Commit**

```bash
cd /home/eric/source/ironband
git add scripts/global/GlobalMap.gd
git commit -m "$(cat <<'EOF'
feat(frontend): GlobalMap renders city/naval/capital burg markers

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `RegionMap.gd` — render all-type markers filtered to the locale, extend info text

**Files:**
- Modify: `scripts/regional/RegionMap.gd`

**Interfaces:**
- Consumes: `BurgMarkerLayer` (Task 1). `RegionMap.gd` already has `_burg_data: BurgLoader.BurgData` (loaded at
  line 200) and `_locale_world_rect: Rect2` (set in `_load_static_map_preview`, line 375).
- Produces: all burg types (village through capital) render within the current locale; the existing hex-click
  info panel's `"Settlement: ..."` line (line 1103-1106) gains type name + port status.

- [ ] **Step 1: Add the `_burg_layer` field**

Near the existing `var _burg_data: BurgLoader.BurgData = null` declaration (around line 146):

```gdscript
var _burg_layer: BurgMarkerLayer = null
```

- [ ] **Step 2: Build markers after routes/rivers load**

In `_load_static_map_preview()` (around line 353-428), find the end of the function:

```gdscript
	_load_routes()
	_load_rivers()
	$LoadingLabel.visible = false
```

Add a call right after `_load_rivers()`:

```gdscript
	_load_routes()
	_load_rivers()
	_load_burg_markers()
	$LoadingLabel.visible = false
```

- [ ] **Step 3: Implement `_load_burg_markers`**

Add this new function near `_load_rivers()`:

```gdscript
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

	_burg_layer.build(filtered, Callable(self, "_hex_to_world"))
```

- [ ] **Step 4: Extend the existing settlement info text**

Find the burg block in `_build_hex_info` (around line 1103-1106):

```gdscript
	if _burg_data and not _burg_data.is_empty():
		var burg: BurgLoader.Burg = _burg_data.by_hex.get(hex, null)
		if burg != null:
			lines.append("Settlement: %s (pop. %d)" % [burg.name, burg.population])
```

Replace with:

```gdscript
	if _burg_data and not _burg_data.is_empty():
		var burg: BurgLoader.Burg = _burg_data.by_hex.get(hex, null)
		if burg != null:
			var port_note := "  ⚓ Port" if burg.is_port() else ""
			lines.append("Settlement: %s — %s, pop. %d%s" %
				[burg.name, burg.type_name(), burg.population, port_note])
```

- [ ] **Step 5: Manual verification**

Enter a locale in the Godot editor (double-click a region on the global map, or however the existing dev flow
enters regional zoom). Confirm:
- Village/town/city/capital/naval markers appear for settlements in the current locale, with a visible size
  hierarchy.
- Port settlements show the small harbor badge; capitals show the gold star accent.
- Clicking a settlement's hex shows the extended text (type name + port status) in the info panel.
- No console errors on load or on entering the locale.

- [ ] **Step 6: Commit**

```bash
cd /home/eric/source/ironband
git add scripts/regional/RegionMap.gd
git commit -m "$(cat <<'EOF'
feat(frontend): RegionMap renders all burg types, extends settlement info text

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Verification notes

**Files:** none created — manual verification, documented in a follow-up note appended to the spec (matching
the prior subsystem's Task 8 convention: `docs/superpowers/specs/2026-07-03-burg-markers-design.md`, not a new
doc).

**Interfaces:** none new.

- [ ] **Step 1: Confirm both maps together**

With Tasks 2 and 3 both merged, run through: global map view (confirm city/capital/naval markers, click one),
double-click into a locale that contains at least one village or town (confirm all types render, click one).
Also spot-check a locale with zero burgs (confirm no errors, just no markers).

- [ ] **Step 2: Record findings**

Add a `## Verification Findings (post-implementation)` section to the bottom of
`docs/superpowers/specs/2026-07-03-burg-markers-design.md`, noting: whether the icon-mapping judgment calls (naval
→ harbor.png as base icon, capital → city.png + star accent) read well in practice, and whether the base-icon
size constants (`VILLAGE_SCALE`/`TOWN_SCALE`/`CITY_SCALE`/`NAVAL_SCALE`/`BADGE_SCALE` in `BurgMarkerLayer.gd`)
need retuning. This is evidence-gathering, not a pass/fail gate — the Open Questions section already flagged
these as worth a look once markers are visible.

- [ ] **Step 3: Commit**

```bash
cd /home/eric/source/ironband
git add docs/superpowers/specs/2026-07-03-burg-markers-design.md
git commit -m "$(cat <<'EOF'
docs: record burg-marker verification findings

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** Goal 1 (render markers at both zoom tiers) → Tasks 2, 3. Goal 2 (type/port visual
  distinction) → Task 1's `marker_spec_for`. Goal 3 (click shows settlement info) → Task 2 Step 4, Task 3 Step 4.
  Goal 4 (constant screen size) → Task 1's `_process` counter-scale. Icon Mapping section → Task 1's `match`
  statement, exactly as tabulated in the spec. Zoom-Tier Filtering → Task 2 Step 3 (explicit `{2,3,4}` set, not a
  `>=` comparison — matches the spec's explicit warning about `naval`'s numeric position) and Task 3 Step 3
  (locale-rect filter, no type filter). Click → Info Panel → Task 2 Step 4, Task 3 Step 4. Error Handling →
  `_load_tex`'s `push_error` + `null` fallback (Task 1). Testing Strategy → Task 1's smoke test covers both the
  pure icon-selection logic and the real burg count; manual/visual verification → Task 4.
- **Non-Goals respected:** no changes to `_ready_cellgraph()`/`_select_cellgraph()` in either file; no work on the
  IRONBAND-012 marker/POI system; no new art created.
- **Placeholder scan:** none — every step has complete, real code.
- **Type consistency check:** `BurgMarkerLayer.build(burgs: Array[BurgLoader.Burg], hex_to_world: Callable)` used
  identically in both Task 2 Step 3 and Task 3 Step 3. `marker_spec_for(burg: BurgLoader.Burg) -> Dictionary` used
  identically in Task 1's smoke test and implementation. `_hex_to_world(q: int, r: int) -> Vector2` signature
  matches both `GlobalMap.gd`'s and `RegionMap.gd`'s existing implementations exactly (confirmed by reading both
  before writing this plan) — the `Callable(self, "_hex_to_world")` pattern works identically in both callers.
