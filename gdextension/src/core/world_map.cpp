#include "core/world_map.h"
#include <cmath>
#include <cstring>
#include <fstream>
#include <vector>

namespace ib {

static uint16_t rd_u16(const uint8_t* p) { return p[0] | (p[1] << 8); }
static int16_t  rd_i16(const uint8_t* p) { return (int16_t)rd_u16(p); }
static uint32_t rd_u32(const uint8_t* p) {
    return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}
static double rd_f64(const uint8_t* p) { double v; std::memcpy(&v, p, 8); return v; }

static std::string strtab_get(const std::vector<uint8_t>& tab, uint32_t off) {
    if (off >= tab.size()) return "";
    const char* s = (const char*)&tab[off];
    return std::string(s);
}

bool WorldMap::load(const std::string& path) {
    loaded_ = false;
    format_ = WorldFormat::None;
    header_ = WorldHeader{};
    cell_graph_.reset();
    cells_.clear(); realm_names_.clear(); province_names_.clear();
    hex_order_.clear(); terrain_.clear();

    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)),
                              std::istreambuf_iterator<char>());
    if (buf.size() < 4) return false;

    if (std::memcmp(buf.data(), "HXB1", 4) == 0) {
        if (!load_hexbin_(buf)) return false;
        load_hex_terrain_(path);  // best-effort; missing/bad file just leaves terrain_ empty
        format_ = WorldFormat::Hex;
        loaded_ = true;
        return true;
    }
    if (std::memcmp(buf.data(), "CGB1", 4) == 0) {
        cell_graph_ = std::make_unique<CellGraph>();
        if (!cell_graph_->load(path)) { cell_graph_.reset(); return false; }
        format_ = WorldFormat::CellGraph;
        loaded_ = true;
        return true;
    }
    return false;
}

bool WorldMap::load_hexbin_(const std::vector<uint8_t>& buf) {
    if (buf.size() < 72) return false;

    const uint8_t* h = buf.data();
    header_.version       = rd_u16(h + 4);
    header_.biome_count   = rd_u16(h + 6);
    header_.hex_count     = (int)rd_u32(h + 8);
    header_.strtab_size   = (int)rd_u32(h + 12);
    header_.realm_count   = rd_u16(h + 16);
    header_.province_count= rd_u16(h + 18);
    header_.burg_count    = rd_u16(h + 20);
    header_.r_min         = rd_i16(h + 22);
    header_.r_max         = rd_i16(h + 24);
    header_.tex_w         = rd_u16(h + 26);
    header_.tex_h         = rd_u16(h + 28);
    header_.hex_size      = rd_f64(h + 32);
    header_.origin_x      = rd_f64(h + 40);
    header_.origin_y      = rd_f64(h + 48);
    header_.map_w         = rd_f64(h + 56);
    header_.map_h         = rd_f64(h + 64);

    size_t pos = 72;
    if (pos + (size_t)header_.strtab_size > buf.size()) return false;
    std::vector<uint8_t> strtab(buf.begin() + pos, buf.begin() + pos + header_.strtab_size);
    pos += (size_t)header_.strtab_size;

    pos += (size_t)header_.biome_count * 4; // skip biome offsets

    for (int i = 0; i < header_.realm_count; ++i) {
        if (pos + 6 > buf.size()) return false;
        uint16_t id  = rd_u16(buf.data() + pos);
        uint32_t off = rd_u32(buf.data() + pos + 2);
        pos += 6;
        if (id > 0) realm_names_[id] = strtab_get(strtab, off);
    }
    for (int i = 0; i < header_.province_count; ++i) {
        if (pos + 10 > buf.size()) return false;
        uint16_t id   = rd_u16(buf.data() + pos);
        uint32_t noff = rd_u32(buf.data() + pos + 2);
        pos += 10;
        if (id > 0) province_names_[id] = strtab_get(strtab, noff);
    }
    pos += (size_t)header_.burg_count * 4; // skip burg offsets

    const size_t rec_size = header_.version >= 2 ? 11 : 10;
    for (int i = 0; i < header_.hex_count; ++i) {
        if (pos + rec_size > buf.size()) return false;
        HexCell c;
        c.q           = rd_i16(buf.data() + pos);
        c.r           = rd_i16(buf.data() + pos + 2);
        c.biome_id    = buf[pos + 4];
        c.realm_id    = buf[pos + 5];
        c.province_id = rd_u16(buf.data() + pos + 6);
        c.burg_id     = rd_u16(buf.data() + pos + 8);
        if (rec_size == 11) c.elevation = buf[pos + 10];
        pos += rec_size;
        cells_[key(c.q, c.r)] = c;
        hex_order_.push_back(key(c.q, c.r));
    }

    return true;
}

