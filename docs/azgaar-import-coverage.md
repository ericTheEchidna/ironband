# Azgaar Import Coverage Map

**What this is:** an inventory of every layer in an Azgaar Fantasy Map Generator
"Full" JSON export, what Ironband currently captures, what it would buy in
gameplay terms, and the rough cost to capture it.

**Why it exists:** the current importer (`ibp-engine/tools/azgaar_to_hex.py`)
keeps ~4 attributes per cell (biome, realm, province, burg name) and discards
the rest. Azgaar does not export a *map* — it exports a *world-state snapshot of
a simulated civilization*: diplomacy, fiscal systems, standing armies, a trade
network, an in-world calendar, and a war-torn backstory. This doc is the menu
for deciding which of those already-simulated systems to import-and-continue.

Sample world used for counts: `worlds/Ancient Full 2026-06-26-16-33.json`
(Azgaar 1.128.0, 6,659 land cells, seed 117890883).

---

## Current importer output

`azgaar_to_hex.py` → `hex_grid.hexbin`. Per-hex record is **10 bytes**:
`{ i16 q, i16 r, u8 biome_id, u8 realm_id, u16 province_id, u16 burg_id }`,
plus a string table for biome / realm / province / capital / burg names.

That record has no field for elevation, river, road, culture, religion, or
population. **Capturing more is a format change, not just a converter change.**

---

## Coverage table

Legend: ✅ captured · 🟡 partial · ❌ dropped

| Layer | Azgaar source | Count | Status | Gameplay value | Capture approach |
|---|---|---|---|---|---|
| Biome | `cell.biome` + `biomesData` | — | ✅ | terrain type; feeds march cost | already in hexbin |
| Realm (name) | `cell.state` + `states[].name` | 18 | 🟡 | political coloring | name only; drops everything below |
| Province | `cell.province` + `provinces[]` | 285 | 🟡 | regional coloring | name + capital only |
| Burg (name) | `burgs[].name` by cell | 858 | 🟡 | town labels | name only; drops the settlement sheet |
| Elevation | `cell.h` | per-cell | ❌ | relief, line-of-sight, defensibility | +1 byte/hex; relief shading |
| Climate | `grid.cells` temp/precip, `mapCoordinates` lat/long | 9,933 | ❌ | seasons, day length, weather events | sidecar; derive from real lat/long |
| Rivers | `pack.rivers` (source→mouth polylines, discharge, width) | 207 | ❌ | crossings, chokepoints, fords | vector overlay + crossing cost |
| Roads / sea routes | `pack.routes` (polyline paths, `group`) | 688 | ❌ | faster marching, trade lanes | vector overlay + march-cost multiplier |
| Population | `cell.pop`, `burg.population`, `state.urban/rural` | per-cell | ❌ | recruitment, contract density, regen | sidecar; per-hex + per-burg |
| Culture | `pack.cultures` (type, expansionism, origins) | 11 | ❌ | factions, relations, naming | +1 byte/hex + culture table |
| Religion | `pack.religions` (form, deity, origins) | 23 | ❌ | factions, crusades, relations | +1 byte/hex + religion table |
| Settlement detail | `burg.{population,type,port,market,citadel,walls,temple,plaza,shanty,production}` | 858 | ❌ | town services, sieges, economy | burg sidecar `.bin` |
| Economy | `pack.goods` / `markets` / `deals`, `burg.production` | 71/36/13,035 | ❌ | trade prices (feeds ported BB formula), supply chains | economy sidecar → seed trade engine |
| Military | `state.military[]` (archers/cavalry/artillery/infantry), `campaigns` | 13/state | ❌ | world armies, wars, threat | military sidecar → world actors |
| Diplomacy | `state.diplomacy` (relation per other state) | 18×18 | ❌ | faction reputation, alliances, war | realm sidecar; relation matrix |
| Fiscal | `state.{salesTax,pollTax,treasury,form,formName}` | per-state | ❌ | government behavior, prices | realm sidecar |
| Zones / events | `pack.zones` (Invasion, Rebels, Crusade, Occupation + cells) | 10 | ❌ | pre-loaded crisis event queue | seed `TriggerSystem` |
| Calendar / history | `settings.options.{year,era,eraShort}`, dated `campaigns`, `notes` | — | ❌ | epoch start date, backstory | seed `WorldClock` epoch |
| Heraldry | `burg.coa`, `state.coa` (blazons) | 859 | ❌ | faction/town visual identity (banners) | coa sidecar → banner renderer |
| Lore notes | `notes` (legend text per marker/regiment/zone) | 165 | ❌ | flavor, GM hooks | notes sidecar |
| Name generation | `nameBases` (name grammars) | 43 | ❌ | runtime lore-consistent names | import grammars |
| Named features | `pack.features` (named oceans/lakes/landmasses) | 15 | ❌ | geographic labels | features sidecar |
| Markers / POIs | `pack.markers` (🌋 volcanoes, ruins, etc.) | 76 | ❌ | points of interest, encounters | marker overlay |

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
2. **Entity tables + vectors** (realms, burgs, economy, military, rivers,
   roads, zones, coa) → sidecar `.bin`/`.json` files keyed by id, loaded
   alongside the hexbin. This is how `cheia/` already carries `cultures.bin`,
   `religions.bin`, `routes.bin`, etc. — the pattern exists; it's unused for
   most layers.

The **decision to make** (see time-model note): for each system, *import and
continue* Azgaar's simulated state, or *regenerate* it natively? Diplomacy,
military, and the economy arrive pre-simulated with a backstory — importing
them means the world starts mid-history, not at day 0.

---

## Backlog

Tracked as `ironband` tasks tagged **Azgaar import**. See Memex project 30.
This doc is the rationale; the tasks are the route.
