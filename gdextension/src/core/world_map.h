#pragma once
#include "core/cell_graph.h"
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace ib {

struct HexCell {
    int q = 0, r = 0;
    int biome_id = 0, realm_id = 0, province_id = 0, burg_id = 0;
    int elevation = 0;   // 0-255, hexbin v2+; 0 for v1 files
};

struct WorldHeader {
    int version = 0, biome_count = 0, hex_count = 0, strtab_size = 0;
    int realm_count = 0, province_count = 0, burg_count = 0;
    int r_min = 0, r_max = 0, tex_w = 0, tex_h = 0;
    double hex_size = 1.0, origin_x = 0.0, origin_y = 0.0, map_w = 0.0, map_h = 0.0;
};

enum class WorldFormat { None, Hex, CellGraph };

class WorldMap {
public:
    bool load(const std::string& path);
    bool loaded() const { return loaded_; }
    const WorldHeader& header() const { return header_; }
    const HexCell* cell_at(int q, int r) const;
    std::string realm_name(int realm_id) const;
    std::string province_name(int province_id) const;

    WorldFormat format() const { return format_; }
    const CellGraph* cell_graph() const { return cell_graph_ ? cell_graph_.get() : nullptr; }

private:
    static int64_t key(int q, int r) { return ((int64_t)q << 32) ^ (uint32_t)r; }
    bool load_hexbin_(const std::vector<uint8_t>& buf);

    bool loaded_ = false;
    WorldFormat format_ = WorldFormat::None;
    std::unique_ptr<CellGraph> cell_graph_;
    WorldHeader header_;
    std::unordered_map<int64_t, HexCell> cells_;
    std::unordered_map<int, std::string> realm_names_;
    std::unordered_map<int, std::string> province_names_;
};

} // namespace ib
