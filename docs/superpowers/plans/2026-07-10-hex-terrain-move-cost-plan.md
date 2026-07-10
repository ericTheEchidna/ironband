# Hex-Terrain Move Cost Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make roads speed party march and rivers slow it in the live default `Hex`-format game, by loading `hex_terrain.bin` into `WorldMap` and using it in `move_cost()`.

**Architecture:** `WorldMap` (pure C++ core, no Godot deps) gains a second sidecar load — `hex_terrain.bin`, zipped against `hex_grid.hexbin`'s sequential hex order captured during the same load pass — and `move_cost()`'s `Hex` branch applies a road-discount or river-penalty multiplier (road wins, no stacking) using two new shared constants also adopted by the existing `CellGraph` branch.

**Tech Stack:** C++17, doctest (via `gdextension/tests/run.sh`), no Godot/GDExtension changes needed — `IronbandEngine::get_move_cost()` and the party-tick `cost_fn` already forward to `WorldMap::move_cost()`.

## Global Constraints

- `gdextension/src/core/*.cpp` has zero Godot dependencies (no `#include <godot_cpp/...>`) — do not add any. All logging/failure handling must be silent (matching `load_hexbin_`'s existing convention of returning `false` with no logging).
- Test command: `cd gdextension/tests && ./run.sh` — must end `[doctest] Status: SUCCESS!` with `0 failed` for both test cases and assertions. Baseline confirmed 2026-07-10: 32 test cases, 415 assertions, all passing before this plan's changes.
- Follow the existing code style in `world_map.cpp`/`hex.h` exactly (no exceptions, no `std::optional`, plain structs, `unordered_map` keyed by the existing `key(q,r)`/`hex_location(q,r)` bit-packing).

---

## Reference: design spec

Full rationale, background, and the two corrections made during brainstorming are in
`docs/superpowers/specs/2026-07-10-hex-terrain-move-cost-design.md`. Read it before
starting if anything below is unclear — this plan implements that spec exactly.

---

### Task 1: Load `hex_terrain.bin` and apply road/river cost in `WorldMap::move_cost()` (Hex format)

**Files:**
- Modify: `gdextension/src/core/hex.h`
- Modify: `gdextension/src/core/world_map.h`
- Modify: `gdextension/src/core/world_map.cpp`
- Create: `gdextension/tests/hex_terrain_fixture.h`
- Modify: `gdextension/tests/test_world_map.cpp`

**Interfaces:**
- Consumes: existing `WorldMap::load()`, `load_hexbin_()`, `move_cost()`, `key(q,r)` (all in `world_map.cpp`); existing `write_fixture_hexbin()` from `hexbin_fixture.h` (2 hexes: `(5,0)` and `(6,0)`, both biome 1 / cost 1.5, sequential order `(5,0)` then `(6,0)`).
- Produces: `ib::ROAD_COST_MULTIPLIER` (`double`, `0.5`) and `ib::RIVER_COST_MULTIPLIER` (`double`, `1.5`) in `hex.h`, for Task 2 to reuse. `WorldMap` gains a private `std::vector<int64_t> hex_order_` and `std::unordered_map<int64_t, HexTerrain> terrain_` — not consumed outside this file, `move_cost()` is the only reader.

- [ ] **Step 1: Add the shared cost constants to `hex.h`**

In `gdextension/src/core/hex.h`, change:

```cpp
constexpr double IMPASSABLE = 1e9;
```

to:

```cpp
constexpr double IMPASSABLE = 1e9;
constexpr double ROAD_COST_MULTIPLIER = 0.5;   // BB-derived road discount (06-24 spec)
constexpr double RIVER_COST_MULTIPLIER = 1.5;  // river-crossing penalty
```

- [ ] **Step 2: Add the `HexTerrain` struct and new `WorldMap` members/declaration**

In `gdextension/src/core/world_map.h`, after the `TerrainInfo` struct and before `class WorldMap {`, add:

```cpp
struct HexTerrain {
    uint16_t route_flags = 0;  // bit 0 = has_road, bit 6 = has_trail (hex-level, see hex_terrain.bin)
    uint16_t river_id = 0;     // 0 = no river
};
```

Then in `class WorldMap`'s `private:` section, change:

```cpp
private:
    static int64_t key(int q, int r) { return ((int64_t)q << 32) ^ (uint32_t)r; }
    bool load_hexbin_(const std::vector<uint8_t>& buf);

    bool loaded_ = false;
    double hours_per_unit_ = 1.0;
    WorldFormat format_ = WorldFormat::None;
    std::unique_ptr<CellGraph> cell_graph_;
    WorldHeader header_;
    std::unordered_map<int64_t, HexCell> cells_;
    std::unordered_map<int, std::string> realm_names_;
    std::unordered_map<int, std::string> province_names_;
};
```

to:

```cpp
private:
    static int64_t key(int q, int r) { return ((int64_t)q << 32) ^ (uint32_t)r; }
    bool load_hexbin_(const std::vector<uint8_t>& buf);
    bool load_hex_terrain_(const std::string& hexbin_path);

    bool loaded_ = false;
    double hours_per_unit_ = 1.0;
    WorldFormat format_ = WorldFormat::None;
    std::unique_ptr<CellGraph> cell_graph_;
    WorldHeader header_;
    std::unordered_map<int64_t, HexCell> cells_;
    std::vector<int64_t> hex_order_;                    // (q,r) keys, hex_grid.hexbin sequential order
    std::unordered_map<int64_t, HexTerrain> terrain_;    // keyed same as cells_/hex_order_ entries
    std::unordered_map<int, std::string> realm_names_;
    std::unordered_map<int, std::string> province_names_;
};
```

- [ ] **Step 3: Write the failing tests**

Create `gdextension/tests/hex_terrain_fixture.h`:

```cpp
#pragma once
#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

// Writes a minimal hex_terrain.bin (HXT1) with exactly 2 records, matching
// write_fixture_hexbin's 2 hexes in sequential order: record 0 = (5,0), record 1 = (6,0).
// Only route_flags/river_id are meaningful for move_cost tests; other fields are zeroed.
inline std::string write_fixture_hex_terrain(
        const std::string& path,
        uint16_t route_flags_0, uint16_t river_id_0,
        uint16_t route_flags_1, uint16_t river_id_1) {
    auto u16 = [](std::vector<uint8_t>& b, uint16_t v){ b.push_back(v&0xFF); b.push_back((v>>8)&0xFF); };
    auto u32 = [](std::vector<uint8_t>& b, uint32_t v){ for(int i=0;i<4;i++) b.push_back((v>>(8*i))&0xFF); };

    std::vector<uint8_t> body;
    body.push_back('H'); body.push_back('X'); body.push_back('T'); body.push_back('1');
    u16(body, 1);   // version
    u32(body, 2);   // hex_count

    auto rec = [&](uint16_t route_flags, uint16_t river_id) {
        body.push_back(0);            // height (unused by move_cost)
        body.push_back(0);            // type_flags (unused)
        u16(body, 0);                 // culture_id (unused)
        u16(body, 0);                 // religion_id (unused)
        u16(body, 0);                 // river_flow (unused)
        u16(body, river_id);
        u16(body, route_flags);
    };
    rec(route_flags_0, river_id_0);
    rec(route_flags_1, river_id_1);

    std::ofstream f(path, std::ios::binary);
    f.write((const char*)body.data(), (std::streamsize)body.size());
    f.close();
    return path;
}
```

In `gdextension/tests/test_world_map.cpp`, add `#include <filesystem>` to the top
of the includes, and add these four `TEST_CASE`s after the existing
`"move_cost: hex backing keeps the flat per-hex terrain model"` test (around
line 129):

```cpp
TEST_CASE("move_cost: hex backing applies road discount from hex_terrain.bin") {
    WorldMap map;
    write_fixture_hexbin("build/fixture.hexbin");
    write_fixture_hex_terrain("build/hex_terrain.bin", 0, 0, /*route1*/0x1, /*river1*/0);
    REQUIRE(map.load("build/fixture.hexbin"));
    // dest (6,0): biome 1.5 * road 0.5 = 0.75
    CHECK(map.move_cost(hex_location(5, 0), hex_location(6, 0)) == doctest::Approx(0.75));
}

TEST_CASE("move_cost: hex backing applies river penalty from hex_terrain.bin") {
    WorldMap map;
    write_fixture_hexbin("build/fixture.hexbin");
    write_fixture_hex_terrain("build/hex_terrain.bin", 0, 0, /*route1*/0, /*river1*/7);
    REQUIRE(map.load("build/fixture.hexbin"));
    // dest (6,0): biome 1.5 * river 1.5 = 2.25
    CHECK(map.move_cost(hex_location(5, 0), hex_location(6, 0)) == doctest::Approx(2.25));
}

TEST_CASE("move_cost: hex backing prefers road over river when both present (bridge)") {
    WorldMap map;
    write_fixture_hexbin("build/fixture.hexbin");
    write_fixture_hex_terrain("build/hex_terrain.bin", 0, 0, /*route1*/0x1, /*river1*/7);
    REQUIRE(map.load("build/fixture.hexbin"));
    CHECK(map.move_cost(hex_location(5, 0), hex_location(6, 0)) == doctest::Approx(0.75));
}

TEST_CASE("move_cost: hex backing falls back to flat cost when hex_terrain.bin is missing") {
    std::filesystem::create_directories("build/no_terrain");
    write_fixture_hexbin("build/no_terrain/fixture.hexbin");
    WorldMap map;
    REQUIRE(map.load("build/no_terrain/fixture.hexbin"));
    CHECK(map.move_cost(hex_location(5, 0), hex_location(6, 0)) == doctest::Approx(1.5));
}
```

Also add `#include "hex_terrain_fixture.h"` next to the existing
`#include "hexbin_fixture.h"` at the top of `test_world_map.cpp`.

- [ ] **Step 4: Run the tests to verify the new ones fail**

Run: `cd gdextension/tests && ./run.sh`
Expected: the 4 new test cases FAIL (0.75/2.25 expected but flat 1.5 returned;
the "missing" case should already PASS since it degrades to today's existing
behavior — that's fine, it's asserting current behavior stays correct).

- [ ] **Step 5: Implement `load_hex_terrain_` and wire it into `load()`/`load_hexbin_`**

In `gdextension/src/core/world_map.cpp`, in `WorldMap::load()`, change:

```cpp
    cell_graph_.reset();
    cells_.clear(); realm_names_.clear(); province_names_.clear();
```

to:

```cpp
    cell_graph_.reset();
    cells_.clear(); realm_names_.clear(); province_names_.clear();
    hex_order_.clear(); terrain_.clear();
```

Then change:

```cpp
    if (std::memcmp(buf.data(), "HXB1", 4) == 0) {
        if (!load_hexbin_(buf)) return false;
        format_ = WorldFormat::Hex;
        loaded_ = true;
        return true;
    }
```

to:

```cpp
    if (std::memcmp(buf.data(), "HXB1", 4) == 0) {
        if (!load_hexbin_(buf)) return false;
        load_hex_terrain_(path);  // best-effort; missing/bad file just leaves terrain_ empty
        format_ = WorldFormat::Hex;
        loaded_ = true;
        return true;
    }
```

In `load_hexbin_`'s hex-record loop, change:

```cpp
        pos += rec_size;
        cells_[key(c.q, c.r)] = c;
    }

    return true;
}
```

to:

```cpp
        pos += rec_size;
        cells_[key(c.q, c.r)] = c;
        hex_order_.push_back(key(c.q, c.r));
    }

    return true;
}
```

Then add the new method right after `load_hexbin_`'s closing brace:

```cpp
bool WorldMap::load_hex_terrain_(const std::string& hexbin_path) {
    size_t slash = hexbin_path.find_last_of("/\\");
    std::string dir = slash == std::string::npos ? std::string() : hexbin_path.substr(0, slash + 1);
    std::string path = dir + "hex_terrain.bin";

    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)),
                              std::istreambuf_iterator<char>());
    if (buf.size() < 10 || std::memcmp(buf.data(), "HXT1", 4) != 0) return false;

    uint32_t hex_count = rd_u32(buf.data() + 6);
    if (hex_count != hex_order_.size()) return false;

    const size_t rec_size = 12;
    size_t pos = 10;
    if (pos + (size_t)hex_count * rec_size > buf.size()) return false;

    for (uint32_t i = 0; i < hex_count; ++i) {
        const uint8_t* p = buf.data() + pos;
        HexTerrain t;
        t.river_id    = rd_u16(p + 8);
        t.route_flags = rd_u16(p + 10);
        terrain_[hex_order_[i]] = t;
        pos += rec_size;
    }
    return true;
}
```

- [ ] **Step 6: Apply road/river cost in `move_cost()`'s Hex branch**

In `gdextension/src/core/world_map.cpp`, change:

```cpp
    if (format_ == WorldFormat::Hex) {
        // Flat per-hex model (06-24 spec): every hex is the same size, so
        // distance collapses into the constant and cost = terrain multiplier.
        return terrain_cost_for_biome(dest.biome_id);
    }
```

to:

```cpp
    if (format_ == WorldFormat::Hex) {
        // Flat per-hex model (06-24 spec): every hex is the same size, so
        // distance collapses into the constant and cost = terrain multiplier.
        double cost = terrain_cost_for_biome(dest.biome_id);
        auto it = terrain_.find(to);
        if (it != terrain_.end()) {
            bool has_road  = (it->second.route_flags & 0x1) != 0;
            bool has_river = it->second.river_id > 0;
            if (has_road)       cost *= ROAD_COST_MULTIPLIER;
            else if (has_river) cost *= RIVER_COST_MULTIPLIER;
        }
        return cost;
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd gdextension/tests && ./run.sh`
Expected: all test cases pass, including the 4 new ones and all pre-existing
ones (in particular `"move_cost: hex backing keeps the flat per-hex terrain
model"` must still pass unchanged — it has no `hex_terrain.bin` sibling for its
`build/fixture.hexbin` path unless a prior test in the same run wrote one, so
verify this test still passes when run as part of the full suite, not just in
isolation).

- [ ] **Step 8: Commit**

```bash
git add gdextension/src/core/hex.h gdextension/src/core/world_map.h \
        gdextension/src/core/world_map.cpp gdextension/tests/hex_terrain_fixture.h \
        gdextension/tests/test_world_map.cpp
git commit -m "$(cat <<'EOF'
feat: load hex_terrain.bin and apply road/river move cost in Hex format

WorldMap's live default Hex-format move_cost() was a flat per-biome cost with
no awareness of hex_terrain.bin at all, so roads rendered without speeding
travel and rivers rendered without slowing it. Loads the sidecar (zipped
against hex_grid.hexbin's sequential order) and applies a road discount or
river penalty, with road taking precedence (bridge behavior).

Closes remaining scope of IRONBAND-044/IRONBAND-045.
EOF
)"
```

---

### Task 2: Share the road-cost constant with the CellGraph path, fix stale GDScript doc comment

**Files:**
- Modify: `gdextension/src/core/world_map.cpp`
- Modify: `scripts/loaders/HexTerrainLoader.gd`

**Interfaces:**
- Consumes: `ib::ROAD_COST_MULTIPLIER` from `hex.h` (added in Task 1).
- Produces: nothing new consumed elsewhere; this task is cleanup only.

- [ ] **Step 1: Point the CellGraph branch's inline literal at the shared constant**

In `gdextension/src/core/world_map.cpp`, in `WorldMap::move_cost()`'s `CellGraph`
branch, change:

```cpp
    uint16_t route = cell_graph_->edge_route(*a, edge);
    if (route != NO_ROUTE && cell_graph_->route_group(route) == RouteGroup::Road)
        cost *= 0.5;   // BB-derived road modifier (06-24 spec)
    return cost;
```

to:

```cpp
    uint16_t route = cell_graph_->edge_route(*a, edge);
    if (route != NO_ROUTE && cell_graph_->route_group(route) == RouteGroup::Road)
        cost *= ROAD_COST_MULTIPLIER;
    return cost;
```

- [ ] **Step 2: Run the full test suite to confirm no regression**

Run: `cd gdextension/tests && ./run.sh`
Expected: all tests pass, in particular the existing `"move_cost: cell backing
scales with distance and roads halve it"` test (its expected value `1.5` was
derived from the `0.5` literal — `ROAD_COST_MULTIPLIER` is also `0.5`, so this
is a pure refactor with no behavior change, and this test is what proves it).

- [ ] **Step 3: Fix the stale doc comment in `HexTerrainLoader.gd`**

In `scripts/loaders/HexTerrainLoader.gd`, change:

```gdscript
## type_flags bits: 0=harbor 2=coastal 3=ocean (bit 1 unused — "port" is a
## burg attribute, not a per-hex one; see BurgLoader.Burg.is_port())
## route_flags bits: 0-5=road on edge N/NE/SE/S/SW/NW, 6-11=trail on same edges,
##                   12=ferry (searoute) present (non-directional)
```

to:

```gdscript
## type_flags bits: 0=harbor 2=coastal 3=ocean (bit 1 unused — "port" is a
## burg attribute, not a per-hex one; see BurgLoader.Burg.is_port())
## route_flags bits: bit 0 = has_road, bit 6 = has_trail — both are HEX-LEVEL
##                   booleans ("does any road/trail touch this hex"), not
##                   per-edge-direction data. azgaar_to_hex.py's writer never
##                   sets bits 1-5 or 7-11, so has_road_on_dir(d)/
##                   has_trail_on_dir(d) below only ever return true for d=0.
##                   Bit 12 (ferry) is likewise never set by the current
##                   writer — has_ferry() always returns false today.
```

This is a comment-only change — no behavior difference, confirmed by checking
all three call sites (`CombatMap.gd:119-120`, `RegionMap.gd:1424-1425,1428,2691`)
already loop over all 6 directions and OR the results, so they already only
rely on the `d=0` bit firing correctly, which is unaffected.

- [ ] **Step 4: Commit**

```bash
git add gdextension/src/core/world_map.cpp scripts/loaders/HexTerrainLoader.gd
git commit -m "$(cat <<'EOF'
refactor: share ROAD_COST_MULTIPLIER constant, fix stale route_flags doc comment

CellGraph branch's inline 0.5 literal now references the same constant the
Hex branch uses (pure refactor, existing test proves no behavior change).
HexTerrainLoader.gd's doc comment claimed per-edge-direction road/trail bits
and a ferry bit that azgaar_to_hex.py's writer never actually sets — corrected
to describe the real hex-level-only data.
EOF
)"
```

---

## Done When

- Both tasks committed.
- `cd gdextension/tests && ./run.sh` passes in full, including the 4 new
  road/river/bridge/missing-file test cases.
- Marching along a road hex costs less than the flat biome cost; entering a
  river hex without a road costs more; a road on a river hex costs the road
  rate.
- No Godot/GDExtension rebuild is required to verify this (pure `core/` change,
  tested via the doctest harness) — but if you want to confirm end-to-end,
  `cd gdextension && scons target=template_debug` must still build clean.
