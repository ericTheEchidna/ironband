# Hex-Terrain Move Cost — Roads Speed Travel, Rivers Slow It — Design Spec

**Date:** 2026-07-10
**Status:** Approved for planning
**Closes:** remaining scope of IRONBAND-045 (road march cost), IRONBAND-044 (river crossing cost)

## Summary

`WorldMap::move_cost()` — the function that actually drives party march speed —
only has a flat per-hex terrain cost in the live default `Hex` format path. Roads
and rivers are loaded from `hex_terrain.bin` and rendered by `HexTerrainLoader.gd`
for visuals, but the C++ engine has no awareness of that file at all, so roads
render without speeding travel and rivers render without slowing it. This spec
adds `hex_terrain.bin` loading to `WorldMap` and applies road/river cost
modifiers in `move_cost()`, so the two features that already have working data
pipelines and renderers finally affect gameplay.

## Background / how this was found

Auditing the Azgaar import coverage doc (2026-07-10), IRONBAND-045 was briefly
marked done because `world_map.cpp:205` has a 0.5x road-cost multiplier. Closer
inspection showed that multiplier only fires in the `CellGraph` (Voronoi) branch
of `move_cost()`, which is gated behind the dev-only `force_cell_test` flag and
is off by default. The live default path is `Hex` format
(`world_map.cpp:182-186`), which is a flat `terrain_cost_for_biome(biome_id)` —
it never reads `hex_terrain.bin`. Grepping all of `gdextension/src/` confirmed
nothing there references `route_flags`, `river_id`, or `river_flow`.

## Goals

1. `WorldMap` (Hex format) loads `hex_terrain.bin` alongside `hex_grid.hexbin`.
2. Road hexes reduce march cost (reusing the existing 0.5x BB-derived constant,
   for consistency with the disabled CellGraph path).
3. River hexes increase march cost (new 1.5x constant).
4. A road on the entered edge negates the river penalty (bridge behavior) —
   checked first, no stacking.
5. Missing/malformed `hex_terrain.bin` degrades gracefully to today's flat
   biome-only cost, matching `HexTerrainLoader.gd`'s existing tolerance.

## Non-Goals

- Per-edge river data (rivers stay per-hex, non-directional, per available data —
  see the earlier "River cost model" decision). A true edge-crossing river model
  is a separate, larger follow-up if ever needed.
- Sea route cost (no water traversal exists yet — out of scope per IRONBAND-045's
  original notes).
- Changing the `CellGraph` path's existing (also incomplete) cost logic — that
  path is off by default and out of scope here.
- Trail cost (route_flags bit 6) — roads only, for this pass.

## Architecture

### Data loading

`WorldMap::load()`'s `Hex` branch (`world_map.cpp:35-39`) currently calls only
`load_hexbin_(buf)`. It gains a second step: derive the `hex_terrain.bin` path
from the hexbin path's directory (same sibling-file convention
`HexTerrainLoader.gd` already uses — same directory, fixed filename) and parse
it with a new private method, e.g. `load_hex_terrain_(path)`, mirroring
`HexTerrainLoader.gd`'s parser: magic `HXT1`, 10-byte header, 12-byte records
(`height u8, type_flags u8, culture_id u16, religion_id u16, river_flow u16,
river_id u16, route_flags u16`).

Parsed records are stored in a new member, keyed the same way as `cells_`:

```cpp
struct HexTerrain {
    uint8_t height = 0;
    uint8_t type_flags = 0;
    uint16_t culture_id = 0, religion_id = 0;
    uint16_t river_flow = 0, river_id = 0;
    uint16_t route_flags = 0;
};
std::unordered_map<int64_t, HexTerrain> terrain_;
```

If the file is missing, has a bad magic, or is truncated: log via
`godot::UtilityFunctions::print` (matching the existing engine's logging style)
and leave `terrain_` empty — `WorldMap::load()` still returns `true` for a
successful hexbin load. This mirrors `HexTerrainLoader.gd`'s tolerance (it
`push_warning`s and returns an empty `TerrainData` rather than failing the
whole world load).

