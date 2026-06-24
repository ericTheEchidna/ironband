#include "core/world_clock.h"

namespace ib {

int WorldClock::advance(double real_seconds) {
    if (scale_ == 0.0 || real_seconds <= 0.0) return 0;
    int day_before = game_day();
    hours_ += real_seconds * HOURS_PER_SECOND * scale_;
    return game_day() - day_before;
}

} // namespace ib
