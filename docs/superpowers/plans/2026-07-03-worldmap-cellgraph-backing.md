# WorldMap Cell-Graph Backing + Adjacency Interface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach `IronbandEngine`'s `WorldMap` to load either `hex_grid.hexbin` or `cell_graph.bin` behind one shared adjacency interface (`neighbors` / `move_cost` / `terrain`), generalize the engine↔Godot boundary to location ids, and expose the cell-query surface the frontend cell-mode (subsystem 3) will consume — subsystem 2 of the freeform-worldmap design ([spec](../specs/2026-07-02-freeform-worldmap-design.md)).

**Architecture:** A new pure-C++ `CellGraph` reader (`core/cell_graph.h/.cpp`) parses the CGB1 binary produced by `ibp-engine/tools/azgaar_to_cellgraph.py`. `WorldMap` sniffs the file magic and dispatches to the existing hex backing or the new cell backing; both implement the same location-id-based adjacency interface. `PartyController` is generalized from `Hex` to `int64_t` location ids. `IronbandEngine` gains `location_entered` (alongside the existing `hex_entered` for back-compat), `get_location_info`, and cell site/polygon queries (engine-served data access — decided 2026-07-03; the frontend gets cell data from the engine, not a duplicate GDScript parser).

**Tech Stack:** C++17, doctest (vendored), plain `g++` core tests via `gdextension/tests/run.sh`, SCons + godot-cpp (4.6) for the extension build. All work in the `ironband` repo except Task 9's data generation (ibp-engine).

## Global Constraints

- **`src/core/` MUST NOT `#include` any godot-cpp header** — core tests compile with plain g++, no Godot (existing rule from the 06-24 plan).
- **Test command:** `cd ~/source/ironband/gdextension/tests && ./run.sh` — must end `Status: SUCCESS!`. 23 test cases / 298 assertions pass before this plan starts.
- **Extension build check (Tasks 8 only):** `cd ~/source/ironband/gdextension && scons target=template_debug` — must exit 0.
- **CGB1 format** is defined by the module docstring of `~/source/ibp-engine/tools/azgaar_to_cellgraph.py` (the authoritative spec). Key facts used here, all little-endian:
  - Header 70 B: magic `"CGB1"`, `version:u16`, then 12×u16 counts (biome, culture, religion, realm, province, burg, river, feature, zone, marker, note, route), then 10×u32 (cell_count, vertex_count, border_total, neighbor_total, river_cells_total, feature_verts_total, zone_cells_total, route_pts_total, strtab_size, extras_size).
  - Meta 48 B: 9×f32 (map_w, map_h, distance_scale, latT, latN, latS, lonT, lonW, lonE) + 3×u32 strtab offsets (map_name, distance_unit, seed).
  - Sections in order after meta: strtab; biome offs (4 B×biome); realms (54 B); provinces (34 B); burgs (44 B); cultures (16 B); religions (20 B); rivers (46 B); river_cells (4 B); features (23 B); feature_verts (4 B); zones (20 B); zone_cells (4 B); markers (24 B); notes (12 B); routes (16 B); route_pts (12 B); vertices (8 B: f32 x, f32 y); cells (64 B); borders (4 B×border_total); neighbors (4 B×neighbor_total); edge_routes (2 B×neighbor_total, `0xFFFF`=no route); extras (zlib, `extras_size` B — the C++ reader skips it).
  - Cell record 64 B, field order: `id:u32, cx:f32, cy:f32, biome:u8, coast_tier:i8, elevation:u8, harbor:u8, realm:u16, province:u16, culture:u16, religion:u16, burg:u16, river:u16, river_flow:u16, confluence:u16, area:u16, suitability:u16, feature:u16, temp:i8, prec:u8, pop:f32, grid_id:u32, haven:u32, border_start:u32, border_count:u16, neighbor_start:u32, neighbor_count:u8, is_water:u8`.
  - Realm row 54 B: `id:u16 @0, name_off:u32 @2, full_name_off:u32 @6, form_off:u32 @10, capital:u16 @14, culture:u16 @16, center:u32 @18, color_off:u32 @22, 7×f32 @26`. Province row 34 B: `id:u16 @0, state:u16 @2, burg:u16 @4, center:u32 @6, name_off:u32 @10, full_name_off:u32 @14, form_off:u32 @18, color_off:u32 @22, 2×f32 @26`. Route row 16 B: `id:u16 @0, group_off:u32 @2, feature:u32 @6, pts_start:u32 @10, pts_count:u16 @14`.
- **All ids in CGB1 are Azgaar-native** (cells may be sparse after repair); the reader builds an id→index map. Never index `cells_[id]` directly.
- **Location id convention (this plan defines it, later plans consume it):** `int64_t`. Hex backing: packed axial `((int64_t)q << 32) ^ (uint32_t)r` (identical to the existing `WorldMap::key`). Cell backing: the native cell id, zero-extended.
- **`move_cost` semantics (spec, decided):** hex backing keeps today's flat per-hex model (`terrain_cost_for_biome(dest)` hours). Cell backing: `euclid(site_a, site_b) × terrain_cost_for_biome(dest) × hours_per_unit`, road edge ×0.5, water dest `IMPASSABLE`. `hours_per_unit` is one settable tuning constant (default 1.0), calibrated later — the 06-24 spec's open `HOURS_PER_UNIT` question; do not invent a value.
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

- Create: `gdextension/src/core/cell_graph.h` / `.cpp` — CGB1 reader (header/meta/strtab/names, cells, adjacency slices, route groups). One responsibility: parse + expose.
- Create: `gdextension/tests/cellgraph_fixture.h` — hand-rolled minimal CGB1 writer (mirrors `hexbin_fixture.h`).
- Create: `gdextension/tests/test_cell_graph.cpp` — reader tests.
- Modify: `gdextension/src/core/world_map.h` / `.cpp` — format dispatch, adjacency interface, `move_cost`.
- Modify: `gdextension/tests/test_world_map.cpp` — v2 hexbin fix tests, dispatch + contract tests.
- Modify: `gdextension/tests/hexbin_fixture.h` — emit v2 records (elevation).
- Modify: `gdextension/src/core/party_controller.h` / `.cpp`, `gdextension/tests/test_party.cpp` — Hex → location ids.
- Modify: `gdextension/src/ironband_engine.h` / `.cpp` — location boundary + cell queries.
- Create (Task 9, ibp-engine repo): `worlds/cheia/cell_graph.bin` — generated, committed.

---

### Task 1: Fix hexbin v2 record parsing (latent bug)

`azgaar_to_hex.py` writes **version 2** hexbin (11-byte hex records, trailing `u8 elevation`) — see its docstring line "N×11 B adds u8 elevation (v2)". `WorldMap::load` hardcodes 10-byte records and ignores `version`, so it misparses every real world file generated since v2. The GDScript loader handles v2; the engine doesn't.

**Files:**
- Modify: `gdextension/src/core/world_map.h` (add `elevation` to `HexCell`)
- Modify: `gdextension/src/core/world_map.cpp:73-84`
- Modify: `gdextension/tests/hexbin_fixture.h` (write v2)
- Test: `gdextension/tests/test_world_map.cpp`

**Interfaces:**
- Produces: `HexCell.elevation` (int, 0-255). `WorldMap::load` accepts v1 (10 B records, elevation 0) and v2 (11 B).

- [ ] **Step 1: Write the failing test**

