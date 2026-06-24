#pragma once
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/string.hpp>

namespace ib {

class IronbandEngine : public godot::Node {
    GDCLASS(IronbandEngine, godot::Node)

protected:
    static void _bind_methods();

public:
    IronbandEngine() = default;
    ~IronbandEngine() override = default;

    godot::String ping() const;
};

} // namespace ib
