# Ironband Freeform World-Map Design — Native-Cell Graph vs. Hex Grid

**Date:** 2026-07-02
**Status:** Draft — spec only, no implementation planned yet. Rendering at Scale and `move_cost` normalization are
now resolved (see those sections). Not yet implementation-ready: the hex-retirement criterion still needs sign-off
(see Open Questions).
**Relates to:** [2026-06-24-world-map-engine-design.md](2026-06-24-world-map-engine-design.md) (approved) — this doc
resolves that spec's open question: *"Hex coordinate convention carried from `ibp-engine` — confirm axial vs offset
and reuse the existing loader logic in C++."*

**Coordinate convention (resolved):** `ibp-engine`'s existing `WorldHex`/`WorldPathfinder` (`include/World.h:8`,
`src/WorldPathfinder.cpp:25,73-75`) already use **axial** coordinates — `hex_distance()` implements the standard
axial-cube distance formula, and neighbor traversal uses the canonical 6-offset `DQ`/`DR` axial deltas, not an
offset (odd-r/even-r) scheme. `WorldMap`'s hex backing keeps this convention unchanged; there is no remaining
ambiguity to carry into `IronbandEngine`. (Note: `addons/hex_strategy_map/hex_grid.gd`, an unrelated frontend
subsystem for local tactical display, does use offset coordinates — that's a separate, tactical-scale concern
untouched by this spec; see Non-Goals.)

## Summary

Azgaar's Fantasy Map Generator produces a Voronoi diagram of irregular cells. Ironband's current pipeline
(`ibp-engine/tools/azgaar_to_hex.py`) rasterizes that into a uniform hex grid before anything downstream — rendering,
terrain, pathfinding — ever sees it. This rasterization is a deliberate trade (hexes give O(1) neighbor lookups and a
closed-form pixel↔coordinate mapping) but it's also the direct cause of several bugs already fixed in this repo
(hex-native coastal re-check, `river_id` handling, rasterized routes) — each one is a case of information that was
correct on Azgaar's native cells becoming ambiguous or wrong once resampled onto a coarser, differently-shaped grid.

Research into other Azgaar-derived projects (`AzgaarToCK3`, `AzgaarFMGtoCK3`) shows a viable alternative: keep
Azgaar's own cells as the graph, with a hierarchy built on top (cell → county-like group → duchy-like group), the
same pattern Crusader Kings 3 and Europa Universalis 4 use for their own province maps. Those games prove a rigid
grid isn't required for deterministic adjacency, pathfinding, or AI — a graph over irregular regions works fine.

This spec designs a **native-cell graph** representation as an alternative to the hex grid, evaluates it against the
hex approach, and defines how the two could coexist during evaluation — targeting the not-yet-built `IronbandEngine`
(GDExtension) described in the 2026-06-24 spec, since that engine's `WorldMap` subsystem has not fixed its
coordinate convention yet.

## Goals

1. **Resolve the open coordinate-convention question** in the approved world-map-engine spec before `WorldMap` is
   implemented. (Resolved above: hex backing stays axial, matching `ibp-engine`'s existing implementation.)
2. **Eliminate the class of bugs** caused by re-discretizing Azgaar's native cell data onto a hex grid (coastal
   flags, river continuity, route rasterization) by keeping cell-derived data at its native resolution where
   possible.
3. **Enable irregular, CK3/EU4-style province geography** (variable-size regions, natural-feeling adjacency) instead
   of uniform hex movement costs, without requiring a rigid grid.
4. **Keep the decision reversible and low-risk**: prove out the cell-graph approach without breaking the existing hex
   pipeline or committing `WorldMap`'s public shape to it prematurely.

## Non-Goals

- Implementing `IronbandEngine`, `WorldMap`, or any C++ GDExtension code (this is a design spec only; see Status).
- A tactical/combat-scale grid system (out of scope; if a future tactical layer wants a grid, it can rasterize from
  the cell graph independently — not addressed here).
- Redesigning Azgaar's own generation process — this spec is entirely about what happens to Azgaar's *output*.
- Deciding whether hex or cell-graph ships as the *only* format long-term. This spec produces both as parallel
  options and defers that call until they can be compared in a running `WorldMap`.

## Background: What Other Azgaar-Derived Projects Do