In `tests/hexbin_fixture.h`, change the fixture to v2: in `write_fixture_hexbin`, change the version write `u16(body, 1);` to `u16(body, 2);`, and at the end of **each** of the two hex records append one elevation byte — the record-writing block gains `body.push_back(42);` for the first record and `body.push_back(7);` for the second (immediately after each record's final `u16` field).

In `tests/test_world_map.cpp`, add to the existing `TEST_CASE("WorldMap loads header, cells, and names from hexbin")` after the `c->province_id` check:

```cpp
    CHECK(c->elevation == 42);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: compile error `no member named 'elevation' in 'ib::HexCell'` (or, after adding the field only, CHECK failure / misparsed cells because the reader still assumes 10 B).

- [ ] **Step 3: Write minimal implementation**

`src/core/world_map.h` — add to `HexCell`:

```cpp
struct HexCell {
    int q = 0, r = 0;
    int biome_id = 0, realm_id = 0, province_id = 0, burg_id = 0;
    int elevation = 0;   // 0-255, hexbin v2+; 0 for v1 files
};
```

`src/core/world_map.cpp` — replace the hex-record loop:

```cpp
    const size_t rec_size = header_.version >= 2 ? 11 : 10;
    for (int i = 0; i < header_.hex_count; ++i) {
        if (pos + rec_size > buf.size()) return false;
        HexCell c;
        c.q           = rd_i16(buf.data() + pos);
        c.r           = rd_i16(buf.data() + pos + 2);
        c.biome_id    = buf[pos + 4];
        c.realm_id    = buf[pos + 5];
        c.province_id = rd_u16(buf.data() + pos + 6);
        c.burg_id     = rd_u16(buf.data() + pos + 8);
        if (rec_size == 11) c.elevation = buf[pos + 10];
        pos += rec_size;
        cells_[key(c.q, c.r)] = c;
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: `Status: SUCCESS!` (23 cases, assertions grow by 1)

- [ ] **Step 5: Commit**

```bash
cd ~/source/ironband
git add gdextension/src/core/world_map.h gdextension/src/core/world_map.cpp gdextension/tests/hexbin_fixture.h gdextension/tests/test_world_map.cpp
git commit -m "fix(engine): parse hexbin v2 11-byte records with elevation"
```

---

### Task 2: CGB1 fixture + CellGraph header/meta/strtab/names

**Files:**
- Create: `gdextension/tests/cellgraph_fixture.h`
- Create: `gdextension/src/core/cell_graph.h`
- Create: `gdextension/src/core/cell_graph.cpp`
- Test: `gdextension/tests/test_cell_graph.cpp`

**Interfaces:**
- Produces: `ib::CellGraph` with `bool load(const std::string&)`, `bool loaded() const`, `const CellGraphHeader& header() const`, `const CellGraphMeta& meta() const`, `std::string biome_name(int) const`, `std::string realm_name(int) const`, `std::string province_name(int) const` (province name = the row's **full_name** offset @14, matching hexbin behavior).
- Produces: `write_fixture_cellgraph(path)` — 3 cells in a row (ids 0,1,2; sites (0,0),(10,0),(20,0)), cell 2 water; 4 vertices; 1 realm "Northreach" (id 1), 1 province "Coldvale" (id 1, full_name "Coldvale March"), 1 route (id 0, group "roads"); edge 0↔1 carries route 0; all other table counts 0; `extras_size = 0`; biomes ["Marine","Grassland","Forest"]; cells 0,1 biome 1/realm 1/province 1, cell 2 biome 0/is_water/realm 0; elevations 40,55,0; borders: cell0=[0,1,2], cell1=[1,2,3], cell2=[2,3,0]; neighbors: cell0=[1], cell1=[0,2], cell2=[1]; edge_routes: [0], [0,0xFFFF], [0xFFFF]. Meta: map 1280×768, distance_scale 3.0, map_name "Testland", distance_unit "mi".

- [ ] **Step 1: Write the fixture**

Create `tests/cellgraph_fixture.h`:

```cpp
#pragma once
#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

// Writes a minimal valid cell_graph.bin (CGB1): 3 cells in a row, cell 2
// marine; 1 realm, 1 province, 1 road route on edge 0<->1; extras_size 0.
inline std::string write_fixture_cellgraph(const std::string& path) {
    std::vector<uint8_t> b;
    auto u8  = [&](uint8_t v){ b.push_back(v); };
    auto i8  = [&](int8_t v){ b.push_back((uint8_t)v); };
    auto u16 = [&](uint16_t v){ b.push_back(v&0xFF); b.push_back((v>>8)&0xFF); };
    auto u32 = [&](uint32_t v){ for(int i=0;i<4;i++) b.push_back((v>>(8*i))&0xFF); };
    auto f32 = [&](float v){ uint8_t p[4]; std::memcpy(p,&v,4); for(int i=0;i<4;i++) b.push_back(p[i]); };

    // ── strtab (built first so offsets are known) ────────────────────────
    std::vector<uint8_t> st; st.push_back(0);            // offset 0 = ""
    auto add_str = [&](const std::string& s)->uint32_t {
        uint32_t off = (uint32_t)st.size();
        for (char c : s) st.push_back((uint8_t)c);
        st.push_back(0);
        return off;
    };
    uint32_t off_marine = add_str("Marine");
    uint32_t off_grass  = add_str("Grassland");
    uint32_t off_forest = add_str("Forest");
    uint32_t off_realm  = add_str("Northreach");
    uint32_t off_provn  = add_str("Coldvale");
    uint32_t off_provf  = add_str("Coldvale March");
    uint32_t off_roads  = add_str("roads");
    uint32_t off_name   = add_str("Testland");
    uint32_t off_unit   = add_str("mi");

    // ── header 70 B ──────────────────────────────────────────────────────
    u8('C'); u8('G'); u8('B'); u8('1');
    u16(1);                       // version
    u16(3);                       // biome_count
    u16(0); u16(0);               // culture_count, religion_count
    u16(1); u16(1); u16(0);       // realm, province, burg
    u16(0); u16(0); u16(0);       // river, feature, zone
    u16(0); u16(0); u16(1);       // marker, note, route
    u32(3);                       // cell_count
    u32(4);                       // vertex_count
    u32(9);                       // border_total  (3 per cell)
    u32(4);                       // neighbor_total (1+2+1)
    u32(0); u32(0); u32(0); u32(0); // river_cells, feature_verts, zone_cells, route_pts
    u32((uint32_t)st.size());     // strtab_size
    u32(0);                       // extras_size
    // ── meta 48 B ────────────────────────────────────────────────────────
    f32(1280.0f); f32(768.0f); f32(3.0f);                 // map w/h, distance_scale
    f32(59.4f); f32(29.7f); f32(-29.7f);                  // latT latN latS
    f32(99.0f); f32(-49.5f); f32(49.5f);                  // lonT lonW lonE
    u32(off_name); u32(off_unit); u32(0);                 // map_name, distance_unit, seed
    // ── strtab ───────────────────────────────────────────────────────────
    for (uint8_t c : st) b.push_back(c);
    // ── biome offsets ────────────────────────────────────────────────────
    u32(off_marine); u32(off_grass); u32(off_forest);
    // ── realms: 1 row, 54 B ──────────────────────────────────────────────
    u16(1); u32(off_realm); u32(0); u32(0);               // id, name, full, form
    u16(0); u16(0); u32(0); u32(0);                       // capital, culture, center, color
    for (int i = 0; i < 7; i++) f32(0.0f);
    // ── provinces: 1 row, 34 B ───────────────────────────────────────────
    u16(1); u16(1); u16(0); u32(0);                       // id, state, burg, center
    u32(off_provn); u32(off_provf); u32(0); u32(0);       // name, full_name, form, color
    f32(0.0f); f32(0.0f);                                 // pole
    // ── burgs 0, cultures 0, religions 0, rivers 0 (+0 cells), features 0
    //    (+0 verts), zones 0 (+0 cells), markers 0, notes 0 ── nothing.
    // ── routes: 1 row, 16 B ──────────────────────────────────────────────
    u16(0); u32(off_roads); u32(0); u32(0); u16(0);       // id 0, group "roads", 0 pts
    // ── route points 0 ── nothing.
    // ── vertices: 4×8 B ──────────────────────────────────────────────────
    f32(-5.0f); f32(-5.0f);  f32(5.0f);  f32(-5.0f);
    f32(15.0f); f32(-5.0f);  f32(25.0f); f32(-5.0f);
    // ── cells: 3×64 B ────────────────────────────────────────────────────
    auto cell = [&](uint32_t id, float cx, float cy, uint8_t biome, int8_t tier,
                    uint8_t elev, uint16_t realm, uint16_t prov,
                    uint32_t bstart, uint16_t bcount,
                    uint32_t nstart, uint8_t ncount, uint8_t water) {
        u32(id); f32(cx); f32(cy);
        u8(biome); i8(tier); u8(elev); u8(0);             // biome, coast_tier, elevation, harbor
        u16(realm); u16(prov); u16(0); u16(0);            // realm, province, culture, religion
        u16(0); u16(0); u16(0); u16(0);                   // burg, river, river_flow, confluence
        u16(10); u16(0); u16(0);                          // area, suitability, feature
        i8(15); u8(20); f32(1.5f);                        // temp, prec, pop
        u32(0); u32(0);                                   // grid_id, haven
        u32(bstart); u16(bcount); u32(nstart); u8(ncount);
        u8(water);
    };
    cell(0,  0.0f, 0.0f, 1,  1, 40, 1, 1, 0, 3, 0, 1, 0);
    cell(1, 10.0f, 0.0f, 1,  1, 55, 1, 1, 3, 3, 1, 2, 0);
    cell(2, 20.0f, 0.0f, 0, -1,  0, 0, 0, 6, 3, 3, 1, 1);
    // ── borders: 9×u32 ───────────────────────────────────────────────────
    u32(0); u32(1); u32(2);   u32(1); u32(2); u32(3);   u32(2); u32(3); u32(0);
    // ── neighbors: 4×u32 ─────────────────────────────────────────────────
    u32(1);   u32(0); u32(2);   u32(1);
    // ── edge routes: 4×u16 ───────────────────────────────────────────────
    u16(0);   u16(0); u16(0xFFFF);   u16(0xFFFF);
    // ── extras: none (extras_size 0) ─────────────────────────────────────

    std::ofstream f(path, std::ios::binary);
    f.write((const char*)b.data(), (std::streamsize)b.size());
    return path;
}
```

- [ ] **Step 2: Write the failing test**

Create `tests/test_cell_graph.cpp`:

```cpp
#include "doctest.h"
#include "core/cell_graph.h"
#include "cellgraph_fixture.h"
#include <fstream>

using namespace ib;

TEST_CASE("CellGraph loads header, meta, and name tables") {
    std::string path = "build/fixture.cellgraph";
    write_fixture_cellgraph(path);

    CellGraph g;
    REQUIRE(g.load(path));
    REQUIRE(g.loaded());

    const CellGraphHeader& h = g.header();
    CHECK(h.version == 1);
    CHECK(h.biome_count == 3);
    CHECK(h.cell_count == 3);
    CHECK(h.vertex_count == 4);
    CHECK(h.neighbor_total == 4);
    CHECK(h.border_total == 9);
    CHECK(h.route_count == 1);

    const CellGraphMeta& m = g.meta();
    CHECK(m.map_width == doctest::Approx(1280.0));
    CHECK(m.distance_scale == doctest::Approx(3.0));
    CHECK(m.map_name == "Testland");
    CHECK(m.distance_unit == "mi");

    CHECK(g.biome_name(0) == "Marine");
    CHECK(g.biome_name(1) == "Grassland");
    CHECK(g.realm_name(1) == "Northreach");
    CHECK(g.province_name(1) == "Coldvale March");
    CHECK(g.realm_name(99) == "");
}

TEST_CASE("CellGraph rejects bad magic and short files") {
    { std::ofstream f("build/bad.cellgraph", std::ios::binary); f << "XXXX"; }
    CellGraph g;
    CHECK(!g.load("build/bad.cellgraph"));
    CHECK(!g.loaded());
    CHECK(!g.load("build/does_not_exist.cellgraph"));
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: compile error `core/cell_graph.h: No such file or directory`

- [ ] **Step 4: Write minimal implementation**

Create `src/core/cell_graph.h`:

```cpp
#pragma once
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace ib {

struct CellGraphHeader {
    int version = 0;
    int biome_count = 0, culture_count = 0, religion_count = 0, realm_count = 0;
    int province_count = 0, burg_count = 0, river_count = 0, feature_count = 0;
    int zone_count = 0, marker_count = 0, note_count = 0, route_count = 0;
    uint32_t cell_count = 0, vertex_count = 0, border_total = 0, neighbor_total = 0;
    uint32_t river_cells_total = 0, feature_verts_total = 0, zone_cells_total = 0;
    uint32_t route_pts_total = 0, strtab_size = 0, extras_size = 0;
};

struct CellGraphMeta {
    double map_width = 0.0, map_height = 0.0, distance_scale = 0.0;
    double lat_t = 0.0, lat_n = 0.0, lat_s = 0.0;
    double lon_t = 0.0, lon_w = 0.0, lon_e = 0.0;
    std::string map_name, distance_unit, seed;
};

struct GraphCell {
    uint32_t id = 0;
    float cx = 0.0f, cy = 0.0f;
    int biome_id = 0, coast_tier = 0, elevation = 0, harbor = 0;
    int realm_id = 0, province_id = 0, culture_id = 0, religion_id = 0;
    int burg_id = 0, river_id = 0, river_flow = 0, confluence = 0;
    int area = 0, suitability = 0, feature_id = 0;
    int temp = 0, prec = 0;
    float pop = 0.0f;
    uint32_t grid_id = 0, haven = 0;
    uint32_t border_start = 0; int border_count = 0;
    uint32_t neighbor_start = 0; int neighbor_count = 0;
    bool is_water = false;
};

// Route groups (from Azgaar route "group" strings).
enum class RouteGroup : uint8_t { Road = 0, Trail = 1, Searoute = 2, Unknown = 255 };
constexpr uint16_t NO_ROUTE = 0xFFFF;

class CellGraph {
public:
    bool load(const std::string& path);
    bool loaded() const { return loaded_; }
    const CellGraphHeader& header() const { return header_; }
    const CellGraphMeta& meta() const { return meta_; }

    std::string biome_name(int biome_id) const;
    std::string realm_name(int realm_id) const;
    std::string province_name(int province_id) const;

    const GraphCell* cell(uint32_t id) const;              // by native (possibly sparse) id
    const std::vector<GraphCell>& cells() const { return cells_; }

    // Adjacency slices (valid only for a cell returned by this graph):
    const uint32_t* neighbors(const GraphCell& c) const { return neighbors_.data() + c.neighbor_start; }
    const uint32_t* border(const GraphCell& c) const { return borders_.data() + c.border_start; }
    uint16_t edge_route(const GraphCell& c, int k) const { return edge_routes_[c.neighbor_start + (uint32_t)k]; }
    RouteGroup route_group(uint16_t route_id) const;
    void vertex(uint32_t vid, float& x, float& y) const {
        x = verts_[(size_t)vid * 2]; y = verts_[(size_t)vid * 2 + 1];
    }

private:
    bool loaded_ = false;
    CellGraphHeader header_;
    CellGraphMeta meta_;
    std::vector<GraphCell> cells_;
    std::unordered_map<uint32_t, size_t> index_by_id_;
    std::vector<uint32_t> neighbors_, borders_;
    std::vector<uint16_t> edge_routes_;
    std::vector<float> verts_;                             // x,y interleaved
    std::unordered_map<int, std::string> biome_names_, realm_names_, province_names_;
    std::unordered_map<uint16_t, RouteGroup> route_groups_;
};

} // namespace ib
```

Create `src/core/cell_graph.cpp` (this task implements through the name tables; cells/adjacency land in Task 3 — the loop bodies below marked `// Task 3` are written as section *skips* here and replaced in Task 3):

```cpp
#include "core/cell_graph.h"
#include <cstring>
#include <fstream>

namespace ib {

static uint16_t rd_u16(const uint8_t* p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd_u32(const uint8_t* p) {
    return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}
static float rd_f32(const uint8_t* p) { float v; std::memcpy(&v, p, 4); return v; }

static std::string strtab_get(const std::vector<uint8_t>& tab, uint32_t off) {
    if (off >= tab.size()) return "";
    return std::string((const char*)&tab[off]);
}

bool CellGraph::load(const std::string& path) {
    loaded_ = false;
    cells_.clear(); index_by_id_.clear();
    neighbors_.clear(); borders_.clear(); edge_routes_.clear(); verts_.clear();
    biome_names_.clear(); realm_names_.clear(); province_names_.clear();
    route_groups_.clear();

    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)),
                              std::istreambuf_iterator<char>());
    if (buf.size() < 70 + 48) return false;
    if (std::memcmp(buf.data(), "CGB1", 4) != 0) return false;

    const uint8_t* h = buf.data();
    header_.version         = rd_u16(h + 4);
    header_.biome_count     = rd_u16(h + 6);
    header_.culture_count   = rd_u16(h + 8);
    header_.religion_count  = rd_u16(h + 10);
    header_.realm_count     = rd_u16(h + 12);
    header_.province_count  = rd_u16(h + 14);
    header_.burg_count      = rd_u16(h + 16);
    header_.river_count     = rd_u16(h + 18);
    header_.feature_count   = rd_u16(h + 20);
    header_.zone_count      = rd_u16(h + 22);
    header_.marker_count    = rd_u16(h + 24);
    header_.note_count      = rd_u16(h + 26);
    header_.route_count     = rd_u16(h + 28);
    header_.cell_count          = rd_u32(h + 30);
    header_.vertex_count        = rd_u32(h + 34);
    header_.border_total        = rd_u32(h + 38);
    header_.neighbor_total      = rd_u32(h + 42);
    header_.river_cells_total   = rd_u32(h + 46);
    header_.feature_verts_total = rd_u32(h + 50);
    header_.zone_cells_total    = rd_u32(h + 54);
    header_.route_pts_total     = rd_u32(h + 58);
    header_.strtab_size         = rd_u32(h + 62);
    header_.extras_size         = rd_u32(h + 66);

    const uint8_t* m = buf.data() + 70;
    meta_.map_width      = rd_f32(m + 0);
    meta_.map_height     = rd_f32(m + 4);
    meta_.distance_scale = rd_f32(m + 8);
    meta_.lat_t = rd_f32(m + 12); meta_.lat_n = rd_f32(m + 16); meta_.lat_s = rd_f32(m + 20);
    meta_.lon_t = rd_f32(m + 24); meta_.lon_w = rd_f32(m + 28); meta_.lon_e = rd_f32(m + 32);
    uint32_t off_name = rd_u32(m + 36), off_unit = rd_u32(m + 40), off_seed = rd_u32(m + 44);

    size_t pos = 70 + 48;
    if (pos + header_.strtab_size > buf.size()) return false;
    std::vector<uint8_t> strtab(buf.begin() + pos, buf.begin() + pos + header_.strtab_size);
    pos += header_.strtab_size;
    meta_.map_name      = strtab_get(strtab, off_name);
    meta_.distance_unit = strtab_get(strtab, off_unit);
    meta_.seed          = strtab_get(strtab, off_seed);

    auto need = [&](size_t n) { return pos + n <= buf.size(); };

    // biomes
    for (int i = 0; i < header_.biome_count; ++i) {
        if (!need(4)) return false;
        biome_names_[i] = strtab_get(strtab, rd_u32(buf.data() + pos));
        pos += 4;
    }
    // realms (54 B: name_off @2)
    for (int i = 0; i < header_.realm_count; ++i) {
        if (!need(54)) return false;
        uint16_t id  = rd_u16(buf.data() + pos);
        realm_names_[id] = strtab_get(strtab, rd_u32(buf.data() + pos + 2));
        pos += 54;
    }
    // provinces (34 B: full_name_off @14)
    for (int i = 0; i < header_.province_count; ++i) {
        if (!need(34)) return false;
        uint16_t id  = rd_u16(buf.data() + pos);
        province_names_[id] = strtab_get(strtab, rd_u32(buf.data() + pos + 14));
        pos += 34;
    }
    // burgs / cultures / religions / rivers(+cells) / features(+verts) /
    // zones(+cells) / markers / notes — skipped (not needed by the engine yet)
    pos += (size_t)header_.burg_count * 44;
    pos += (size_t)header_.culture_count * 16;
    pos += (size_t)header_.religion_count * 20;
    pos += (size_t)header_.river_count * 46 + (size_t)header_.river_cells_total * 4;
    pos += (size_t)header_.feature_count * 23 + (size_t)header_.feature_verts_total * 4;
    pos += (size_t)header_.zone_count * 20 + (size_t)header_.zone_cells_total * 4;
    pos += (size_t)header_.marker_count * 24;
    pos += (size_t)header_.note_count * 12;
    // routes (16 B: group_off @2) — group per route id
    for (int i = 0; i < header_.route_count; ++i) {
        if (!need(16)) return false;
        uint16_t id = rd_u16(buf.data() + pos);
        std::string grp = strtab_get(strtab, rd_u32(buf.data() + pos + 2));
        RouteGroup g = RouteGroup::Unknown;
        if (grp == "roads") g = RouteGroup::Road;
        else if (grp == "trails") g = RouteGroup::Trail;
        else if (grp == "searoutes") g = RouteGroup::Searoute;
        route_groups_[id] = g;
        pos += 16;
    }
    pos += (size_t)header_.route_pts_total * 12;

    // vertices / cells / borders / neighbors / edge_routes — Task 3 parses
    // these; Task 2 only validates the sizes exist.
    size_t tail = (size_t)header_.vertex_count * 8
                + (size_t)header_.cell_count * 64
                + (size_t)header_.border_total * 4
                + (size_t)header_.neighbor_total * 4
                + (size_t)header_.neighbor_total * 2
                + (size_t)header_.extras_size;
    if (pos + tail > buf.size()) return false;

    loaded_ = true;
    return true;
}

std::string CellGraph::biome_name(int biome_id) const {
    auto it = biome_names_.find(biome_id);
    return it == biome_names_.end() ? "" : it->second;
}
std::string CellGraph::realm_name(int realm_id) const {
    auto it = realm_names_.find(realm_id);
    return it == realm_names_.end() ? "" : it->second;
}
std::string CellGraph::province_name(int province_id) const {
    auto it = province_names_.find(province_id);
    return it == province_names_.end() ? "" : it->second;
}
const GraphCell* CellGraph::cell(uint32_t id) const {
    auto it = index_by_id_.find(id);
    return it == index_by_id_.end() ? nullptr : &cells_[it->second];
}
RouteGroup CellGraph::route_group(uint16_t route_id) const {
    auto it = route_groups_.find(route_id);
    return it == route_groups_.end() ? RouteGroup::Unknown : it->second;
}

} // namespace ib
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: `Status: SUCCESS!` (25 cases)

- [ ] **Step 6: Commit**

```bash
cd ~/source/ironband
git add gdextension/src/core/cell_graph.h gdextension/src/core/cell_graph.cpp gdextension/tests/cellgraph_fixture.h gdextension/tests/test_cell_graph.cpp
git commit -m "feat(engine): CellGraph CGB1 reader — header, meta, name tables"
```

---

### Task 3: CellGraph cells, vertices, and adjacency slices

**Files:**
- Modify: `gdextension/src/core/cell_graph.cpp` (replace the Task-2 tail-size validation with real parsing)
- Test: `gdextension/tests/test_cell_graph.cpp`

**Interfaces:**
- Produces (already declared in Task 2's header): populated `cells()`, `cell(id)`, `neighbors(c)`, `border(c)`, `edge_route(c,k)`, `vertex(vid,x,y)`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_cell_graph.cpp`:

```cpp
TEST_CASE("CellGraph parses cells, vertices, and adjacency") {
    std::string path = "build/fixture.cellgraph";
    write_fixture_cellgraph(path);
    CellGraph g;
    REQUIRE(g.load(path));

    REQUIRE(g.cells().size() == 3);
    const GraphCell* c0 = g.cell(0);
    const GraphCell* c1 = g.cell(1);
    const GraphCell* c2 = g.cell(2);
    REQUIRE(c0 != nullptr); REQUIRE(c1 != nullptr); REQUIRE(c2 != nullptr);
    CHECK(g.cell(99) == nullptr);

    CHECK(c0->cx == doctest::Approx(0.0f));
    CHECK(c1->cx == doctest::Approx(10.0f));
    CHECK(c0->biome_id == 1);
    CHECK(c0->elevation == 40);
    CHECK(c0->realm_id == 1);
    CHECK(c0->province_id == 1);
    CHECK(c0->coast_tier == 1);
    CHECK(c2->coast_tier == -1);       // signed round-trip
    CHECK(c2->is_water);
    CHECK(!c0->is_water);
    CHECK(c0->temp == 15);
    CHECK(c0->pop == doctest::Approx(1.5f));

    // adjacency: 0-[1], 1-[0,2], 2-[1]
    REQUIRE(c1->neighbor_count == 2);
    CHECK(g.neighbors(*c1)[0] == 0);
    CHECK(g.neighbors(*c1)[1] == 2);
    REQUIRE(c0->neighbor_count == 1);
    CHECK(g.neighbors(*c0)[0] == 1);

    // borders: cell1 = [1,2,3]
    REQUIRE(c1->border_count == 3);
    CHECK(g.border(*c1)[0] == 1);
    CHECK(g.border(*c1)[2] == 3);

    // edge routes: 0->1 is road route 0; 1->2 has none
    CHECK(g.edge_route(*c0, 0) == 0);
    CHECK(g.route_group(0) == RouteGroup::Road);
    CHECK(g.edge_route(*c1, 0) == 0);        // 1->0 (reciprocal road)
    CHECK(g.edge_route(*c1, 1) == NO_ROUTE); // 1->2
    CHECK(g.edge_route(*c2, 0) == NO_ROUTE);

    // vertices
    float x = 0, y = 0;
    g.vertex(1, x, y);
    CHECK(x == doctest::Approx(5.0f));
    CHECK(y == doctest::Approx(-5.0f));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: FAIL — `g.cells().size() == 3` is 0 (Task 2 only validated sizes)

- [ ] **Step 3: Write minimal implementation**

In `src/core/cell_graph.cpp`, replace the block from `// vertices / cells / borders ...` through `if (pos + tail > buf.size()) return false;` with:

```cpp
    // vertices
    if (!need((size_t)header_.vertex_count * 8)) return false;
    verts_.resize((size_t)header_.vertex_count * 2);
    for (uint32_t i = 0; i < header_.vertex_count; ++i) {
        verts_[(size_t)i * 2]     = rd_f32(buf.data() + pos);
        verts_[(size_t)i * 2 + 1] = rd_f32(buf.data() + pos + 4);
        pos += 8;
    }
    // cells (64 B records — offsets per the CGB1 cell layout)
    if (!need((size_t)header_.cell_count * 64)) return false;
    cells_.resize(header_.cell_count);
    for (uint32_t i = 0; i < header_.cell_count; ++i) {
        const uint8_t* p = buf.data() + pos;
        GraphCell& c = cells_[i];
        c.id          = rd_u32(p + 0);
        c.cx          = rd_f32(p + 4);
        c.cy          = rd_f32(p + 8);
        c.biome_id    = p[12];
        c.coast_tier  = (int8_t)p[13];
        c.elevation   = p[14];
        c.harbor      = p[15];
        c.realm_id    = rd_u16(p + 16);
        c.province_id = rd_u16(p + 18);
        c.culture_id  = rd_u16(p + 20);
        c.religion_id = rd_u16(p + 22);
        c.burg_id     = rd_u16(p + 24);
        c.river_id    = rd_u16(p + 26);
        c.river_flow  = rd_u16(p + 28);
        c.confluence  = rd_u16(p + 30);
        c.area        = rd_u16(p + 32);
        c.suitability = rd_u16(p + 34);
        c.feature_id  = rd_u16(p + 36);
        c.temp        = (int8_t)p[38];
        c.prec        = p[39];
        c.pop         = rd_f32(p + 40);
        c.grid_id     = rd_u32(p + 44);
        c.haven       = rd_u32(p + 48);
        c.border_start   = rd_u32(p + 52);
        c.border_count   = rd_u16(p + 56);
        c.neighbor_start = rd_u32(p + 58);
        c.neighbor_count = p[62];
        c.is_water       = p[63] != 0;
        index_by_id_[c.id] = i;
        pos += 64;
    }
    // borders
    if (!need((size_t)header_.border_total * 4)) return false;
    borders_.resize(header_.border_total);
    for (uint32_t i = 0; i < header_.border_total; ++i) { borders_[i] = rd_u32(buf.data() + pos); pos += 4; }
    // neighbors
    if (!need((size_t)header_.neighbor_total * 4)) return false;
    neighbors_.resize(header_.neighbor_total);
    for (uint32_t i = 0; i < header_.neighbor_total; ++i) { neighbors_[i] = rd_u32(buf.data() + pos); pos += 4; }
    // edge routes
    if (!need((size_t)header_.neighbor_total * 2)) return false;
    edge_routes_.resize(header_.neighbor_total);
    for (uint32_t i = 0; i < header_.neighbor_total; ++i) { edge_routes_[i] = rd_u16(buf.data() + pos); pos += 2; }
    // extras: intentionally skipped (zlib JSON; no engine consumer)
    if (!need(header_.extras_size)) return false;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: `Status: SUCCESS!` (26 cases)

- [ ] **Step 5: Commit**

```bash
cd ~/source/ironband
git add gdextension/src/core/cell_graph.cpp gdextension/tests/test_cell_graph.cpp
git commit -m "feat(engine): CellGraph cells, vertices, adjacency, edge routes"
```

---

### Task 4: WorldMap format dispatch

**Files:**
- Modify: `gdextension/src/core/world_map.h`
- Modify: `gdextension/src/core/world_map.cpp`
- Test: `gdextension/tests/test_world_map.cpp`

**Interfaces:**
- Produces: `enum class WorldFormat { None, Hex, CellGraph };`, `WorldFormat WorldMap::format() const`, `const CellGraph* WorldMap::cell_graph() const` (nullptr on hex worlds). `WorldMap::load` dispatches on magic. All existing hex API (`cell_at`, `header`, `realm_name`, `province_name`) unchanged for hex worlds; on cell worlds `realm_name`/`province_name` answer from the cell graph.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_world_map.cpp` (add `#include "cellgraph_fixture.h"` at the top):

```cpp
TEST_CASE("WorldMap dispatches on file magic") {
    WorldMap map;
    write_fixture_hexbin("build/fixture.hexbin");
    REQUIRE(map.load("build/fixture.hexbin"));
    CHECK(map.format() == WorldFormat::Hex);
    CHECK(map.cell_graph() == nullptr);

    write_fixture_cellgraph("build/fixture.cellgraph");
    REQUIRE(map.load("build/fixture.cellgraph"));
    CHECK(map.format() == WorldFormat::CellGraph);
    REQUIRE(map.cell_graph() != nullptr);
    CHECK(map.cell_graph()->cells().size() == 3);
    CHECK(map.realm_name(1) == "Northreach");
    CHECK(map.province_name(1) == "Coldvale March");
    CHECK(map.cell_at(5, 0) == nullptr);   // hex API answers empty on cell worlds

    // loading a hex world again clears the cell backing
    REQUIRE(map.load("build/fixture.hexbin"));
    CHECK(map.format() == WorldFormat::Hex);
    CHECK(map.cell_graph() == nullptr);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: compile error `WorldFormat` not declared

- [ ] **Step 3: Write minimal implementation**

`src/core/world_map.h` — add `#include "core/cell_graph.h"` and `#include <memory>`; add inside namespace before `class WorldMap`:

```cpp
enum class WorldFormat { None, Hex, CellGraph };
```

Add to `WorldMap`'s public section:

```cpp
    WorldFormat format() const { return format_; }
    const CellGraph* cell_graph() const { return cell_graph_ ? cell_graph_.get() : nullptr; }
```

Add to the private section:

```cpp
    WorldFormat format_ = WorldFormat::None;
    std::unique_ptr<CellGraph> cell_graph_;
```

`src/core/world_map.cpp` — rename the existing body of `load` to a private helper by wrapping: change `bool WorldMap::load(const std::string& path) {` to `bool WorldMap::load_hexbin_(const std::vector<uint8_t>& buf) {` taking the already-read buffer (drop the `ifstream` block from it; it starts at `if (buf.size() < 72) return false;`), declare `bool load_hexbin_(const std::vector<uint8_t>&);` in the header's private section, and add the new dispatching `load`:

```cpp
bool WorldMap::load(const std::string& path) {
    loaded_ = false;
    format_ = WorldFormat::None;
    cell_graph_.reset();
    cells_.clear(); realm_names_.clear(); province_names_.clear();

    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)),
                              std::istreambuf_iterator<char>());
    if (buf.size() < 4) return false;

    if (std::memcmp(buf.data(), "HXB1", 4) == 0) {
        if (!load_hexbin_(buf)) return false;
        format_ = WorldFormat::Hex;
        loaded_ = true;
        return true;
    }
    if (std::memcmp(buf.data(), "CGB1", 4) == 0) {
        cell_graph_ = std::make_unique<CellGraph>();
        if (!cell_graph_->load(path)) { cell_graph_.reset(); return false; }
        format_ = WorldFormat::CellGraph;
        loaded_ = true;
        return true;
    }
    return false;
}
```

And route the name lookups through the backing:

```cpp
std::string WorldMap::realm_name(int realm_id) const {
    if (format_ == WorldFormat::CellGraph) return cell_graph_->realm_name(realm_id);
    auto it = realm_names_.find(realm_id);
    return it == realm_names_.end() ? "" : it->second;
}
std::string WorldMap::province_name(int province_id) const {
    if (format_ == WorldFormat::CellGraph) return cell_graph_->province_name(province_id);
    auto it = province_names_.find(province_id);
    return it == province_names_.end() ? "" : it->second;
}
```

(`load_hexbin_` keeps its own `loaded_ = true; return true;` removed — the dispatcher sets `loaded_`. Remove those two lines from the moved body and end it with `return true;`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: `Status: SUCCESS!` (27 cases)

- [ ] **Step 5: Commit**

```bash
cd ~/source/ironband
git add gdextension/src/core/world_map.h gdextension/src/core/world_map.cpp gdextension/tests/test_world_map.cpp
git commit -m "feat(engine): WorldMap dispatches hexbin/cellgraph on file magic"
```

---

### Task 5: Adjacency interface — neighbors + terrain for both backings

**Files:**
- Modify: `gdextension/src/core/world_map.h`
- Modify: `gdextension/src/core/world_map.cpp`
- Test: `gdextension/tests/test_world_map.cpp`

**Interfaces:**
- Produces (consumed by Tasks 6-8 and by the frontend plan):

```cpp
// Location ids: hex worlds pack axial coords; cell worlds use native cell ids.
inline int64_t hex_location(int q, int r) { return ((int64_t)q << 32) ^ (uint32_t)r; }
inline int hex_location_q(int64_t id) { return (int)(id >> 32); }
inline int hex_location_r(int64_t id) { return (int)(int32_t)(uint32_t)(id & 0xFFFFFFFFll); }

struct TerrainInfo {
    int biome_id = 0; bool is_water = false;
    int realm_id = 0, province_id = 0, burg_id = 0, elevation = 0;
};

std::vector<int64_t> WorldMap::location_neighbors(int64_t id) const;   // empty if unknown id
bool WorldMap::location_terrain(int64_t id, TerrainInfo& out) const;   // false if unknown id
```

- Hex backing: neighbors = the 6 axial offsets `(+1,0) (+1,-1) (0,-1) (-1,0) (-1,+1) (0,+1)`, filtered to hexes present in the file. Cell backing: the stored neighbor slice.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_world_map.cpp`:

```cpp
static void check_adjacency_contract(WorldMap& map, int64_t start_id) {
    // Contract (spec Testing Strategy): neighbor queries return valid ids,
    // every neighbor edge is mutual, and terrain resolves for every id.
    std::vector<int64_t> ns = map.location_neighbors(start_id);
    REQUIRE(!ns.empty());
    for (int64_t n : ns) {
        TerrainInfo t;
        CHECK(map.location_terrain(n, t));
        std::vector<int64_t> back = map.location_neighbors(n);
        CHECK(std::find(back.begin(), back.end(), start_id) != back.end());
    }
}

TEST_CASE("adjacency contract holds for the hex backing") {
    // fixture hexbin has cells (5,0) and (6,0) — axial neighbors of each other
    WorldMap map;
    write_fixture_hexbin("build/fixture.hexbin");
    REQUIRE(map.load("build/fixture.hexbin"));

    int64_t id = hex_location(5, 0);
    TerrainInfo t;
    REQUIRE(map.location_terrain(id, t));
    CHECK(t.biome_id == 1);
    CHECK(!t.is_water);
    CHECK(t.elevation == 42);

    std::vector<int64_t> ns = map.location_neighbors(id);
    REQUIRE(ns.size() == 1);               // only (6,0) exists in the fixture
    CHECK(ns[0] == hex_location(6, 0));
    check_adjacency_contract(map, id);

    CHECK(map.location_neighbors(hex_location(99, 99)).empty());
    CHECK(!map.location_terrain(hex_location(99, 99), t));
}

TEST_CASE("adjacency contract holds for the cell-graph backing") {
    WorldMap map;
    write_fixture_cellgraph("build/fixture.cellgraph");
    REQUIRE(map.load("build/fixture.cellgraph"));

    TerrainInfo t;
    REQUIRE(map.location_terrain(1, t));
    CHECK(t.biome_id == 1);
    CHECK(t.realm_id == 1);
    CHECK(t.elevation == 55);
    REQUIRE(map.location_terrain(2, t));
    CHECK(t.is_water);

    std::vector<int64_t> ns = map.location_neighbors(1);
    REQUIRE(ns.size() == 2);
    CHECK(ns[0] == 0);
    CHECK(ns[1] == 2);
    check_adjacency_contract(map, 1);

    CHECK(map.location_neighbors(999).empty());
}
```

Add `#include <algorithm>` at the top of `test_world_map.cpp`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: compile error `hex_location` / `TerrainInfo` not declared

- [ ] **Step 3: Write minimal implementation**

`src/core/world_map.h` — add inside the namespace (before `class WorldMap`), and declare the two methods in the public section:

```cpp
inline int64_t hex_location(int q, int r) { return ((int64_t)q << 32) ^ (uint32_t)r; }
inline int hex_location_q(int64_t id) { return (int)(id >> 32); }
inline int hex_location_r(int64_t id) { return (int)(int32_t)(uint32_t)(id & 0xFFFFFFFFll); }

struct TerrainInfo {
    int biome_id = 0;
    bool is_water = false;
    int realm_id = 0, province_id = 0, burg_id = 0, elevation = 0;
};
```

```cpp
    std::vector<int64_t> location_neighbors(int64_t id) const;
    bool location_terrain(int64_t id, TerrainInfo& out) const;
```

(`#include <vector>` at the top.) `src/core/world_map.cpp`:

```cpp
std::vector<int64_t> WorldMap::location_neighbors(int64_t id) const {
    std::vector<int64_t> out;
    if (format_ == WorldFormat::Hex) {
        static const int DQ[6] = { 1, 1, 0, -1, -1, 0 };
        static const int DR[6] = { 0, -1, -1, 0, 1, 1 };
        int q = hex_location_q(id), r = hex_location_r(id);
        if (!cell_at(q, r)) return out;
        for (int i = 0; i < 6; ++i) {
            int nq = q + DQ[i], nr = r + DR[i];
            if (cell_at(nq, nr)) out.push_back(hex_location(nq, nr));
        }
    } else if (format_ == WorldFormat::CellGraph) {
        const GraphCell* c = cell_graph_->cell((uint32_t)id);
        if (!c) return out;
        const uint32_t* ns = cell_graph_->neighbors(*c);
        for (int i = 0; i < c->neighbor_count; ++i) out.push_back((int64_t)ns[i]);
    }
    return out;
}

bool WorldMap::location_terrain(int64_t id, TerrainInfo& out) const {
    if (format_ == WorldFormat::Hex) {
        const HexCell* c = cell_at(hex_location_q(id), hex_location_r(id));
        if (!c) return false;
        out.biome_id = c->biome_id;
        out.is_water = c->biome_id == 0;
        out.realm_id = c->realm_id;
        out.province_id = c->province_id;
        out.burg_id = c->burg_id;
        out.elevation = c->elevation;
        return true;
    }
    if (format_ == WorldFormat::CellGraph) {
        const GraphCell* c = cell_graph_->cell((uint32_t)id);
        if (!c) return false;
        out.biome_id = c->biome_id;
        out.is_water = c->is_water;
        out.realm_id = c->realm_id;
        out.province_id = c->province_id;
        out.burg_id = c->burg_id;
        out.elevation = c->elevation;
        return true;
    }
    return false;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: `Status: SUCCESS!` (29 cases)

- [ ] **Step 5: Commit**

```bash
cd ~/source/ironband
git add gdextension/src/core/world_map.h gdextension/src/core/world_map.cpp gdextension/tests/test_world_map.cpp
git commit -m "feat(engine): location-id adjacency interface over both backings"
```

---

### Task 6: move_cost for both backings

**Files:**
- Modify: `gdextension/src/core/world_map.h`
- Modify: `gdextension/src/core/world_map.cpp`
- Test: `gdextension/tests/test_world_map.cpp`

**Interfaces:**
- Produces: `double WorldMap::move_cost(int64_t from, int64_t to) const` — game-hours to move between adjacent locations; `IMPASSABLE` for water destinations, unknown ids, or non-adjacent pairs on cell worlds. `void WorldMap::set_hours_per_unit(double)` / `double hours_per_unit() const` (default 1.0; the shared spec tuning constant, calibrated later).
- Hex: `terrain_cost_for_biome(dest.biome_id)` — identical numbers to today's engine `cost_fn`. Cell: `euclid(site_from, site_to) × terrain_cost_for_biome(dest.biome_id) × hours_per_unit_`, halved if the edge carries a road route.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_world_map.cpp` (add `#include "core/hex.h"` at the top for `IMPASSABLE`):

```cpp
TEST_CASE("move_cost: hex backing keeps the flat per-hex terrain model") {
    WorldMap map;
    write_fixture_hexbin("build/fixture.hexbin");
    REQUIRE(map.load("build/fixture.hexbin"));
    // fixture: both hexes biome 1 (Hot desert, x1.5)
    CHECK(map.move_cost(hex_location(5, 0), hex_location(6, 0)) == doctest::Approx(1.5));
    CHECK(map.move_cost(hex_location(5, 0), hex_location(99, 99)) == doctest::Approx(IMPASSABLE));
}

TEST_CASE("move_cost: cell backing scales with distance and roads halve it") {
    WorldMap map;
    write_fixture_cellgraph("build/fixture.cellgraph");
    REQUIRE(map.load("build/fixture.cellgraph"));
    map.set_hours_per_unit(0.2);

    // 0 -> 1: dist 10, biome 1 (x1.5), ROAD edge: 10 * 1.5 * 0.2 * 0.5 = 1.5
    CHECK(map.move_cost(0, 1) == doctest::Approx(1.5));
    // 1 -> 0 (reciprocal road edge): same cost
    CHECK(map.move_cost(1, 0) == doctest::Approx(1.5));
    // 1 -> 2: water destination
    CHECK(map.move_cost(1, 2) == doctest::Approx(IMPASSABLE));
    // 0 -> 2: not adjacent
    CHECK(map.move_cost(0, 2) == doctest::Approx(IMPASSABLE));
    CHECK(map.move_cost(0, 999) == doctest::Approx(IMPASSABLE));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: compile error `move_cost` not a member

- [ ] **Step 3: Write minimal implementation**

`src/core/world_map.h` — add `#include "core/hex.h"` (for `IMPASSABLE`, `terrain_cost_for_biome`); public section:

```cpp
    double move_cost(int64_t from, int64_t to) const;
    void set_hours_per_unit(double h) { hours_per_unit_ = h; }
    double hours_per_unit() const { return hours_per_unit_; }
```

Private: `double hours_per_unit_ = 1.0;`

`src/core/world_map.cpp` — add `#include <cmath>`:

```cpp
double WorldMap::move_cost(int64_t from, int64_t to) const {
    TerrainInfo dest;
    if (!location_terrain(to, dest)) return IMPASSABLE;
    if (dest.is_water) return IMPASSABLE;

    if (format_ == WorldFormat::Hex) {
        // Flat per-hex model (06-24 spec): every hex is the same size, so
        // distance collapses into the constant and cost = terrain multiplier.
        return terrain_cost_for_biome(dest.biome_id);
    }

    const GraphCell* a = cell_graph_->cell((uint32_t)from);
    const GraphCell* b = cell_graph_->cell((uint32_t)to);
    if (!a || !b) return IMPASSABLE;

    // must be adjacent; find the edge to read its route
    int edge = -1;
    const uint32_t* ns = cell_graph_->neighbors(*a);
    for (int i = 0; i < a->neighbor_count; ++i)
        if (ns[i] == b->id) { edge = i; break; }
    if (edge < 0) return IMPASSABLE;

    double dx = (double)b->cx - a->cx, dy = (double)b->cy - a->cy;
    double dist = std::sqrt(dx * dx + dy * dy);
    double cost = dist * terrain_cost_for_biome(dest.biome_id) * hours_per_unit_;

    uint16_t route = cell_graph_->edge_route(*a, edge);
    if (route != NO_ROUTE && cell_graph_->route_group(route) == RouteGroup::Road)
        cost *= 0.5;   // BB-derived road modifier (06-24 spec)
    return cost;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: `Status: SUCCESS!` (31 cases)

- [ ] **Step 5: Commit**

```bash
cd ~/source/ironband
git add gdextension/src/core/world_map.h gdextension/src/core/world_map.cpp gdextension/tests/test_world_map.cpp
git commit -m "feat(engine): move_cost — flat hex model + distance-weighted cell model with road halving"
```

---

### Task 7: PartyController over location ids

**Files:**
- Modify: `gdextension/src/core/party_controller.h`
- Modify: `gdextension/src/core/party_controller.cpp`
- Test: `gdextension/tests/test_party.cpp`
- Modify: `gdextension/src/ironband_engine.cpp` (compile-fix the call sites — full rewiring lands in Task 8)

**Interfaces:**
- Produces:

```cpp
class PartyController {
public:
    static constexpr double FATIGUE_PER_STEP = 5.0;   // was FATIGUE_PER_HEX
    void set_position(int64_t loc);
    int64_t position() const;
    void set_path(const std::vector<int64_t>& path);
    bool moving() const;
    double fatigue() const;
    int advance(double game_hours,
                const std::function<double(int64_t from, int64_t to)>& cost_fn,
                const std::function<bool(int64_t)>& on_location_entered);
};
```

`cost_fn` now takes `(from, to)` so callers can pass `WorldMap::move_cost` directly. Semantics of `advance` are otherwise unchanged (accumulate `carry_` hours until the next step's cost is paid; `on_location_entered` returning false pauses).

- [ ] **Step 1: Update the tests (mechanical Hex→id translation)**

In `tests/test_party.cpp`: replace every `Hex{q, r}` literal with `hex_location(q, r)` (add `#include "core/world_map.h"`), change `cost_fn` lambdas from `[](Hex h)` to `[](int64_t, int64_t)` (same returned values), `on_hex_entered` lambdas from `[](Hex h)` to `[](int64_t id)`, position comparisons from `CHECK(pc.position() == Hex{...})` to `CHECK(pc.position() == hex_location(...))`, and `FATIGUE_PER_HEX` to `FATIGUE_PER_STEP`. Keep every scenario and expected value identical — this is a type migration, not a behavior change.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: compile errors in `test_party.cpp` (signature mismatches)

- [ ] **Step 3: Write minimal implementation**

`src/core/party_controller.h`:

```cpp
#pragma once
#include <cstdint>
#include <functional>
#include <vector>

namespace ib {

class PartyController {
public:
    static constexpr double FATIGUE_PER_STEP = 5.0;

    void set_position(int64_t loc) { pos_ = loc; }
    int64_t position() const { return pos_; }

    void set_path(const std::vector<int64_t>& path) { path_ = path; idx_ = 0; carry_ = 0.0; }
    bool moving() const { return idx_ < path_.size(); }
    double fatigue() const { return fatigue_; }

    int advance(double game_hours,
                const std::function<double(int64_t, int64_t)>& cost_fn,
                const std::function<bool(int64_t)>& on_location_entered);

private:
    int64_t pos_ = 0;
    std::vector<int64_t> path_;
    size_t idx_ = 0;
    double carry_ = 0.0;     // game-hours accumulated toward the next step
    double fatigue_ = 0.0;
};

} // namespace ib
```

`src/core/party_controller.cpp`: apply the same mechanical migration to the 26-line implementation — `Hex next = path_[idx_]` becomes `int64_t next = path_[idx_]`, `cost_fn(next)` becomes `cost_fn(pos_, next)`, `FATIGUE_PER_HEX` → `FATIGUE_PER_STEP`; the hour-accumulation loop is otherwise unchanged.

`src/ironband_engine.cpp` — minimal compile fixes at the three call sites (full rewiring is Task 8):
- `set_party_position`: `party_.set_position(hex_location(q, r));`
- `get_party_position`: `int64_t id = party_.position(); return Vector2i(hex_location_q(id), hex_location_r(id));`
- `move_party`: build `std::vector<int64_t>` via `hex_location((int)v.x, (int)v.y)`.
- In `tick`: `Hex from_hex = party_.position();` becomes `int64_t from_id = party_.position();`; `cost_fn` becomes `[&](int64_t, int64_t to) -> double { const HexCell* c = map_.cell_at(hex_location_q(to), hex_location_r(to)); double mult = c ? terrain_cost_for_biome(c->biome_id) : 1.0; ... }` (keep the surrounding math identical); `on_entered` becomes `[&](int64_t id) { int q = hex_location_q(id), r = hex_location_r(id); ...existing body using q/r... }`.

- [ ] **Step 4: Run tests + build the extension to verify both compile**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: `Status: SUCCESS!`
Run: `cd ~/source/ironband/gdextension && scons target=template_debug 2>&1 | tail -3`
Expected: exit 0

- [ ] **Step 5: Commit**

```bash
cd ~/source/ironband
git add gdextension/src/core/party_controller.h gdextension/src/core/party_controller.cpp gdextension/tests/test_party.cpp gdextension/src/ironband_engine.cpp
git commit -m "refactor(engine): PartyController moves over location ids, cost_fn takes (from,to)"
```

---

### Task 8: IronbandEngine boundary — location_entered, get_location_info, cell queries

**Files:**
- Modify: `gdextension/src/ironband_engine.h`
- Modify: `gdextension/src/ironband_engine.cpp`

**Interfaces (consumed by the frontend cell-mode plan — subsystem 3):**
- Signal `location_entered(id: int, terrain: String, province: String, realm: String)` — emitted alongside the existing `hex_entered(q, r, ...)` (which stays until the frontend migrates; on cell worlds `hex_entered` is NOT emitted).
- `get_world_format() -> String` — `"hex"`, `"cellgraph"`, or `""`.
- `get_location_info(id: int) -> Dictionary` — biome_id/is_water/realm_id/province_id/burg_id/elevation/realm_name/province_name for either backing.
- `get_location_neighbors(id: int) -> PackedInt64Array`, `get_move_cost(from: int, to: int) -> float`, `set_hours_per_unit(h: float)`.
- Cell-world queries: `get_cell_ids() -> PackedInt64Array`, `get_cell_sites() -> PackedVector2Array` (same order as ids), `get_cell_polygon(id: int) -> PackedVector2Array` (border vertex positions, polygon order). Empty on hex worlds.
- `load_world` logs a neighbor-count histogram on cell worlds (spec Error-Handling requirement).

- [ ] **Step 1: Implement bindings**

`src/ironband_engine.h` — add to the public section:

```cpp
    godot::String get_world_format() const;
    godot::Dictionary get_location_info(int64_t id) const;
    godot::PackedInt64Array get_location_neighbors(int64_t id) const;
    double get_move_cost(int64_t from, int64_t to) const;
    void set_hours_per_unit(double h);
    godot::PackedInt64Array get_cell_ids() const;
    godot::PackedVector2Array get_cell_sites() const;
    godot::PackedVector2Array get_cell_polygon(int64_t id) const;
```

(add `#include <godot_cpp/variant/packed_int64_array.hpp>`.)

`src/ironband_engine.cpp` — in `_bind_methods()` add:

```cpp
    ClassDB::bind_method(D_METHOD("get_world_format"), &IronbandEngine::get_world_format);
    ClassDB::bind_method(D_METHOD("get_location_info", "id"), &IronbandEngine::get_location_info);
    ClassDB::bind_method(D_METHOD("get_location_neighbors", "id"), &IronbandEngine::get_location_neighbors);
    ClassDB::bind_method(D_METHOD("get_move_cost", "from", "to"), &IronbandEngine::get_move_cost);
    ClassDB::bind_method(D_METHOD("set_hours_per_unit", "h"), &IronbandEngine::set_hours_per_unit);
    ClassDB::bind_method(D_METHOD("get_cell_ids"), &IronbandEngine::get_cell_ids);
    ClassDB::bind_method(D_METHOD("get_cell_sites"), &IronbandEngine::get_cell_sites);
    ClassDB::bind_method(D_METHOD("get_cell_polygon", "id"), &IronbandEngine::get_cell_polygon);
    ADD_SIGNAL(MethodInfo("location_entered",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::STRING, "terrain"),
        PropertyInfo(Variant::STRING, "province"),
        PropertyInfo(Variant::STRING, "realm")));
```

Implementations:

```cpp
String IronbandEngine::get_world_format() const {
    switch (map_.format()) {
        case WorldFormat::Hex:       return "hex";
        case WorldFormat::CellGraph: return "cellgraph";
        default:                     return "";
    }
}

Dictionary IronbandEngine::get_location_info(int64_t id) const {
    Dictionary d;
    TerrainInfo t;
    if (!map_.location_terrain(id, t)) return d;
    d["id"] = id;
    d["biome_id"] = t.biome_id;
    d["is_water"] = t.is_water;
    d["realm_id"] = t.realm_id;
    d["province_id"] = t.province_id;
    d["burg_id"] = t.burg_id;
    d["elevation"] = t.elevation;
    d["realm_name"] = String(map_.realm_name(t.realm_id).c_str());
    d["province_name"] = String(map_.province_name(t.province_id).c_str());
    if (map_.format() == WorldFormat::Hex) {
        d["q"] = hex_location_q(id); d["r"] = hex_location_r(id);
    }
    return d;
}

PackedInt64Array IronbandEngine::get_location_neighbors(int64_t id) const {
    PackedInt64Array out;
    for (int64_t n : map_.location_neighbors(id)) out.push_back(n);
    return out;
}

double IronbandEngine::get_move_cost(int64_t from, int64_t to) const {
    return map_.move_cost(from, to);
}

void IronbandEngine::set_hours_per_unit(double h) { map_.set_hours_per_unit(h); }

PackedInt64Array IronbandEngine::get_cell_ids() const {
    PackedInt64Array out;
    const CellGraph* g = map_.cell_graph();
    if (!g) return out;
    for (const GraphCell& c : g->cells()) out.push_back((int64_t)c.id);
    return out;
}

PackedVector2Array IronbandEngine::get_cell_sites() const {
    PackedVector2Array out;
    const CellGraph* g = map_.cell_graph();
    if (!g) return out;
    for (const GraphCell& c : g->cells()) out.push_back(Vector2(c.cx, c.cy));
    return out;
}

PackedVector2Array IronbandEngine::get_cell_polygon(int64_t id) const {
    PackedVector2Array out;
    const CellGraph* g = map_.cell_graph();
    if (!g) return out;
    const GraphCell* c = g->cell((uint32_t)id);
    if (!c) return out;
    const uint32_t* b = g->border(*c);
    for (int i = 0; i < c->border_count; ++i) {
        float x = 0, y = 0;
        g->vertex(b[i], x, y);
        out.push_back(Vector2(x, y));
    }
    return out;
}
```

In `load_world`, after a successful load, log the histogram (add `#include <godot_cpp/variant/utility_functions.hpp>` if absent):

```cpp
bool IronbandEngine::load_world(const String& path) {
    bool ok = map_.load(path.utf8().get_data());
    if (ok && map_.format() == WorldFormat::CellGraph) {
        const CellGraph* g = map_.cell_graph();
        int hist[16] = {0};
        for (const GraphCell& c : g->cells())
            hist[c.neighbor_count < 15 ? c.neighbor_count : 15]++;
        String s = "IronbandEngine: cellgraph loaded, neighbor histogram:";
        for (int i = 0; i < 16; ++i)
            if (hist[i]) s += String(" {0}:{1}").format(Array::make(i, hist[i]));
        godot::UtilityFunctions::print(s);
    }
    return ok;
}
```

In `tick`'s `on_entered` lambda, emit both signals — after the existing `emit_signal("hex_entered", ...)` line (which must only fire on hex worlds), add:

```cpp
        emit_signal("location_entered", (int64_t)id, terrain, prov, realm);
```

and guard the hex one: `if (map_.format() == WorldFormat::Hex) emit_signal("hex_entered", q, r, terrain, prov, realm);`

- [ ] **Step 2: Build the extension**

Run: `cd ~/source/ironband/gdextension && scons target=template_debug 2>&1 | tail -3`
Expected: exit 0. Also run `cd tests && ./run.sh` — core suite still `Status: SUCCESS!`.

- [ ] **Step 3: Manual smoke in Godot (documented, not automated)**

Open the project in Godot 4.6, run the main scene, verify console shows no engine errors and hex-world behavior is unchanged (party moves, `hex_entered` HUD updates still work). This is a regression sanity check only.

- [ ] **Step 4: Commit**

```bash
cd ~/source/ironband
git add gdextension/src/ironband_engine.h gdextension/src/ironband_engine.cpp
git commit -m "feat(engine): location_entered boundary + cell query surface for frontend"
```

---

### Task 9: Real-data smoke — generate, commit, and load cheia's cell_graph.bin

**Files:**
- Create (ibp-engine repo): `worlds/cheia/cell_graph.bin` — generated, committed there.
- Test: `gdextension/tests/test_cell_graph.cpp` (real-data case, skips when file absent)

- [ ] **Step 1: Generate and commit the world file (ibp-engine)**

```bash
cd ~/source/ibp-engine
python3 tools/azgaar_to_cellgraph.py worlds/cheia/azgaar.json
git add worlds/cheia/cell_graph.bin
git commit -m "data: generate cheia cell_graph.bin (full-fidelity CGB1)"
```

Expected converter log: `cell_count=26924 merged_or_dropped=0 site_separation_violations=0`.

- [ ] **Step 2: Add the real-data test**

Add to `tests/test_cell_graph.cpp`:

```cpp
TEST_CASE("CellGraph loads the real cheia world when present") {
    const char* real = "/home/eric/source/ibp-engine/worlds/cheia/cell_graph.bin";
    if (!std::ifstream(real)) { MESSAGE("cheia cell_graph.bin absent — skipping"); return; }

    CellGraph g;
    REQUIRE(g.load(real));
    CHECK(g.header().cell_count == 26924);
    CHECK(g.meta().distance_scale == doctest::Approx(3.0));
    CHECK(g.meta().distance_unit == "mi");

    // every cell's neighbor slice stays in bounds and edges are mutual for
    // a sample of cells
    const GraphCell* c = g.cell(100);
    REQUIRE(c != nullptr);
    REQUIRE(c->neighbor_count > 0);
    for (int i = 0; i < c->neighbor_count; ++i) {
        const GraphCell* n = g.cell(g.neighbors(*c)[i]);
        REQUIRE(n != nullptr);
        bool mutual = false;
        for (int k = 0; k < n->neighbor_count; ++k)
            if (g.neighbors(*n)[k] == c->id) mutual = true;
        CHECK(mutual);
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd ~/source/ironband/gdextension/tests && ./run.sh`
Expected: `Status: SUCCESS!` (32 cases; the real-data case exercises the 26,924-cell file)

- [ ] **Step 4: Commit (ironband)**

```bash
cd ~/source/ironband
git add gdextension/tests/test_cell_graph.cpp
git commit -m "test(engine): load real cheia cell_graph.bin when present"
```

---

## Self-Review Notes

- **Spec coverage:** Architecture's "WorldMap loads either format behind one adjacency interface" → Tasks 4-5. `move_cost` formula → Task 6 (with `HOURS_PER_UNIT` left settable, per the 06-24 open question — deliberately not invented here). `location_entered`/`get_location_info` boundary → Task 8. Error-handling's "neighbor-count histogram at load" → Task 8; "world-format mismatch fails clearly" → magic dispatch (Task 4) returns false rather than misreading. Testing Strategy's "contract tests against both backings" → Task 5's `check_adjacency_contract` run on both fixtures. Variable-neighbor-count safety → the interface returns a variable-length vector; nothing exposes a 6-slot array.
- **Not covered (deferred by design):** pathfinding over the interface (no engine consumer yet — `move_party` still takes an explicit path), trigger-system location generalization beyond what `on_location_entered` already provides, rendering/hover (subsystem 3), `hours_per_unit` calibration (needs the 06-24 spec's time-scale resolution), retiring `hex_entered` (frontend migration, subsystem 3).
- **Placeholder scan:** clean — every code step has complete code; Task 7's test migration is mechanical with exact rules; Task 8's Godot smoke is explicitly manual-verification-only.
- **Type consistency:** `hex_location`/`hex_location_q`/`hex_location_r` defined once (Task 5) and used in Tasks 7-8; `TerrainInfo` fields match between Task 5 definition and Task 8 dictionary; `RouteGroup`/`NO_ROUTE` defined in Task 2, consumed in Task 6; fixture ids/values in Task 2 match every later task's assertions (cells 0/1/2, road edge 0↔1, elevations 40/55/0, realm "Northreach", province full-name "Coldvale March").
- **Latent-bug note:** Task 1's hexbin v2 fix is a prerequisite discovered during planning — the engine currently misparses every post-May world file; `elevation` is also needed by `TerrainInfo`.
