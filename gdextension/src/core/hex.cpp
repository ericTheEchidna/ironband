#include "core/hex.h"
#include <cmath>

namespace ib {

static const double SQRT3 = std::sqrt(3.0);

Vec2 hex_to_world(Hex h, double hex_size, double origin_x, double origin_y) {
    return Vec2{
        hex_size * SQRT3 * (h.q + h.r * 0.5) + origin_x,
        hex_size * 1.5   *  h.r             + origin_y
    };
}

Hex hex_round(double qf, double rf) {
    double xf = qf, zf = rf, yf = -xf - zf;
    double rx = std::round(xf), ry = std::round(yf), rz = std::round(zf);
    double dx = std::abs(rx - xf), dy = std::abs(ry - yf), dz = std::abs(rz - zf);
    if (dx > dy && dx > dz)      rx = -ry - rz;
    else if (dy > dz)            ry = -rx - rz;
    else                         rz = -rx - ry;
    return Hex{ (int)rx, (int)rz };
}

Hex world_to_hex(Vec2 w, double hex_size, double origin_x, double origin_y) {
    double r_f = (w.y - origin_y) / (1.5 * hex_size);
    double q_f = ((w.x - origin_x) / (SQRT3 * hex_size)) - r_f * 0.5;
    return hex_round(q_f, r_f);
}

double terrain_cost_for_biome(int biome_id) {
    // Azgaar biome ids. Movement multipliers (BB-derived ratios).
    switch (biome_id) {
        case 0:  return IMPASSABLE; // Marine
        case 1:  return 1.5;        // Hot desert
        case 2:  return 1.5;        // Cold desert
        case 3:  return 1.0;        // Savanna
        case 4:  return 1.0;        // Grassland
        case 5:  return 1.5;        // Tropical seasonal forest
        case 6:  return 1.5;        // Temperate deciduous forest
        case 7:  return 2.0;        // Tropical rainforest
        case 8:  return 1.5;        // Temperate rainforest
        case 9:  return 1.5;        // Taiga
        case 10: return 1.5;        // Tundra
        case 11: return 2.5;        // Glacier
        case 12: return 2.0;        // Wetland
        default: return 1.0;
    }
}

} // namespace ib
