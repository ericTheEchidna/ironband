#pragma once
#include <cstdint>
#include <string>
#include <unordered_map>

namespace ib {

struct HexCell {
    int q = 0, r = 0;
    int biome_id = 0, realm_id = 0, province_id = 0, burg_id = 0;
};

struct WorldHeader {
    int version = 0, biome_count = 0, hex_count = 0, strtab_size = 0;
    int realm_count = 0, province_count = 0, burg_count = 0;
    int r_min = 0, r_max = 0, tex_w = 0, tex_h = 0;
    double hex_size = 1.0, origin_x = 0.0, origin_y = 0.0, map_w = 0.0, map_h = 0.0;
};

class WorldMap {
public:
    bool load(const std::string& path);
    bool loaded() const { return loaded_; }
    const WorldHeader& header() const { return header_; }
    const HexCell* cell_at(int q, int r) const;
    std::string realm_name(int realm_id) const;
    std::string province_name(int province_id) const;

private:
    static int64_t key(int q, int r) { return ((int64_t)q << 32) ^ (uint32_t)r; }

    bool loaded_ = false;
    WorldHeader header_;
    std::unordered_map<int64_t, HexCell> cells_;
    std::unordered_map<int, std::string> realm_names_;
    std::unordered_map<int, std::string> province_names_;
};

} // namespace ib
