#include "core/trigger_system.h"
#include "core/world_map.h"

namespace ib {

Trigger TriggerSystem::check(const WorldMap& map, Hex from, Hex to) {
    const HexCell* dst = map.cell_at(to.q, to.r);
    const HexCell* src = map.cell_at(from.q, from.r);

    // 1. Location: a settlement in the destination hex.
    if (dst && dst->burg_id > 0) {
        return Trigger{ TriggerType::Location,
                        "burg_id=" + std::to_string(dst->burg_id) };
    }

    // 2. Border: province or realm changes between two KNOWN hexes.
    if (dst && src) {
        if (dst->province_id != src->province_id && src->province_id != 0) {
            return Trigger{ TriggerType::Border,
                            "province=" + std::to_string(dst->province_id) };
        }
        if (dst->realm_id != src->realm_id && src->realm_id != 0) {
            return Trigger{ TriggerType::Border,
                            "realm=" + std::to_string(dst->realm_id) };
        }
    }

    // 3. Encounter roll.
    if (encounter_chance_ > 0.0 && roll() < encounter_chance_) {
        int realm = dst ? dst->realm_id : 0;
        return Trigger{ TriggerType::Encounter, "realm=" + std::to_string(realm) };
    }

    // 4. Event roll.
    if (event_chance_ > 0.0 && roll() < event_chance_) {
        return Trigger{ TriggerType::Event, "" };
    }

    return Trigger{ TriggerType::None, "" };
}

} // namespace ib
