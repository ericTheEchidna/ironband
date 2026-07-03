#include "ironband_engine.h"
#include "core/hex.h"
#include <godot_cpp/core/class_db.hpp>
#include <memory>

using namespace godot;

namespace ib {

IronbandEngine::IronbandEngine() {
    triggers_ = std::make_unique<TriggerSystem>(1337u);
    triggers_->set_encounter_chance(0.05);
    triggers_->set_event_chance(0.02);
    sim_ = std::make_unique<WorldSim>(1337u);
}

void IronbandEngine::_bind_methods() {
    ClassDB::bind_method(D_METHOD("ping"), &IronbandEngine::ping);
    ClassDB::bind_method(D_METHOD("load_world", "path"), &IronbandEngine::load_world);
    ClassDB::bind_method(D_METHOD("move_party", "path"), &IronbandEngine::move_party);
    ClassDB::bind_method(D_METHOD("set_time_scale", "s"), &IronbandEngine::set_time_scale);
    ClassDB::bind_method(D_METHOD("resume"), &IronbandEngine::resume);
    ClassDB::bind_method(D_METHOD("set_party_position", "q", "r"), &IronbandEngine::set_party_position);
    ClassDB::bind_method(D_METHOD("get_party_position"), &IronbandEngine::get_party_position);
    ClassDB::bind_method(D_METHOD("get_hex_info", "q", "r"), &IronbandEngine::get_hex_info);
    ClassDB::bind_method(D_METHOD("get_game_time"), &IronbandEngine::get_game_time);
    ClassDB::bind_method(D_METHOD("tick", "delta"), &IronbandEngine::tick);
    ClassDB::bind_method(D_METHOD("get_world_format"), &IronbandEngine::get_world_format);
    ClassDB::bind_method(D_METHOD("get_location_info", "id"), &IronbandEngine::get_location_info);
    ClassDB::bind_method(D_METHOD("get_location_neighbors", "id"), &IronbandEngine::get_location_neighbors);
    ClassDB::bind_method(D_METHOD("get_move_cost", "from", "to"), &IronbandEngine::get_move_cost);
    ClassDB::bind_method(D_METHOD("set_hours_per_unit", "h"), &IronbandEngine::set_hours_per_unit);
    ClassDB::bind_method(D_METHOD("get_cell_ids"), &IronbandEngine::get_cell_ids);
    ClassDB::bind_method(D_METHOD("get_cell_sites"), &IronbandEngine::get_cell_sites);
    ClassDB::bind_method(D_METHOD("get_cell_polygon", "id"), &IronbandEngine::get_cell_polygon);

    ADD_SIGNAL(MethodInfo("hex_entered",
        PropertyInfo(Variant::INT, "q"), PropertyInfo(Variant::INT, "r"),
        PropertyInfo(Variant::INT, "terrain_id"), PropertyInfo(Variant::INT, "province_id"),
        PropertyInfo(Variant::INT, "realm_id")));
    ADD_SIGNAL(MethodInfo("location_entered",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::STRING, "terrain"),
        PropertyInfo(Variant::STRING, "province"),
        PropertyInfo(Variant::STRING, "realm")));
    ADD_SIGNAL(MethodInfo("encounter_triggered",
        PropertyInfo(Variant::STRING, "type"), PropertyInfo(Variant::STRING, "payload")));
    ADD_SIGNAL(MethodInfo("clock_ticked",
        PropertyInfo(Variant::INT, "game_day"), PropertyInfo(Variant::FLOAT, "game_hour")));
    ADD_SIGNAL(MethodInfo("time_scale_changed", PropertyInfo(Variant::FLOAT, "scale")));
    ADD_SIGNAL(MethodInfo("world_tick_completed", PropertyInfo(Variant::INT, "game_day")));
}

String IronbandEngine::ping() const {
    return String("ironband-engine-ok");
}

