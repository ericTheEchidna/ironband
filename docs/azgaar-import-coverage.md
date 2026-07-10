# Azgaar Import Coverage Map

**What this is:** an inventory of every layer in an Azgaar Fantasy Map Generator
"Full" JSON export, what Ironband currently captures *and exposes in-game*, what's
imported-but-unused, what it would buy in gameplay terms, and the rough cost to
capture what's missing.

**Why it exists:** Azgaar does not export a *map* — it exports a *world-state
snapshot of a simulated civilization*: diplomacy, fiscal systems, standing armies, a
trade network, an in-world calendar, and a war-torn backstory. This doc is the menu
for deciding which of those already-simulated systems to import-and-continue.

Sample world used for counts: `worlds/Ancient Full 2026-06-26-16-33.json`
(Azgaar 1.128.0, 6,659 land cells, seed 117890883).

**Audit note (2026-07-10):** this doc previously described a single flat 10-byte
hexbin importer with no elevation/river/culture/religion support. That's no longer
accurate — see "Current importer output" below. Status verified against actual
loader/rendering code, not just importer output, as of that date.

---

## Current importer output

Two converters now, not one:

- **`ibp-engine/tools/azgaar_to_hex.py`** → `hex_grid.hexbin` (v2, 11-byte record:
  `{i16 q, i16 r, u8 biome_id, u8 realm_id, u16 province_id, u16 burg_id, u8 elevation}`)
  plus a **separate sidecar `hex_terrain.bin`** (12-byte record: height, culture_id,
  religion_id, river_flow/river_id, route_flags — see `HexTerrainLoader.gd`), plus
  `burgs.bin`, `cultures.bin`, `religions.bin`, `routes.bin`, `rivers.bin` and a
  string table.
- **`ibp-engine/tools/azgaar_to_cellgraph.py`** → `cell_graph.bin` (CGB1), a richer
  per-cell/per-vertex Voronoi graph carrying nearly everything the flat hexbin
  drops: features, zones, markers, notes, routes, coast_tier/harbor, temp/precip/pop,
  plus a compressed zlib-JSON **"extras" blob** with burg/state/province COA,
  state diplomacy/campaigns, culture/religion origins, and `nameBases`. Gated behind
  a dev-only flag (`force_cell_test` in `GlobalMap.gd`), off by default.

---

## Coverage table

Legend: ✅ exposed in-game · 🟡 imported but only partially exposed · ❌ not imported/unused

| Layer | Azgaar source | Count | Status | Evidence / gap | Task |
|---|---|---|---|---|---|
| Biome | `cell.biome` + `biomesData` | — | ✅ | rendered in hexbin/shader, shown in tooltips | — |
| Realm (name) | `cell.state` + `states[].name` | 18 | ✅ | name + color shown in tooltip/city view | see Diplomacy/Fiscal below for the rest of the state record |
| Province | `cell.province` + `provinces[]` | 285 | ✅ | name shown in tooltip/city view | — |
| Burg (name) | `burgs[].name` by cell | 858 | ✅ | `BurgLoader.gd`, rendered via `BurgMarkerLayer.gd` | — |
| Elevation | `cell.h` | per-cell | 🟡 | value captured, shown as "Elevation: %dm" in tooltip; no relief/hillshade rendering | **IRONBAND-040** |
| Climate | `grid.cells` temp/precip, `mapCoordinates` lat/long | 9,933 | ❌ | no loader/consumer | **IRONBAND-041** |
| Rivers | `pack.rivers` (source→mouth polylines, discharge, width) | 207 | 🟡 | overlay + tooltip done; no crossing-cost logic in `party_controller`/`world_map` | **IRONBAND-044** |
| Roads / sea routes | `pack.routes` (polyline paths, `group`) | 688 | 🟡 | `RouteLoader.gd`, rendered incl. ferries. **Correction:** the 0.5x road-cost multiplier in `world_map.cpp` only fires in the dev-flag-gated `CellGraph` path — the live default `Hex` path's `move_cost()` never reads `hex_terrain.bin`/`route_flags`, so roads render but don't speed march in the shipped game | **IRONBAND-045** (reopened) |
| Population (burg) | `burg.population` | 858 | ✅ | shown in tooltip and city view | done — **IRONBAND-047** |
| Population (per-cell) | `cell.pop`, `cell.s`, `state.urban`/`rural` | per-cell | ❌ | no loader/consumer | **IRONBAND-043** |
| Culture | `pack.cultures` (type, expansionism, origins) | 11 | ✅ | `CultureLoader.gd`, name shown in tooltip/city view | done — **IRONBAND-042** |
| Religion | `pack.religions` (form, deity, origins) | 23 | ✅ | `ReligionLoader.gd`, same pattern | done — **IRONBAND-042** |
| Settlement detail | `burg.{population,type,port,market,citadel,walls,temple,plaza,shanty,production}` | 858 | ✅ | walls/citadel/plaza/temple/shanty flags rendered in `CityViewPanel.gd` | done — **IRONBAND-047** |
| Economy | `pack.goods` / `markets` / `deals`, `burg.production` | 71/36/13,035 | 🟡 | `ExtrasLoader.gd` parses goods/markets; top-5 stock shown in city view. Full `deals` graph (13,035) and BB price-formula wiring not done | **IRONBAND-048** (updated scope) |
| Military (per-burg) | `burg` garrison data | 858 | ✅ | garrison names/unit counts shown in city view | done — **IRONBAND-049** (partial) |
| Military (state-level) | `state.military[]` (archers/cavalry/artillery/infantry), `campaigns` | 13/state | ❌ | sits in `cell_graph.bin` extras blob, unparsed | **IRONBAND-049** |
| Diplomacy | `state.diplomacy` (relation per other state) | 18×18 | ❌ | unparsed | **IRONBAND-046** |
| Fiscal | `state.{salesTax,pollTax,treasury,form,formName}` | per-state | ❌ | unparsed | **IRONBAND-046** |
| Zones / events | `pack.zones` (Invasion, Rebels, Crusade, Occupation + cells) | 10 | ❌ | only reachable via the dev-flag-gated cellgraph path; no `TriggerSystem` consumer | **IRONBAND-04A** |
| Calendar / history | `settings.options.{year,era,eraShort}`, dated `campaigns`, `notes` | — | ❌ | no `WorldClock` epoch seeding | **IRONBAND-04B** |
| Heraldry | `burg.coa`, `state.coa` (blazons) | 859 | ❌ | sits in extras blob, unparsed | **IRONBAND-04C** |
| Lore notes | `notes` (legend text per marker/regiment/zone) | 165 | ❌ | cellgraph-only, no UI consumer | **IRONBAND-04D** |
| Name generation | `nameBases` (name grammars) | 43 | ❌ | extras-blob-only, unused | **IRONBAND-04D** |
| Named features | `pack.features` (named oceans/lakes/landmasses) | 15 | ❌ | cellgraph-only, gated behind dev flag | **IRONBAND-04D** |
| Markers / POIs | `pack.markers` (🌋 volcanoes, ruins, etc.) | 76 | ❌ | cellgraph-only, gated behind dev flag | **IRONBAND-04D** |
| Hexbin extensibility | — | — | ✅ | v2 hexbin + `hex_terrain.bin` sidecar shipped | done — **IRONBAND-03F** |

