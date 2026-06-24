#pragma once

namespace ib {

struct Vec2 { double x = 0.0, y = 0.0; };

struct Hex {
    int q = 0, r = 0;
    bool operator==(const Hex& o) const { return q == o.q && r == o.r; }
    bool operator!=(const Hex& o) const { return !(*this == o); }
};

constexpr double IMPASSABLE = 1e9;

Vec2 hex_to_world(Hex h, double hex_size, double origin_x, double origin_y);
Hex  world_to_hex(Vec2 w, double hex_size, double origin_x, double origin_y);
Hex  hex_round(double qf, double rf);
double terrain_cost_for_biome(int biome_id);

} // namespace ib
