#include "doctest.h"
#include "core/world_clock.h"

using namespace ib;

TEST_CASE("advance accumulates game-hours scaled by HOURS_PER_SECOND and scale") {
    WorldClock c;
    c.set_scale(1.0);
    c.advance(1.0); // 1 real second
    CHECK(c.game_hours() == doctest::Approx(WorldClock::HOURS_PER_SECOND));
}

TEST_CASE("paused clock does not advance") {
    WorldClock c;
    c.pause();
    CHECK(c.paused());
    c.advance(10.0);
    CHECK(c.game_hours() == doctest::Approx(0.0));
}

TEST_CASE("advance reports day boundaries crossed") {
    WorldClock c;
    c.set_scale(1.0); // 4 game-hours/sec → 6 real-sec per game-day
    int d0 = c.advance(6.0);  // exactly 24 game-hours
    CHECK(d0 == 1);
    CHECK(c.game_day() == 1);
    int d1 = c.advance(12.0); // +48 game-hours → 2 more days
    CHECK(d1 == 2);
    CHECK(c.game_day() == 3);
}

TEST_CASE("game_hour_of_day wraps within 24") {
    WorldClock c;
    c.set_scale(1.0);
    c.advance(7.0); // 28 game-hours
    CHECK(c.game_day() == 1);
    CHECK(c.game_hour_of_day() == doctest::Approx(4.0));
}