bool IronbandEngine::load_world(const String& path) {
    bool ok = map_.load(path.utf8().get_data());
    if (ok && map_.format() == WorldFormat::CellGraph) {
        const CellGraph* g = map_.cell_graph();
        int hist[16] = {0};
        for (const GraphCell& c : g->cells())
            hist[c.neighbor_count < 15 ? c.neighbor_count : 15]++;
        String s = "IronbandEngine: cellgraph loaded, neighbor histogram:";
        for (int i = 0; i < 16; ++i)
            if (hist[i]) s += String(" {0}:{1}").format(Array::make(i, hist[i]));
        godot::UtilityFunctions::print(s);
    }
    return ok;
}

void IronbandEngine::set_party_position(int q, int r) {
    party_.set_position(hex_location(q, r));
}

Vector2i IronbandEngine::get_party_position() const {
    int64_t id = party_.position();
    return Vector2i(hex_location_q(id), hex_location_r(id));
}

void IronbandEngine::move_party(const PackedVector2Array& path) {
    std::vector<int64_t> locations;
    locations.reserve(path.size());
    for (int i = 0; i < path.size(); ++i) {
        Vector2 v = path[i];
        locations.push_back(hex_location((int)v.x, (int)v.y));
    }
    party_.set_path(locations);
}

void IronbandEngine::set_time_scale(double s) {
    clock_.set_scale(s);
    if (s > 0.0) resume_scale_ = s;
    emit_signal("time_scale_changed", clock_.scale());
}

void IronbandEngine::resume() {
    clock_.set_scale(resume_scale_);
    emit_signal("time_scale_changed", clock_.scale());
}

Dictionary IronbandEngine::get_hex_info(int q, int r) const {
    Dictionary d;
    const HexCell* c = map_.cell_at(q, r);
    if (!c) return d;
    d["q"] = c->q; d["r"] = c->r;
    d["biome_id"] = c->biome_id;
    d["realm_id"] = c->realm_id;
    d["province_id"] = c->province_id;
    d["burg_id"] = c->burg_id;
    d["realm_name"] = String(map_.realm_name(c->realm_id).c_str());
    d["province_name"] = String(map_.province_name(c->province_id).c_str());
    return d;
}

String IronbandEngine::get_world_format() const {
    switch (map_.format()) {
        case WorldFormat::Hex:       return "hex";
        case WorldFormat::CellGraph: return "cellgraph";
        default:                     return "";
    }
}

Dictionary IronbandEngine::get_location_info(int64_t id) const {
    Dictionary d;
    TerrainInfo t;
    if (!map_.location_terrain(id, t)) return d;
    d["id"] = id;
    d["biome_id"] = t.biome_id;
    d["is_water"] = t.is_water;
    d["realm_id"] = t.realm_id;
    d["province_id"] = t.province_id;
    d["burg_id"] = t.burg_id;
    d["elevation"] = t.elevation;
    d["realm_name"] = String(map_.realm_name(t.realm_id).c_str());
    d["province_name"] = String(map_.province_name(t.province_id).c_str());
    if (map_.format() == WorldFormat::Hex) {
        d["q"] = hex_location_q(id); d["r"] = hex_location_r(id);
    }
    return d;
}

PackedInt64Array IronbandEngine::get_location_neighbors(int64_t id) const {
    PackedInt64Array out;
    for (int64_t n : map_.location_neighbors(id)) out.push_back(n);
    return out;
}

double IronbandEngine::get_move_cost(int64_t from, int64_t to) const {
    return map_.move_cost(from, to);
}

void IronbandEngine::set_hours_per_unit(double h) { map_.set_hours_per_unit(h); }

PackedInt64Array IronbandEngine::get_cell_ids() const {
    PackedInt64Array out;
    const CellGraph* g = map_.cell_graph();
    if (!g) return out;
    for (const GraphCell& c : g->cells()) out.push_back((int64_t)c.id);
    return out;
}

PackedVector2Array IronbandEngine::get_cell_sites() const {
    PackedVector2Array out;
    const CellGraph* g = map_.cell_graph();
    if (!g) return out;
    for (const GraphCell& c : g->cells()) out.push_back(Vector2(c.cx, c.cy));
    return out;
}

