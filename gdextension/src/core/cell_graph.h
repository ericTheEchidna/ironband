#pragma once
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace ib {

struct CellGraphHeader {
    int version = 0;
    int biome_count = 0, culture_count = 0, religion_count = 0, realm_count = 0;
    int province_count = 0, burg_count = 0, river_count = 0, feature_count = 0;
    int zone_count = 0, marker_count = 0, note_count = 0, route_count = 0;
    uint32_t cell_count = 0, vertex_count = 0, border_total = 0, neighbor_total = 0;
    uint32_t river_cells_total = 0, feature_verts_total = 0, zone_cells_total = 0;
    uint32_t route_pts_total = 0, strtab_size = 0, extras_size = 0;
};

struct CellGraphMeta {
    double map_width = 0.0, map_height = 0.0, distance_scale = 0.0;
    double lat_t = 0.0, lat_n = 0.0, lat_s = 0.0;
    double lon_t = 0.0, lon_w = 0.0, lon_e = 0.0;
    std::string map_name, distance_unit, seed;
};

struct GraphCell {
    uint32_t id = 0;
    float cx = 0.0f, cy = 0.0f;
    int biome_id = 0, coast_tier = 0, elevation = 0, harbor = 0;
    int realm_id = 0, province_id = 0, culture_id = 0, religion_id = 0;
    int burg_id = 0, river_id = 0, river_flow = 0, confluence = 0;
    int area = 0, suitability = 0, feature_id = 0;
    int temp = 0, prec = 0;
    float pop = 0.0f;
    uint32_t grid_id = 0, haven = 0;
    uint32_t border_start = 0; int border_count = 0;
    uint32_t neighbor_start = 0; int neighbor_count = 0;
    bool is_water = false;
};

// Route groups (from Azgaar route "group" strings).
enum class RouteGroup : uint8_t { Road = 0, Trail = 1, Searoute = 2, Unknown = 255 };
constexpr uint16_t NO_ROUTE = 0xFFFF;

class CellGraph {
public:
    bool load(const std::string& path);
    bool loaded() const { return loaded_; }
    const CellGraphHeader& header() const { return header_; }
    const CellGraphMeta& meta() const { return meta_; }

    std::string biome_name(int biome_id) const;
    std::string realm_name(int realm_id) const;
    std::string province_name(int province_id) const;

    const GraphCell* cell(uint32_t id) const;              // by native (possibly sparse) id
    const std::vector<GraphCell>& cells() const { return cells_; }

    // Adjacency slices (valid only for a cell returned by this graph):
    const uint32_t* neighbors(const GraphCell& c) const { return neighbors_.data() + c.neighbor_start; }
    const uint32_t* border(const GraphCell& c) const { return borders_.data() + c.border_start; }
    uint16_t edge_route(const GraphCell& c, int k) const { return edge_routes_[c.neighbor_start + (uint32_t)k]; }
    RouteGroup route_group(uint16_t route_id) const;
    void vertex(uint32_t vid, float& x, float& y) const {
        x = verts_[(size_t)vid * 2]; y = verts_[(size_t)vid * 2 + 1];
    }

private:
    bool loaded_ = false;
    CellGraphHeader header_;
    CellGraphMeta meta_;
    std::vector<GraphCell> cells_;
    std::unordered_map<uint32_t, size_t> index_by_id_;
    std::vector<uint32_t> neighbors_, borders_;
    std::vector<uint16_t> edge_routes_;
    std::vector<float> verts_;                             // x,y interleaved
    std::unordered_map<int, std::string> biome_names_, realm_names_, province_names_;
    std::unordered_map<uint16_t, RouteGroup> route_groups_;
};

} // namespace ib
