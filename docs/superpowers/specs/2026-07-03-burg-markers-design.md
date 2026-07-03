# Burg Markers — Settlement Icons with Port Indicator

**Date:** 2026-07-03
**Status:** Approved for planning — spec only, no implementation done yet.
**Relates to:** [2026-07-02-freeform-worldmap-design.md](2026-07-02-freeform-worldmap-design.md) (cell-graph
rendering, merged) — this spec is unrelated in mechanism but reuses that work's testing-strategy convention
(headless `SceneTree` smoke scripts; no automated visual-rendering checks exist in this repo).

## Summary

`burgs.bin` (settlement data — name, population, type, port/capital/walls flags, hex position) is loaded today by
`RegionMap.gd` but only used for click-to-inspect text; `GlobalMap.gd` doesn't load it at all. No burg ever renders
as a visible marker on either map. Real icon art now exists (`assets/{village,town,city,harbor}.png`) and this spec
covers rendering it: settlement markers with size/type hierarchy and a port indicator, at both global and regional
zoom, with click-to-inspect wired to show settlement info on both maps.

## Goals

1. Render a marker for every burg at regional zoom, and for cities/naval/capitals at global zoom (avoiding clutter
   from ~1800 burgs at world-overview scale).
2. Distinguish settlement type (village/town/city/capital/naval) and port status visually, using the provided art.
3. Clicking a burg's hex shows its name/type/population/port status in the existing info panel, on both maps.
4. Markers stay a constant, readable screen size regardless of camera zoom (matching `PartyMarker`'s existing
   convention), not shrinking to unreadable specks at global zoom or ballooning at regional zoom.

## Non-Goals

- **Cell-graph worlds** (`cheia`, the dev/test path from the freeform-worldmap work). `burgs.bin` is keyed by hex
  `q`/`r`; there is no cell-compatible burg loader or data. The live game world (`ancient`) is hex-format, so this
  is not a practical gap today — explicitly deferred, matching how cell-mode routes/rivers were scoped out of the
  prior subsystem's Task 4.
- **The broader marker/POI system** (dungeons, lighthouses, inns, sea monsters, etc. — 153 markers tracked
  separately in IRONBAND-012). That system has open gameplay-design questions (discovery/visibility rules,
  encounter-generation hooks) that are a separate design pass, not a rendering-only concern like this spec.
- **New art.** This spec uses the four icons already provided as-is; no new commissioned assets.

## Icon Mapping

Four source icons exist: `village.png`, `town.png`, `city.png` (settlement silhouettes, one per size tier) and
`harbor.png` (a symbolic anchor-and-waves badge, visually distinct in style from the other three — not a
settlement silhouette).

`BurgLoader.Burg.type` (0=village, 1=town, 2=city, 3=naval, 4=capital) and `.flags` (bit 1 = `is_port()`) combine
to select a marker's visual as follows:

| type | base icon | notes |
|---|---|---|
| 0 village | `village.png` | |
| 1 town | `town.png` | |
| 2 city | `city.png` | |
| 3 naval | `harbor.png` | no dedicated art; `harbor.png` is thematically closest and stylistically reads as a distinct badge/symbol rather than a settlement, which fits "naval base" better than reusing a city silhouette |
| 4 capital | `city.png` | no dedicated capital art; capitals are the largest settlements anyway, so city art is a reasonable stand-in |

Additionally, independent of type: a small **capital accent** (procedural gold star, no art asset — corner badge)
is drawn on top of the base icon when `type == 4`, and a small **port badge** (`harbor.png`, scaled down, opposite
corner) is drawn on top of the base icon when `is_port()` is true **and** `type != 3` (naval burgs already show
`harbor.png` as their full base icon — no double-badging).

This mapping is this spec's resolved judgment call, not directly confirmed against original intent for the art —
flagged here in case it needs revisiting once markers are visible in the editor.

## Architecture

**New file:** `scripts/shared/BurgMarkerLayer.gd` (`class_name BurgMarkerLayer`, `extends Node2D`) — a reusable
rendering component in the same location and spirit as `CellSpatialHash.gd` and `PartyMarker.gd`: small, single-
purpose, usable from both `GlobalMap.gd` and `RegionMap.gd` without either scene knowing the other exists.

