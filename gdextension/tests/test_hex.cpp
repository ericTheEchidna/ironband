#include "doctest.h"
#include "core/hex.h"

using namespace ib;

TEST_CASE("hex_to_world matches pointy-top axial formula") {
    Vec2 w = hex_to_world(Hex{2, 3}, 10.0, 0.0, 0.0);
    // x = 10*sqrt(3)*(2 + 1.5) = 10*1.7320508*3.5 = 60.621...
    CHECK(w.x == doctest::Approx(60.6217782649));
    CHECK(w.y == doctest::Approx(45.0)); // 10*1.5*3
}

TEST_CASE("world_to_hex is the inverse of hex_to_world") {
    for (int q = -5; q <= 5; ++q)
        for (int r = -5; r <= 5; ++r) {
            Vec2 w = hex_to_world(Hex{q, r}, 12.0, 100.0, -50.0);
            Hex back = world_to_hex(w, 12.0, 100.0, -50.0);
            CHECK(back.q == q);
            CHECK(back.r == r);
        }
}

TEST_CASE("terrain cost: grassland cheap, glacier costly, marine impassable") {
    CHECK(terrain_cost_for_biome(4) == doctest::Approx(1.0));   // grassland
    CHECK(terrain_cost_for_biome(12) == doctest::Approx(2.0));  // wetland
    CHECK(terrain_cost_for_biome(11) == doctest::Approx(2.5));  // glacier
    CHECK(terrain_cost_for_biome(0) > 1e8);                     // marine impassable
}
