#pragma once
#include "core/hex.h"
#include <functional>
#include <vector>

namespace ib {

class PartyController {
public:
    static constexpr double FATIGUE_PER_HEX = 5.0;

    void set_position(Hex h) { pos_ = h; }
    Hex  position() const { return pos_; }

    void set_path(const std::vector<Hex>& path) { path_ = path; idx_ = 0; carry_ = 0.0; }
    bool moving() const { return idx_ < path_.size(); }
    double fatigue() const { return fatigue_; }

    int advance(double game_hours,
                const std::function<double(Hex)>& cost_fn,
                const std::function<bool(Hex)>& on_hex_entered);

private:
    Hex pos_;
    std::vector<Hex> path_;
    size_t idx_ = 0;
    double carry_ = 0.0;     // game-hours accumulated toward the next hex
    double fatigue_ = 0.0;
};

} // namespace ib
