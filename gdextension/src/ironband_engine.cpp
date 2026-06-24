#include "ironband_engine.h"
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

namespace ib {

void IronbandEngine::_bind_methods() {
    ClassDB::bind_method(D_METHOD("ping"), &IronbandEngine::ping);
}

String IronbandEngine::ping() const {
    return String("ironband-engine-ok");
}

} // namespace ib