### Cost logic

**Correction (post-brainstorm verification):** `route_flags` is NOT per-edge-direction
data. Checked `ibp-engine/tools/azgaar_to_hex.py`'s writer directly: `has_road`/
`has_trail` are **hex-level booleans** — "does any road/trail touch this hex at
all" (`azgaar_to_hex.py:111-112`), packed into `route_flags` as a single bit each
(bit 0 = has_road, bit 6 = has_trail; `azgaar_to_hex.py:694-696`). No per-edge-
direction bits are ever set. `HexTerrainLoader.gd`'s doc comment describing
"bits 0-5=road on edge N/NE/SE/S/SW/NW" is aspirational/stale — the API methods
`has_road_on_dir(d)`/`has_trail_on_dir(d)` exist but only `d=0`/`d=0` (bit 0/bit
6) can ever be true in practice, since the writer never sets the other bits.

This simplifies the design: road and river are both simple **hex-level** checks
on the destination hex, symmetric with each other — no edge/direction
resolution needed at all.

In `WorldMap::move_cost()`'s `Hex` branch (`world_map.cpp:182-186`):

```cpp
double cost = terrain_cost_for_biome(dest.biome_id);
auto it = terrain_.find(key(hex_location_q(to), hex_location_r(to)));
if (it != terrain_.end()) {
    bool has_road  = (it->second.route_flags & 0x1) != 0;
    bool has_river = it->second.river_id > 0;
    if (has_road)       cost *= ROAD_COST_MULTIPLIER;   // 0.5, existing constant
    else if (has_river) cost *= RIVER_COST_MULTIPLIER;  // 1.5, new constant
}
return cost;
```

Road is checked first and short-circuits the river penalty — a road on a river
hex behaves as a bridge, per the brainstorm decision. The two constants should
be defined once (e.g. in `hex.h` alongside `terrain_cost_for_biome`) so both the
`Hex` and `CellGraph` paths can reference the same `ROAD_COST_MULTIPLIER` instead
of the CellGraph path's currently-inline `0.5` literal.

**Documentation cleanup (small, in scope):** `HexTerrainLoader.gd`'s doc comment
and the `has_road_on_dir`/`has_trail_on_dir` method names imply directionality
that doesn't exist in the data. Correct the doc comment to state plainly that
`route_flags` is hex-level today (bit 0 = has_road, bit 6 = has_trail); leave the
method signatures alone (renaming is a larger, separate cleanup) but note in the
comment that the `d` parameter is currently unused/always effectively checked
against bit 0 given the writer's current output.

## Data flow impact

No changes needed above `WorldMap`: `IronbandEngine::get_move_cost()` and the
party-tick `cost_fn` lambda (`ironband_engine.cpp:220`) both already forward to
`map_.move_cost()`, so this fix propagates automatically to both the live move
preview (`get_move_cost`, used for UI cost previews) and actual party stepping.

## Testing

Extend `gdextension/tests/test_world_map.cpp` with a new fixture (mirroring
`hexbin_fixture.h`'s in-memory-buffer pattern) for a synthetic `hex_terrain.bin`:

- Plain hex, no road/river → baseline `terrain_cost_for_biome` cost.
- Destination hex has road (bit 0 set) → cost × 0.5.
- Destination hex has river (`river_id > 0`), no road → cost × 1.5.
- Destination hex has both road and river → cost × 0.5 (road wins, no stacking).
- Missing `hex_terrain.bin` file → falls back to baseline cost, `WorldMap::load()`
  still returns `true`.

Run via `cd gdextension/tests && ./run.sh`, must end `Status: SUCCESS!`.

## Done When

- `WorldMap` loads `hex_terrain.bin` in the `Hex` format path.
- Marching along a road hex is measurably faster than off-road, in the actual
  shipped game (not just the disabled `CellGraph` path).
- Entering a river hex without a road is measurably slower.
- A road on a river hex costs the road rate, not the river rate.
- Missing `hex_terrain.bin` doesn't break world loading.
- All new + existing `gdextension/tests` pass.