GitHub search across all Azgaar-related repositories turned up two Crusader Kings 3 converters (`niefia/AzgaarFMGtoCK3`,
`pryvyd9/AzgaarToCK3`) and one Europa Universalis 4 converter (`Uvenam/AzgaarToEU4`) — both CK3 and EU4 use irregular
polygon provinces, not a grid. `pryvyd9/AzgaarToCK3`'s documented approach:

- **Barony = 1 Azgaar cell** (no re-discretization — the cell *is* the atomic unit)
- **County = ~4 adjacent cells** sharing state identity; **Duchy** = counties; **Kingdom** = duchies of dominant
  culture; **Empire** = kingdoms of dominant religion
- Adjacency computed via BFS over Azgaar's own cell neighbor graph
- Still rasterizes to a bitmap at the very end, because CK3's own file format requires a `provinces.png` — but that
  rasterization happens once, at the boundary with a specific consumer, not upstream of the whole pipeline

Documented pain points from that project mirror bugs already seen in this repo: single-cell provinces need special
handling (too small for a locator), detached fragments need reassignment to a neighbor, biome→terrain mapping is
genuinely hard, and rivers were dropped entirely (unsolved in that project — Ironband already has a `river_id` fix
for the hex path that this design must account for on the cell-graph path too).

**Implication for this design:** keep Azgaar's own cells as the graph's nodes, build a hierarchy on top for
province/realm-scale grouping (mirroring Ironband's existing GlobalMap/RegionMap split), and only rasterize to a
grid at a specific consumer boundary (rendering) if and when one actually needs it — not upstream of everything.

## Architecture

Targets the not-yet-built `IronbandEngine` (in-process C++ GDExtension autoload) from the approved
2026-06-24 spec. `IronbandEngine`'s `WorldMap` subsystem gains support for two backing world-data representations,
selected per-world by a format marker, both implementing one shared adjacency interface:

- **World-gen (tooling)**: `azgaar_to_hex.py` (existing) and a new `azgaar_to_cellgraph.py` both consume the same
  Azgaar JSON export and each produce a loadable world-data file — `hex_grid.hexbin` (existing) or a new
  `cell_graph.bin`. `azgaar_to_cellgraph.py` skips rasterization entirely: it emits cell site points, polygon border
  vertices, and a neighbor adjacency list derived directly from Azgaar's own Voronoi topology (the same relationship
  `AzgaarToCK3`'s `BFS.py` exploits).
- **`WorldMap` subsystem**: loads either a hex grid or a cell graph based on the world file's format marker. Both are
  exposed through one adjacency interface — `get_neighbors(id) -> ids[]`, `move_cost(a, b) -> float`,
  `get_terrain(id) -> TerrainData` — so everything above `WorldMap` (`PartyController`, `TriggerSystem`, `WorldSim`)
  is written once, against the interface, and never branches on which format is loaded.
- **Engine-Godot boundary**: generalized from the start (no existing running system to keep compatible with) —
  `hex_entered(q, r, ...)` becomes `location_entered(id, terrain_id, province_id, realm_id, ...)`, where `id` is
  either a packed hex coordinate or a native cell id depending on the loaded world's format. `get_hex_info(q, r)`
  becomes `get_location_info(id)`.
- **Frontend rendering**: Godot scenes branch on world format the same way they'll need to branch on any other
  world-data variation — hex worlds render hex silhouettes with axial-round hover; cell-graph worlds render true
  polygon borders with spatial-hash hover (see Interaction Model below).

This is a **narrower** parallel-pipeline than an equivalent design would need if it had to preserve Protohack/
`ibp-engine`-subprocess compatibility: since `IronbandEngine` isn't built yet, the "keep both paths working"
constraint applies only to the offline tooling and `WorldMap`'s internals, not to a live wire protocol or a second
running process.

**This is still real added scope, not a small one.** "Narrower than the Protohack alternative" should not be read as
"cheap." Building the cell-graph path means: a new binary format and converter script, a new frontend rendering mode
(true polygon borders instead of hex silhouettes), a new spatial-hash input-handling path, and a generalized
engine↔Godot boundary — all of it built *before* `IronbandEngine`/`WorldMap` exist in any form, i.e. added to
milestone-1 scope for an engine that currently doesn't compile yet. That cost should be weighed explicitly against
the bugs this design prevents (see Background) when this moves to planning — it is not a free resolution of the
06-24 spec's open question, it's a deliberate scope increase in exchange for avoiding a known bug class.

## Components

| Component | Does | Used by | Depends on |
|---|---|---|---|
| `azgaar_to_cellgraph.py` | Converts Azgaar JSON → `cell_graph.bin` (sites, polygons, adjacency, terrain/biome per cell) | Run offline, same workflow as `azgaar_to_hex.py` | Azgaar JSON export format only |
| `WorldMap` (extended) | Loads hex grid *or* cell graph behind one adjacency interface | `PartyController`, `TriggerSystem`, `WorldSim`, `SignalBus` | World file's format marker |
| Adjacency interface | `get_neighbors`/`move_cost`/`get_terrain`, generic over id type (hex-packed int or native cell id) | All `WorldMap` consumers | Nothing new — decouples existing gameplay logic from hex-specific math |
| `location_entered` / `get_location_info` | Generalized signal/query replacing `hex_entered`/`get_hex_info` | Godot scenes | `WorldMap`'s active backing format |
| Spatial hash index (frontend) | Nearest-site lookup for hover/click on cell-graph worlds — see Interaction Model | `GlobalMap.gd`/`RegionMap.gd` cell-mode input handling | Cell site points from world data |
| Cell-mode rendering | Polygon-outline highlight instead of hex silhouette | Same scenes, cell-mode branch | Cell polygon border vertices |

The adjacency interface is the one load-bearing boundary between the two representations — everything above it is
written once; everything below it (the two `WorldMap` backings) can be deleted independently without touching the
other.

**`move_cost` semantics differ by backing, and that's a real design problem, not just an interface detail.** The
06-24 spec's terrain-cost model is a uniform per-hex unit cost times a terrain multiplier (road ×0.5, plains ×1.0,
forest ×1.5, etc.) — every hex costs the same base amount to cross regardless of size, because every hex *is* the
same size. Azgaar cells are not uniform: a large cell and a tiny cell both count as "one edge" in the adjacency
graph, so a flat terrain-multiplier cost would make crossing a huge cell as cheap as crossing a tiny one, silently
changing effective travel speed and distance-based gameplay (patrol range, encounter pacing tied to hexes-per-day)
between the two backings. `move_cost(a, b)` for the cell-graph backing must incorporate inter-cell distance (e.g.
site-to-site distance × terrain multiplier, normalized against the same base hours-per-unit constant the hex path
uses) rather than a flat per-edge cost, so that game-time-per-real-distance stays comparable between a hex world and
a cell-graph world of the same underlying Azgaar map.

