#include "core/world_sim.h"
#include "core/world_map.h"

namespace ib {

// Pointy-top axial neighbors.
static const Hex NEIGHBORS[6] = {
    {+1, 0}, {+1, -1}, {0, -1}, {-1, 0}, {-1, +1}, {0, +1}
};

void WorldSim::tick_day(const WorldMap& map) {
    ++days_;

    for (Patrol& p : patrols_) {
        // Collect passable neighbors (present in the map, not Marine biome 0).
        std::vector<Hex> options;
        for (const Hex& d : NEIGHBORS) {
            Hex n{ p.pos.q + d.q, p.pos.r + d.r };
            const HexCell* c = map.cell_at(n.q, n.r);
            if (c && c->biome_id != 0) options.push_back(n);
        }
        if (!options.empty()) {
            std::uniform_int_distribution<size_t> pick(0, options.size() - 1);
            p.pos = options[pick(rng_)];
        }
    }

    for (auto& kv : supply_) {
        std::uniform_real_distribution<double> drift(-0.05, 0.05);
        double v = kv.second + drift(rng_);
        if (v < 0.0) v = 0.0;
        if (v > 1.0) v = 1.0;
        kv.second = v;
    }
}

} // namespace ib
