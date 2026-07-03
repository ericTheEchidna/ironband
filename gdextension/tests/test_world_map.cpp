#include "doctest.h"
#include "core/world_map.h"
#include "hexbin_fixture.h"
#include "cellgraph_fixture.h"
#include <algorithm>

using namespace ib;

TEST_CASE("WorldMap loads header, cells, and names from hexbin") {
    std::string path = "build/fixture.hexbin";
    write_fixture_hexbin(path);

    WorldMap map;
    REQUIRE(map.load(path));
    REQUIRE(map.loaded());

    const WorldHeader& h = map.header();
    CHECK(h.hex_count == 2);
    CHECK(h.hex_size == doctest::Approx(10.0));
    CHECK(h.origin_x == doctest::Approx(100.0));
    CHECK(h.map_w == doctest::Approx(400.0));

    const HexCell* c = map.cell_at(5, 0);
    REQUIRE(c != nullptr);
    CHECK(c->biome_id == 1);
    CHECK(c->realm_id == 1);
    CHECK(c->province_id == 1);
    CHECK(c->elevation == 42);

    CHECK(map.cell_at(999, 999) == nullptr);
    CHECK(map.realm_name(1) == "Northreach");
    CHECK(map.province_name(1) == "Coldvale");
}

TEST_CASE("WorldMap rejects a bad magic") {
    std::ofstream f("build/bad.hexbin", std::ios::binary);
    f << "XXXX"; f.close();
    WorldMap map;
    CHECK_FALSE(map.load("build/bad.hexbin"));
}

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
