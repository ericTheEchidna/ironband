#include "doctest.h"
#include "core/party_controller.h"
#include <vector>

using namespace ib;

// Flat cost: every hex costs 4 game-hours.
static double flat_cost(Hex) { return 4.0; }

TEST_CASE("advance steps through hexes as time is spent") {
    PartyController p;
    p.set_position(Hex{0, 0});
    p.set_path({Hex{1, 0}, Hex{2, 0}, Hex{3, 0}});
    CHECK(p.moving());

    std::vector<Hex> entered;
    int n = p.advance(8.0, flat_cost, [&](Hex h){ entered.push_back(h); return true; });
    CHECK(n == 2);                       // 8 hours / 4 per hex
    CHECK(p.position() == Hex{2, 0});
    CHECK(p.fatigue() == doctest::Approx(10.0));
    CHECK(p.moving());                   // one hex remains
}

TEST_CASE("callback returning false halts movement (auto-pause)") {
    PartyController p;
    p.set_position(Hex{0, 0});
    p.set_path({Hex{1, 0}, Hex{2, 0}, Hex{3, 0}});

    int n = p.advance(100.0, flat_cost, [&](Hex h){ return h != Hex{2, 0}; });
    CHECK(n == 2);                       // entered (1,0) and (2,0), then stopped
    CHECK(p.position() == Hex{2, 0});
    CHECK(p.moving());                   // (3,0) still queued
}

TEST_CASE("path completes and party stops moving") {
    PartyController p;
    p.set_position(Hex{0, 0});
    p.set_path({Hex{1, 0}});
    int n = p.advance(100.0, flat_cost, [&](Hex){ return true; });
    CHECK(n == 1);
    CHECK_FALSE(p.moving());
}
