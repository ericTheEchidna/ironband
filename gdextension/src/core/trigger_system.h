#pragma once
#include "core/hex.h"
#include <cstdint>
#include <random>
#include <string>

namespace ib {

class WorldMap;

enum class TriggerType { None, Location, Border, Encounter, Event };

struct Trigger {
    TriggerType type = TriggerType::None;
    std::string payload;
};

class TriggerSystem {
public:
    explicit TriggerSystem(uint32_t seed) : rng_(seed) {}

    void set_encounter_chance(double c) { encounter_chance_ = c; }
    void set_event_chance(double c) { event_chance_ = c; }

    Trigger check(const WorldMap& map, Hex from, Hex to);

private:
    double roll() { return std::uniform_real_distribution<double>(0.0, 1.0)(rng_); }

    std::mt19937 rng_;
    double encounter_chance_ = 0.0;
    double event_chance_ = 0.0;
};

} // namespace ib
