#include "core/party_controller.h"

namespace ib {

int PartyController::advance(double game_hours,
                            const std::function<double(int64_t, int64_t)>& cost_fn,
                            const std::function<bool(int64_t)>& on_location_entered) {
    int entered = 0;
    carry_ += game_hours;
    while (idx_ < path_.size()) {
        int64_t next = path_[idx_];
        double cost = cost_fn(pos_, next);
        if (cost <= 0.0) cost = 0.0001;
        if (carry_ < cost) break;
        carry_ -= cost;
        pos_ = next;
        ++idx_;
        ++entered;
        fatigue_ += FATIGUE_PER_STEP;
        if (!on_location_entered(next)) break;
    }
    if (idx_ >= path_.size()) { path_.clear(); idx_ = 0; carry_ = 0.0; }
    return entered;
}

} // namespace ib