**Public interface:**
- `build(burgs: Array[BurgLoader.Burg], hex_to_world: Callable) -> void` — clears any existing markers, then
  creates one marker node per burg in the input array, positioned via the caller-supplied `hex_to_world(q, r)`
  callable (both `GlobalMap._hex_to_world` and `RegionMap._hex_to_world` already exist with compatible
  signatures). The layer does **not** know about zoom tiers, locale windows, or type filtering — callers pass an
  already-filtered list. This keeps the component's contract answerable at a glance: it draws exactly the burgs
  you hand it, nowhere else, nothing hidden.
- Standard `_process(delta)` override: counter-scales every marker child by `Vector2.ONE / camera_zoom.x` each
  frame, mirroring `PartyMarker.move_to`'s existing per-frame scale convention. Needs a `Camera2D` reference —
  passed once via a `set_camera(cam: Camera2D)` call before first use, not re-passed per frame.

**Per-marker node:** a small `Node2D` wrapper (not a heavier custom class) containing:
- a base `Sprite2D` using the mapped texture (see Icon Mapping), local `scale` set once at creation so the
  village/town/city/capital size hierarchy is visible at camera zoom = 1 (exact pixel constants are an
  implementation-time tuning detail, not a spec requirement — village smallest, city/capital largest, town
  between, naval similar to town)
- an optional badge `Sprite2D` (small `harbor.png`, corner-anchored) when applicable
- an optional accent `Polygon2D` star (small, gold) when `type == 4`

No `MultiMeshInstance2D` or other batching — burg counts per frame are modest (global zoom: a few hundred
city/naval/capital burgs out of ~1800; regional zoom: whatever's in one locale window, far fewer). Plain child
nodes match the codebase's existing scale (`PartyMarker` is a single node; nothing here currently uses
`MultiMesh`), and keeps the component simple to read.

## Zoom-Tier Filtering (caller-side)

Filtering lives in `GlobalMap.gd`/`RegionMap.gd`, not in `BurgMarkerLayer` — each caller already knows its own
zoom/locale state and existing filtering conventions (e.g. `RegionMap`'s locale-window filtering from the prior
subsystem's Task 7).

- **Global zoom:** filter to `type in {2, 3, 4}` (city, naval, capital) — an explicit set membership check, not a
  numeric `type >= 2` comparison. `naval` (3) sits numerically between `town` (1) and `capital` (4) but isn't a
  "bigger settlement" — a threshold check would wrongly exclude it.
- **Regional zoom:** all burgs (any type) whose hex falls within the currently-loaded locale window. No type
  filter — far fewer burgs are in view per locale, so clutter isn't a concern the way it is at global zoom.

## Click → Info Panel

- **`RegionMap.gd`** already resolves burg-at-hex on click (`_burg_data.by_hex.get(hex, null)`, existing code
  around line 1103-1106) and appends `"Settlement: %s (pop. %d)"` to the info text. Extend that line to also
  include `burg.type_name()` and a port indicator (e.g. append `"  ⚓ Port"` when `is_port()`).
- **`GlobalMap.gd`** loads no burg data today — new gap to close. Add a `BurgLoader.load_file(BURGS_PATH)` call
  during world load (same pattern `RegionMap` already uses; `BURGS_PATH` needs adding as a constant alongside the
  existing `HEX_GRID_PATH`/`ROUTES_PATH`/etc.). In the existing hex-click resolution path (`_select_by_zoom` →
  the code that currently calls `_show_info("province", ...)` / `_show_info("realm", ...)`), look up the clicked
  hex in the new burg data; if a burg is present, show settlement info instead, taking priority over
  province/realm text (matching the principle that the most specific information available should win — a
  hex with a named settlement is more informative than its containing province).

## Error Handling / Logging

- Missing/unloadable icon textures: `push_error` with the specific path, fall back to no base sprite (marker node
  still exists at the correct position with just badge/accent if applicable) rather than crashing the scene load —
  matches this codebase's existing pattern of graceful degradation on load failures (`GlobalMap.gd`'s
  `$LoadingLabel.text = "Error: ..."` branches).
- Burgs with `hex_q`/`hex_r` outside the currently-loaded terrain bounds (shouldn't happen with correct data, but
  cheap to guard): skip silently, don't crash `hex_to_world`.

## Testing Strategy

Following this repo's established convention (confirmed in the prior subsystem's plan: no GUT/gdUnit addon, only
headless `SceneTree` smoke scripts under `scenes/smoke/`, run via `godot --headless --script`):