---

## What the dropped detail actually looks like

A single capital burg:

```
burg 'Byra'  type='Naval'  port=1  population=39.9
  citadel=1 walls=1 temple=1 plaza=1 shanty=0  market=3
  treasury=62.7  production=[{goodId:21,units:5},{dealId:7747}, …]
  coa={ t1:'vert', division:{perBend…}, charges:[…], shield }
```

A single realm:

```
state 'Neagurian Empire'  form='Monarchy'/'Empire'
  diplomacy=<relation with all 18 states>   campaigns=<7 dated wars>
  military=<13 regiments>  salesTax=0.14 pollTax=0.24 treasury=2196
  urban=626 rural=5928  area=69273  alert=1.07
  '1st (Capitha) Regiment' 👑 → {archers:1485,cavalry:650,artillery:35,infantry:1773}
```

A live conflict zone and its lore:

```
zone 'Cratevilterism Crusade'  type='Crusade'  cells=101
note: "Regiment was formed in 69 Old Era during the Bybapalian War…"
```

---

## Capture strategy: format implications

Two distinct capture mechanisms, by data shape:

1. **Per-hex scalars** (elevation, culture, religion, population) → widen the
   hexbin record or add parallel per-hex layer arrays. Cheap, render-friendly.
   This pattern already shipped for elevation/culture/religion/rivers/routes via
   `hex_terrain.bin` + companion `.bin` files.
2. **Entity tables + vectors** (realms, burgs, economy, military, diplomacy,
   zones, coa) → the `cell_graph.bin` extras blob already carries most of these;
   the remaining work is mostly **parsing what's already exported**, not adding
   new export logic. Check `ExtrasLoader.gd` and the extras blob schema before
   assuming a new sidecar format is needed.

The **decision to make** (see time-model note): for each system, *import and
continue* Azgaar's simulated state, or *regenerate* it natively? Diplomacy,
military, and the economy arrive pre-simulated with a backstory — importing
them means the world starts mid-history, not at day 0.

---

## Backlog

Tracked as `ironband` tasks tagged **Azgaar import**. See Memex project 30.
This doc is the rationale; the tasks are the route.

Open tasks as of 2026-07-10: IRONBAND-040 (relief shading — elevation capture
itself is done), IRONBAND-041 (climate), IRONBAND-043 (per-cell population),
IRONBAND-044 (river crossing cost — overlay is done), IRONBAND-045 (road march
cost — reopened, see correction below), IRONBAND-046 (diplomacy/fiscal),
IRONBAND-048 (economy, partially shipped), IRONBAND-049 (state-level military —
per-burg garrisons already shipped), IRONBAND-04A (zones/events), IRONBAND-04B
(calendar/history), IRONBAND-04C (heraldry), IRONBAND-04D
(lore/features/markers/nameBases).

Done: IRONBAND-03F (hexbin v2), IRONBAND-042 (culture/religion), IRONBAND-047
(burg detail).

**Correction (2026-07-10, later same day):** IRONBAND-045 was briefly marked
done based on finding a road-cost multiplier in `world_map.cpp` — that
multiplier only fires in the dev-flag-gated `CellGraph` path, not the live
default `Hex` path. Reopened. The live `WorldMap` (Hex format) never loads
`hex_terrain.bin` at all, so neither road nor river cost affects march time in
the shipped game today — this is a shared prerequisite for both IRONBAND-044
and IRONBAND-045.

Note: this doc briefly listed IRONBAND-066 through -069 as open tasks — those
were accidental duplicates of IRONBAND-041/04C/049/043 created before a fuller
task search surfaced the originals, and have since been cancelled in favor of
the pre-existing tasks above.