**Formula (decided):**

```
move_cost(a, b) = distance(site_a, site_b) * terrain_multiplier(a, b) / HOURS_PER_UNIT
```

where `distance(site_a, site_b)` is Euclidean distance between the two cells' Azgaar site points (in the same
world-space units the hex grid's pixel↔coordinate mapping already uses), `terrain_multiplier` reuses the existing
BB-derived per-terrain multipliers from the 06-24 spec unchanged, and `HOURS_PER_UNIT` is the same tuning constant
the hex path resolves during implementation (06-24 spec's open question) — one shared constant, not a
per-backing duplicate, so a hex world and a cell-graph world of the same Azgaar source produce comparable
hours-per-real-distance and patrol range / encounter pacing stay consistent between backings. A hex's own
`move_cost` is unaffected — it keeps the flat per-hex cost from 06-24, since `distance(site_a, site_b)` for two
adjacent hex centers is constant by construction and collapses to the same flat cost already in use.

## Data Flow

Two independent flows, distinguished once at world-load time by the format marker; no runtime conversion between
them, and a given session is entirely one format:

**Hex flow (unchanged):** Azgaar JSON → `azgaar_to_hex.py` → `hex_grid.hexbin` → `WorldMap` loads into hex backing →
`location_entered` fires with packed axial id → Godot renders hex silhouette, resolves hover via axial-round.

**Cell-graph flow (new):** Azgaar JSON → `azgaar_to_cellgraph.py` → `cell_graph.bin` → `WorldMap` loads into
cell-graph backing → `location_entered` fires with native cell id → Godot renders true polygon borders, resolves
hover via spatial-hash nearest-site lookup.

If a hex world needs to become a cell-graph world (or vice versa), that's a re-run of the offline tooling against
the original Azgaar JSON — never a live transform of already-converted data.

## Interaction Model: Hover and Click on Cell-Graph Worlds

The current hex hover/click (`GlobalMap.gd`'s `_update_hover`/`_select_by_zoom`) relies on hex's closed-form
"point → axial coordinate" formula for O(1) lookup. Since Azgaar's cells are themselves a Voronoi diagram, "point is
inside cell X" is mathematically identical to "cell X's site point is the nearest site to this point" — so
point-in-polygon tests aren't needed, just nearest-neighbor search over site points:

1. Build a coarse spatial hash once at world load — bucket cell site points into a uniform grid (independent of any
   gameplay coordinate system, purely a performance index, e.g. `mimmackk`-style acceleration structures use the
   same trick).
2. On hover/click: compute the mouse world-position's bucket, check that bucket plus its 8 neighbors, take the
   minimum-distance site — O(1) amortized, same asymptotic cost as the current hex lookup.
3. Render hover feedback as the cell's true polygon border (already available from `cell_graph.bin`) via a
   `Line2D`/`Polygon2D` outline, rather than a hex silhouette.

The spatial hash is not a return of the hex grid — it never appears in gameplay data, adjacency, or `WorldMap`; it
exists purely inside the frontend's input-handling code as an indexing accelerator, the same category of structure a
physics engine's broad-phase collision uses.

## Rendering at Scale (Global Zoom)

This is an open technical risk this spec does not yet resolve, and it is likely bigger than the hover-performance
question above. Ironband's hex path has an established history of needing zoom-specific optimization at global
scale — `GlobalMap` skips route/river rendering entirely at global zoom (hexes are ~2px wide; polylines are
invisible and expensive to build) and the `hexbin` format itself went through a v1→v2 revision specifically to fix
global-zoom record-size handling. A hex grid's uniformity is what makes those optimizations tractable: fixed-size
cells aggregate predictably into coarser LOD tiers.

Azgaar worlds have on the order of thousands to tens of thousands of irregular cells. Rendering that many distinct
polygon fills/outlines at global zoom, where most cells cover only a few screen pixels, has no aggregation strategy
defined here — point-in-polygon fills at that density risk being far more expensive than the current per-hex
sprite/shader approach, and "just don't render borders below a pixel threshold" (the route/river precedent) may not
be sufficient since the *fills themselves*, not just outlines, carry the color/terrain data.

**Approach (decided): texture-atlas pre-rasterization at build time.** `azgaar_to_cellgraph.py` (or a companion
build step) rasterizes cell fills to a texture atlas at global-zoom resolution, the same way the hex renderer already
produces its terrain texture today — global zoom renders that atlas, not live vector polygons. True per-cell polygon
rendering (borders, hover outline) is reserved for regional zoom, where cell counts on-screen are low enough that
the existing frontend interaction model (Interaction Model section above) is cheap. This was chosen over a
cell-clustering LOD tier because it reuses the hex renderer's proven technique and rendering cost profile instead of
standing up a second, unproven LOD system on top of an already-unproven data pipeline — lower risk for a milestone-1
spec, at the cost of losing true-vector fidelity at global zoom (acceptable: the hex path already makes this same
trade today).

**Performance target:** global-zoom frame time for a cell-graph world must match the current hex renderer's
global-zoom frame time on the same converted world, within measurement noise — since both paths render the same
kind of asset (a pre-baked texture) at that zoom level, there is no structural reason for a gap; a gap would indicate
a bug in the atlas build or sampling, not an inherent cost of the cell-graph format. This target is also the
performance leg of the hex-retirement criterion below.

## Error Handling and Logging

- **World-format mismatch**: if a client/build expects one format and the world file specifies the other, fail with
  a clear version-mismatch message at load time rather than misreading bytes.
- **Degenerate cells from Azgaar data**: per `AzgaarToCK3`'s documented experience, some cells will be too small,
  disconnected fragments, or missing neighbors after conversion. `azgaar_to_cellgraph.py` rejects or merges these at
  build time — logging what was merged/dropped and why (cell id, reason) — rather than letting malformed cells reach
  `WorldMap` or the spatial hash.
- **Near-duplicate site points**: could make hover selection unstable. Flag or nudge sites below a minimum
  separation at build time; log every adjustment.
- **Variable neighbor counts**: any code assuming exactly 6 neighbors (the hex path's `RegionMap.gd` hardcoded
  direction array, `HexTerrainLoader.gd`'s 6-edge road/trail bit encoding) must not be reused as-is for the
  cell-graph path — the adjacency interface should make "assume 6 neighbors" a type-level impossibility for
  cell-graph consumers, using a variable-length edge list instead.
- **Logging, throughout**:
  - `azgaar_to_cellgraph.py` emits a per-run summary: cell count, merged/dropped degenerate cells (id + reason),
    adjacency-symmetry violations found/fixed, minimum site separation observed, build time.
  - `WorldMap` logs a neighbor-count histogram at load (catches broken adjacency immediately) and logs every
    pathfinding failure (source/dest id, not just an empty result), with a debug level tracing individual
    `get_neighbors`/`move_cost` calls — the cell-graph equivalent of the existing `get_hex_debug()` helper.
  - Frontend logs spatial-hash bucket occupancy stats at load (avg/max cells per bucket) and, in dev builds, logs
    every hover resolution (screen pos → bucket → chosen cell id) at the same granularity `GlobalMap.gd`'s `_dbg()`
    already provides for hex double-click today.
  - Every build-time validation/rejection (degenerate cells, near-duplicate sites, orphaned fragments) logs what was
    rejected and why — never a silent drop.

## Testing Strategy

- **Offline tooling**: golden-file tests for `azgaar_to_cellgraph.py` against a fixed small Azgaar fixture —
  assert cell count, adjacency symmetry (A neighbors B ⟺ B neighbors A), no degenerate/orphaned cells survive.
- **Adjacency interface**: contract tests run against both the hex and cell-graph backings — neighbor queries return
  valid, mutually-adjacent ids; a pathfind between two known-connected points returns a connected route. Not
  comparing hex results to cell-graph results directly (the topologies differ), but proving both satisfy the same
  contract.
- **Frontend interaction**: hover/click accuracy test — for a grid of sample screen points, assert the spatial-hash
  selected cell matches a brute-force nearest-site check, catching bucket-boundary bugs.
- **Manual/visual**: load one converted world in both formats side-by-side (hex vs. cell-graph rendering of the same
  Azgaar source) to sanity-check the conversion preserves terrain/coastline placement — the practical, repeatable
  substitute for the by-hand alignment checking already done for the hex path (coastal check, `river_id` fixes).

## Open Questions

- **Province/realm hierarchy on the cell graph**: should Ironband mirror `AzgaarToCK3`'s cell → county-like group →
  duchy-like group pattern explicitly, or does the existing `province_id`/`realm_id` hex-attribute model translate
  directly to cell attributes without needing an intermediate grouping tier? Needs a decision before
  `azgaar_to_cellgraph.py` is implemented.
- **Rivers on the cell graph**: `AzgaarToCK3` never solved this (dropped rivers entirely); Ironband's hex path has a
  working `river_id`-based fix. Whether that logic transfers directly to cell-graph edges or needs rework is
  unresolved.
- **Tactical/combat-scale grid**: out of scope here, but if a future combat layer wants a fixed grid, it would need
  its own rasterization step from the cell graph — not addressed by this spec.
- **When/whether to retire the hex path**: deferred, and still explicitly a placeholder, not a decision — without a
  sign-off, a parallel pipeline defaults to permanent dual-maintenance rather than an actual evaluation. Proposed
  criterion, pending Eric's sign-off: once both backings are running in `WorldMap`, retire the hex path only if the
  cell-graph backing (a) passes the same contract tests as the hex backing (Testing Strategy above), (b) meets the
  Rendering at Scale performance target (global-zoom frame time within measurement noise of the current hex
  renderer, now that Rendering at Scale itself is resolved), and (c) the bug classes in Background (coastal, river,
  route alignment) are confirmed absent on at least one full converted world. Until all three hold, both paths stay,
  and until this criterion itself is signed off, this remains the single blocker keeping this spec from being
  implementation-ready.