bool WorldMap::load_hex_terrain_(const std::string& hexbin_path) {
    size_t slash = hexbin_path.find_last_of("/\\");
    std::string dir = slash == std::string::npos ? std::string() : hexbin_path.substr(0, slash + 1);
    std::string path = dir + "hex_terrain.bin";

    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)),
                              std::istreambuf_iterator<char>());
    if (buf.size() < 10 || std::memcmp(buf.data(), "HXT1", 4) != 0) return false;

    uint32_t hex_count = rd_u32(buf.data() + 6);
    if (hex_count != hex_order_.size()) return false;

    const size_t rec_size = 12;
    size_t pos = 10;
    if (pos + (size_t)hex_count * rec_size > buf.size()) return false;

    for (uint32_t i = 0; i < hex_count; ++i) {
        const uint8_t* p = buf.data() + pos;
        HexTerrain t;
        t.river_id    = rd_u16(p + 8);
        t.route_flags = rd_u16(p + 10);
        terrain_[hex_order_[i]] = t;
        pos += rec_size;
    }
    return true;
}

const HexCell* WorldMap::cell_at(int q, int r) const {
    if (format_ != WorldFormat::Hex) return nullptr;
    auto it = cells_.find(key(q, r));
    return it == cells_.end() ? nullptr : &it->second;
}

std::string WorldMap::realm_name(int realm_id) const {
    if (format_ == WorldFormat::CellGraph) return cell_graph_->realm_name(realm_id);
    auto it = realm_names_.find(realm_id);
    return it == realm_names_.end() ? "" : it->second;
}

std::string WorldMap::province_name(int province_id) const {
    if (format_ == WorldFormat::CellGraph) return cell_graph_->province_name(province_id);
    auto it = province_names_.find(province_id);
    return it == province_names_.end() ? "" : it->second;
}

std::vector<int64_t> WorldMap::location_neighbors(int64_t id) const {
    std::vector<int64_t> out;
    if (format_ == WorldFormat::Hex) {
        static const int DQ[6] = { 1, 1, 0, -1, -1, 0 };
        static const int DR[6] = { 0, -1, -1, 0, 1, 1 };
        int q = hex_location_q(id), r = hex_location_r(id);
        if (!cell_at(q, r)) return out;
        for (int i = 0; i < 6; ++i) {
            int nq = q + DQ[i], nr = r + DR[i];
            if (cell_at(nq, nr)) out.push_back(hex_location(nq, nr));
        }
    } else if (format_ == WorldFormat::CellGraph) {
        const GraphCell* c = cell_graph_->cell((uint32_t)id);
        if (!c) return out;
        const uint32_t* ns = cell_graph_->neighbors(*c);
        for (int i = 0; i < c->neighbor_count; ++i) out.push_back((int64_t)ns[i]);
    }
    return out;
}

bool WorldMap::location_terrain(int64_t id, TerrainInfo& out) const {
    if (format_ == WorldFormat::Hex) {
        const HexCell* c = cell_at(hex_location_q(id), hex_location_r(id));
        if (!c) return false;
        out.biome_id = c->biome_id;
        out.is_water = c->biome_id == 0;
        out.realm_id = c->realm_id;
        out.province_id = c->province_id;
        out.burg_id = c->burg_id;
        out.elevation = c->elevation;
        return true;
    }
    if (format_ == WorldFormat::CellGraph) {
        const GraphCell* c = cell_graph_->cell((uint32_t)id);
        if (!c) return false;
        out.biome_id = c->biome_id;
        out.is_water = c->is_water;
        out.realm_id = c->realm_id;
        out.province_id = c->province_id;
        out.burg_id = c->burg_id;
        out.elevation = c->elevation;
        return true;
    }
    return false;
}

double WorldMap::move_cost(int64_t from, int64_t to) const {
    TerrainInfo dest;
    if (!location_terrain(to, dest)) return IMPASSABLE;
    if (dest.is_water) return IMPASSABLE;

    if (format_ == WorldFormat::Hex) {
        // Flat per-hex model (06-24 spec): every hex is the same size, so
        // distance collapses into the constant and cost = terrain multiplier.
        double cost = terrain_cost_for_biome(dest.biome_id);
        auto it = terrain_.find(to);
        if (it != terrain_.end()) {
            bool has_road  = (it->second.route_flags & 0x1) != 0;
            bool has_river = it->second.river_id > 0;
            if (has_road)       cost *= ROAD_COST_MULTIPLIER;
            else if (has_river) cost *= RIVER_COST_MULTIPLIER;
        }
        return cost;
    }

    const GraphCell* a = cell_graph_->cell((uint32_t)from);
    const GraphCell* b = cell_graph_->cell((uint32_t)to);
    if (!a || !b) return IMPASSABLE;

    // must be adjacent; find the edge to read its route
    int edge = -1;
    const uint32_t* ns = cell_graph_->neighbors(*a);
    for (int i = 0; i < a->neighbor_count; ++i)
        if (ns[i] == b->id) { edge = i; break; }
    if (edge < 0) return IMPASSABLE;

    double dx = (double)b->cx - a->cx, dy = (double)b->cy - a->cy;
    double dist = std::sqrt(dx * dx + dy * dy);
    double cost = dist * terrain_cost_for_biome(dest.biome_id) * hours_per_unit_;

    uint16_t route = cell_graph_->edge_route(*a, edge);
    if (route != NO_ROUTE && cell_graph_->route_group(route) == RouteGroup::Road)
        cost *= 0.5;   // BB-derived road modifier (06-24 spec)
    return cost;
}

} // namespace ib
