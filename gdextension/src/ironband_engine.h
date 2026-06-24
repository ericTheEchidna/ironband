#pragma once
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <memory>

#include "core/world_map.h"
#include "core/world_clock.h"
#include "core/party_controller.h"
#include "core/trigger_system.h"
#include "core/world_sim.h"

namespace ib {

class IronbandEngine : public godot::Node {
    GDCLASS(IronbandEngine, godot::Node)

protected:
    static void _bind_methods();

public:
    IronbandEngine();
    ~IronbandEngine() override = default;

    void _process(double delta) override;
    void tick(double delta);

    godot::String ping() const;

    bool load_world(const godot::String& path);
    void move_party(const godot::PackedVector2Array& path);
    void set_time_scale(double s);
    void resume();
    void set_party_position(int q, int r);
    godot::Vector2i get_party_position() const;
    godot::Dictionary get_hex_info(int q, int r) const;
    godot::Dictionary get_game_time() const;

private:
    WorldMap map_;
    WorldClock clock_;
    PartyController party_;
    std::unique_ptr<TriggerSystem> triggers_;
    std::unique_ptr<WorldSim> sim_;
    double resume_scale_ = 1.0;  // scale to restore after an auto-pause
};

} // namespace ib