- **New: `scenes/smoke/BurgMarkerSmoke.gd`** — loads `burgs.bin` for the real `ancient` world via `BurgLoader`,
  asserts the burg count matches the current data (1847, per the just-merged data refresh). Exercises the
  icon-selection logic as a pure function (`BurgMarkerLayer` should expose icon/badge/accent selection as a
  static or otherwise unit-testable method, not buried inline in `build()`) against synthetic `BurgLoader.Burg`
  fixtures covering all five type values crossed with port/non-port, asserting the expected base-icon/badge/accent
  combination for each.
- **Manual/visual** (no automation exists for this in the repo, stated explicitly rather than overclaimed
  coverage): marker appearance, size hierarchy, badge/accent positioning, and click-to-inspect behavior on both
  maps — verified in the Godot editor once implemented.

## Open Questions

- Exact pixel-size constants for the village/town/city/capital hierarchy and badge/accent sizing are left as an
  implementation-time tuning detail (Architecture section already scopes the intent: readable hierarchy, small
  corner badges) — not blocking spec approval.
- The Icon Mapping section's judgment calls (naval → `harbor.png` as full base icon; capital → `city.png` + star
  accent) are this spec's resolved decision, not independently confirmed — flagged for a quick look once markers
  are visible in the editor, in case the mapping should change.

## Verification Findings (post-implementation)

**2026-07-03:**

- **Implementation complete:** all three tasks (`BurgMarkerLayer.gd`, `GlobalMap.gd` integration, `RegionMap.gd`
  integration) implemented via subagent-driven development, each independently task-reviewed and approved with no
  Critical/Important findings. See `docs/superpowers/plans/2026-07-03-burg-markers-plan.md` and
  `.superpowers/sdd/progress.md` for the full task-by-task record.
- **Confirmed working:** the project boots cleanly with no load errors in a fresh process (checked via headless
  run, twice — once before and once after an icon-asset fix, see below). Global-zoom markers render.
- **Source-art issue found and partially fixed during verification:** the originally-cut `village.png`/`town.png`/
  `city.png`/`harbor.png` had the checkerboard "this is transparent" placeholder pattern baked in as fully-opaque
  pixels (confirmed via alpha-channel inspection: min/max both 255 across the whole image) rather than real alpha
  transparency — an artifact of how the source sheet was cut. User re-exported `village.png`/`town.png`/`city.png`
  with real alpha (confirmed: alpha now ranges 0-255) and confirmed they now render correctly in a fresh Godot
  process. **`harbor.png` was not yet re-exported** — it's still fully opaque (alpha 255/255) as of this writing.
  This affects the naval base icon and the port badge on other types; **not yet fixed**.
- **Gotcha for future icon-asset updates:** `BurgMarkerLayer.gd` caches loaded textures in `static var`s
  (`_ensure_textures_loaded()`'s `_textures_loaded` guard), which persist for the lifetime of the running game
  process. Replacing a `.png` on disk while a Play session is still running will NOT pick up the change — the
  process must be fully stopped and restarted. This is a real (if minor) rough edge worth knowing about, not
  something this spec's scope covers fixing (e.g. a file-watcher or cache-bust mechanism would be over-engineering
  for a dev-only asset-iteration convenience).
- **User feedback on art quality:** "the art sucks, but that's not an issue really. perhaps emojis would be
  awesomer for now." Not treated as blocking — tracked as a follow-up (IRONBAND-053 in memex): swap
  `Sprite2D`-based icons for `Label`-node emoji glyphs. Confirmed low-risk as a future change: `BurgMarkerLayer.gd`
  is the sole place icon rendering happens (via `marker_spec_for()`/`build()`), so this can be redone without
  touching `GlobalMap.gd` or `RegionMap.gd` at all — validates this spec's Architecture goal of keeping the
  rendering strategy isolated from its callers.
- **Still open (not independently confirmed by the user as of this writing, though covered by task review's
  code-level verification):** regional-zoom rendering of all burg types (not just city/capital/naval), the port
  badge's visual placement, the capital gold-star accent's visual placement, and the extended click-to-inspect
  text on both maps. Task-level code review confirmed these are implemented correctly against the spec (see the
  plan's task reviews), but a human hasn't yet visually confirmed them in the editor. Whoever picks this back up
  should do a full pass once `harbor.png` is fixed, covering the complete Task 4 checklist from the plan.
