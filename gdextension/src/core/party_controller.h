#pragma once
#include <cstdint>
#include <functional>
#include <vector>

namespace ib {

class PartyController {
public:
    static constexpr double FATIGUE_PER_STEP = 5.0;

    void set_position(int64_t loc) { pos_ = loc; }
    int64_t position() const { return pos_; }

    void set_path(const std::vector<int64_t>& path) { path_ = path; idx_ = 0; carry_ = 0.0; }
    bool moving() const { return idx_ < path_.size(); }
    double fatigue() const { return fatigue_; }

    int advance(double game_hours,
                const std::function<double(int64_t, int64_t)>& cost_fn,
                const std::function<bool(int64_t)>& on_location_entered);

private:
    int64_t pos_ = 0;
    std::vector<int64_t> path_;
    size_t idx_ = 0;
    double carry_ = 0.0;     // game-hours accumulated toward the next step
    double fatigue_ = 0.0;
};

} // namespace ib
