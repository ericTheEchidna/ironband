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
