#pragma once
#include "core/hex.h"
#include <cstdint>
#include <random>
#include <unordered_map>
#include <vector>

namespace ib {

class WorldMap;

struct Patrol {
    int id = 0;
    Hex pos;
    int realm_id = 0;
};

class WorldSim {
public:
    explicit WorldSim(uint32_t seed) : rng_(seed) {}

    void add_patrol(int id, Hex start, int realm_id) {
        patrols_.push_back(Patrol{ id, start, realm_id });
    }
    void track_market(int burg_id) {
        if (!supply_.count(burg_id)) supply_[burg_id] = 0.5;
    }

    void tick_day(const WorldMap& map);

    const std::vector<Patrol>& patrols() const { return patrols_; }
    double market_supply(int burg_id) const {
        auto it = supply_.find(burg_id);
        return it == supply_.end() ? 0.5 : it->second;
    }
    int days_elapsed() const { return days_; }

private:
    std::mt19937 rng_;
    std::vector<Patrol> patrols_;
    std::unordered_map<int, double> supply_;
    int days_ = 0;
};

} // namespace ib
