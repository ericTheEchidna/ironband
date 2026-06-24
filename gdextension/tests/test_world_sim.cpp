#include "doctest.h"
#include "core/world_sim.h"
#include "core/world_map.h"
#include "hexbin_fixture.h"

using namespace ib;

static WorldMap load_fixture() {
    write_fixture_hexbin("build/sim_fixture.hexbin");
    WorldMap m; m.load("build/sim_fixture.hexbin"); return m;
}

TEST_CASE("tick_day advances the day counter") {
    WorldMap m = load_fixture();
    WorldSim s(7);
    s.tick_day(m);
    s.tick_day(m);
    CHECK(s.days_elapsed() == 2);
}

TEST_CASE("patrol wander is deterministic for a seed") {
    WorldMap m = load_fixture();
    WorldSim a(99); a.add_patrol(1, Hex{5, 0}, 1);
    WorldSim b(99); b.add_patrol(1, Hex{5, 0}, 1);
    for (int i = 0; i < 5; ++i) { a.tick_day(m); b.tick_day(m); }
    CHECK(a.patrols()[0].pos == b.patrols()[0].pos);
}

TEST_CASE("market supply drifts but stays within [0,1]") {
    WorldMap m = load_fixture();
    WorldSim s(3);
    s.track_market(1);
    for (int i = 0; i < 50; ++i) s.tick_day(m);
    double sup = s.market_supply(1);
    CHECK(sup >= 0.0);
    CHECK(sup <= 1.0);
}
