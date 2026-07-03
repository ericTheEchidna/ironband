#include "doctest.h"
#include "core/world_map.h"
#include "hexbin_fixture.h"

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
