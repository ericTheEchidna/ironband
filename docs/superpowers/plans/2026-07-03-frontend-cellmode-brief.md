# Frontend Cell-Mode — Planning Brief (subsystem 3)

**Status:** Scoping brief only — NOT an executable plan. The full TDD plan must be written via
superpowers:writing-plans **after** subsystem 2 ([2026-07-03-worldmap-cellgraph-backing.md](2026-07-03-worldmap-cellgraph-backing.md))
lands, because every rendering/hover task codes against the engine query surface that plan's Task 8 produces
(`get_world_format`, `get_cell_ids`, `get_cell_sites`, `get_cell_polygon`, `get_location_info`,
`location_entered`). Writing exact GDScript now, against unbuilt bindings, would bake in placeholder
interfaces — the reason this is a brief and not a plan.

**Spec:** [2026-07-02-freeform-worldmap-design.md](../specs/2026-07-02-freeform-worldmap-design.md) —
Interaction Model, Rendering at Scale, Components table (frontend rows).

## Decisions already made (do not re-litigate at planning time)

1. **Engine-served data access (2026-07-03):** the frontend gets cell sites/polygons/terrain from
   `IronbandEngine` bindings. No `CellGraphLoader.gd`; no second CGB1 parser in GDScript.
2. **Global zoom = pre-baked texture** (spec, decided): a build-time rasterization of cell fills, the same
   technique the hex path uses (`GlobalMap._hex_img` → `ImageTexture` + shader). True polygons only at
   regional zoom.
3. **Hover = spatial hash over sites** (spec): nearest-site lookup ≡ point-in-Voronoi-cell; bucket grid,
   check 3×3 neighborhood; render the selected cell's true polygon outline.
4. **`hex_entered` stays until this subsystem migrates** to `location_entered` (engine emits both on hex
   worlds; only `location_entered` on cell worlds).

## Work outline (to become plan tasks)

1. **Atlas tooling (ibp-engine):** `tools/render_cellgraph_texture.py` — rasterize cell polygon fills
   (biome palette shared with `render_map.py`) to `worlds/<name>/cell_terrain.png` at global-zoom
   resolution. PIL, mirrors `render_map.py` conventions; unit-test the palette/polygon mapping, smoke on
   cheia.
2. **World-format detection in `GlobalMap.gd`:** branch on `IronbandEngine.get_world_format()` after
   `load_world`; cell worlds load `cell_terrain.png` instead of building the per-hex image. Routes/rivers
   drawing (`routes.bin`/`rivers.bin`) is world-space polylines — format-agnostic, reuse as-is.
3. **Spatial-hash hover:** build bucket grid from `get_cell_sites()` at load (log bucket occupancy stats —
   spec logging requirement); `_update_hover` cell-mode path → nearest site → `Line2D` outline from
   `get_cell_polygon(id)`; hover accuracy self-check in dev builds (sampled brute-force comparison, logged).
4. **Selection / info panel:** click → `get_location_info(id)` → same panel the hex path fills from
   `get_hex_info`; wire `location_entered` for party-position updates on cell worlds.
5. **Regional zoom polygons:** render visible cells' true borders (`Polygon2D`/`Line2D`) in the regional
   tier; only cells intersecting the viewport (site within padded view rect via the same spatial hash).
6. **Side-by-side verification (spec Testing Strategy):** load cheia as hex world and as cell world;
   compare terrain/coastline placement, confirm the retirement-criterion bug classes (coastal, river,
   route alignment) are absent on the cell path — this produces the evidence for criterion (c).
7. **Performance gate:** global-zoom frame-time comparison hex vs cell on cheia (retirement criterion (b)).

## Dependencies / blockers

- Subsystem 2 Tasks 4-8 (engine surface) — hard blocker for outline items 2-5.
- `worlds/cheia/cell_graph.bin` committed (subsystem 2 Task 9) — needed by items 1, 6, 7.
- Items 6-7 feed the hex-retirement criterion; they are evaluation, not construction.