PackedVector2Array IronbandEngine::get_cell_polygon(int64_t id) const {
    PackedVector2Array out;
    const CellGraph* g = map_.cell_graph();
    if (!g) return out;
    const GraphCell* c = g->cell((uint32_t)id);
    if (!c) return out;
    const uint32_t* b = g->border(*c);
    for (int i = 0; i < c->border_count; ++i) {
        float x = 0, y = 0;
        g->vertex(b[i], x, y);
        out.push_back(Vector2(x, y));
    }
    return out;
}

Dictionary IronbandEngine::get_game_time() const {
    Dictionary d;
    d["game_day"] = clock_.game_day();
    d["game_hour"] = clock_.game_hour_of_day();
    d["scale"] = clock_.scale();
    return d;
}

void IronbandEngine::_process(double delta) {
    tick(delta);
}

void IronbandEngine::tick(double delta) {
    if (clock_.paused()) return;

    int days = clock_.advance(delta);

    // Move the party with the time spent this frame.
    double hours_this_frame = delta * WorldClock::HOURS_PER_SECOND * clock_.scale();
    int64_t from_id = party_.position();

    auto cost_fn = [&](int64_t, int64_t to) -> double {
        const HexCell* c = map_.cell_at(hex_location_q(to), hex_location_r(to));
        double mult = c ? terrain_cost_for_biome(c->biome_id) : 1.0;
        return 4.0 * mult;  // BASE_HOURS_PER_HEX * terrain multiplier
    };

    bool auto_paused = false;
    auto on_entered = [&](int64_t id) -> bool {
        int q = hex_location_q(id), r = hex_location_r(id);
        const HexCell* c = map_.cell_at(q, r);
        int terrain = c ? c->biome_id : -1;
        int prov = c ? c->province_id : 0;
        int realm = c ? c->realm_id : 0;
        if (map_.format() == WorldFormat::Hex) emit_signal("hex_entered", q, r, terrain, prov, realm);

        TerrainInfo t_info;
        map_.location_terrain(id, t_info);
        emit_signal("location_entered", (int64_t)id,
            String::num_int64(t_info.biome_id),
            String(map_.province_name(t_info.province_id).c_str()),
            String(map_.realm_name(t_info.realm_id).c_str()));

        // TriggerSystem::check still takes Hex; on CellGraph worlds these
        // q/r values are meaningless (reinterpreted cell ids), so triggers
        // silently no-op there. Generalizing TriggerSystem to location ids
        // is deferred to a future plan (party movement isn't wired to
        // cell-graph worlds yet either — move_party only builds hex ids).
        Hex from_hex{ hex_location_q(from_id), hex_location_r(from_id) };
        Hex h{ q, r };
        Trigger t = triggers_->check(map_, from_hex, h);
        from_id = id;
        if (t.type != TriggerType::None) {
            const char* name = "none";
            switch (t.type) {
                case TriggerType::Location:  name = "location"; break;
                case TriggerType::Border:    name = "border"; break;
                case TriggerType::Encounter: name = "encounter"; break;
                case TriggerType::Event:     name = "event"; break;
                default: break;
            }
            emit_signal("encounter_triggered", String(name), String(t.payload.c_str()));
            // Border is informational and does not auto-pause.
            if (t.type != TriggerType::Border) {
                auto_paused = true;
                return false;
            }
        }
        return true;
    };

    party_.advance(hours_this_frame, cost_fn, on_entered);

    emit_signal("clock_ticked", clock_.game_day(), clock_.game_hour_of_day());

    int base_day = clock_.game_day() - days;
    for (int i = 0; i < days; ++i) {
        sim_->tick_day(map_);
        emit_signal("world_tick_completed", base_day + i + 1);
    }

    if (auto_paused) {
        clock_.pause();
        emit_signal("time_scale_changed", 0.0);
    }
}

} // namespace ib
