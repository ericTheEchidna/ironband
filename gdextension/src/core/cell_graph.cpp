#include "core/cell_graph.h"
#include <cstring>
#include <fstream>

namespace ib {

static uint16_t rd_u16(const uint8_t* p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd_u32(const uint8_t* p) {
    return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}
static float rd_f32(const uint8_t* p) { float v; std::memcpy(&v, p, 4); return v; }

static std::string strtab_get(const std::vector<uint8_t>& tab, uint32_t off) {
    if (off >= tab.size()) return "";
    return std::string((const char*)&tab[off]);
}

bool CellGraph::load(const std::string& path) {
    loaded_ = false;
    cells_.clear(); index_by_id_.clear();
    neighbors_.clear(); borders_.clear(); edge_routes_.clear(); verts_.clear();
    biome_names_.clear(); realm_names_.clear(); province_names_.clear();
    route_groups_.clear();

    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)),
                              std::istreambuf_iterator<char>());
    if (buf.size() < 70 + 48) return false;
    if (std::memcmp(buf.data(), "CGB1", 4) != 0) return false;

    const uint8_t* h = buf.data();
    header_.version         = rd_u16(h + 4);
    header_.biome_count     = rd_u16(h + 6);
    header_.culture_count   = rd_u16(h + 8);
    header_.religion_count  = rd_u16(h + 10);
    header_.realm_count     = rd_u16(h + 12);
    header_.province_count  = rd_u16(h + 14);
    header_.burg_count      = rd_u16(h + 16);
    header_.river_count     = rd_u16(h + 18);
    header_.feature_count   = rd_u16(h + 20);
    header_.zone_count      = rd_u16(h + 22);
    header_.marker_count    = rd_u16(h + 24);
    header_.note_count      = rd_u16(h + 26);
    header_.route_count     = rd_u16(h + 28);
    header_.cell_count          = rd_u32(h + 30);
    header_.vertex_count        = rd_u32(h + 34);
    header_.border_total        = rd_u32(h + 38);
    header_.neighbor_total      = rd_u32(h + 42);
    header_.river_cells_total   = rd_u32(h + 46);
    header_.feature_verts_total = rd_u32(h + 50);
    header_.zone_cells_total    = rd_u32(h + 54);
    header_.route_pts_total     = rd_u32(h + 58);
    header_.strtab_size         = rd_u32(h + 62);
    header_.extras_size         = rd_u32(h + 66);

    const uint8_t* m = buf.data() + 70;
    meta_.map_width      = rd_f32(m + 0);
    meta_.map_height     = rd_f32(m + 4);
    meta_.distance_scale = rd_f32(m + 8);
    meta_.lat_t = rd_f32(m + 12); meta_.lat_n = rd_f32(m + 16); meta_.lat_s = rd_f32(m + 20);
    meta_.lon_t = rd_f32(m + 24); meta_.lon_w = rd_f32(m + 28); meta_.lon_e = rd_f32(m + 32);
    uint32_t off_name = rd_u32(m + 36), off_unit = rd_u32(m + 40), off_seed = rd_u32(m + 44);

    size_t pos = 70 + 48;
    if (pos + header_.strtab_size > buf.size()) return false;
    std::vector<uint8_t> strtab(buf.begin() + pos, buf.begin() + pos + header_.strtab_size);
    pos += header_.strtab_size;
    meta_.map_name      = strtab_get(strtab, off_name);
    meta_.distance_unit = strtab_get(strtab, off_unit);
    meta_.seed          = strtab_get(strtab, off_seed);

    auto need = [&](size_t n) { return pos + n <= buf.size(); };

    // biomes
    for (int i = 0; i < header_.biome_count; ++i) {
        if (!need(4)) return false;
        biome_names_[i] = strtab_get(strtab, rd_u32(buf.data() + pos));
        pos += 4;
    }
    // realms (54 B: name_off @2)
    for (int i = 0; i < header_.realm_count; ++i) {
        if (!need(54)) return false;
        uint16_t id  = rd_u16(buf.data() + pos);
        realm_names_[id] = strtab_get(strtab, rd_u32(buf.data() + pos + 2));
        pos += 54;
    }
    // provinces (34 B: full_name_off @14)
    for (int i = 0; i < header_.province_count; ++i) {
        if (!need(34)) return false;
        uint16_t id  = rd_u16(buf.data() + pos);
        province_names_[id] = strtab_get(strtab, rd_u32(buf.data() + pos + 14));
        pos += 34;
    }
    // burgs / cultures / religions / rivers(+cells) / features(+verts) /
    // zones(+cells) / markers / notes — skipped (not needed by the engine yet)
    pos += (size_t)header_.burg_count * 44;
    pos += (size_t)header_.culture_count * 16;
    pos += (size_t)header_.religion_count * 20;
    pos += (size_t)header_.river_count * 46 + (size_t)header_.river_cells_total * 4;
    pos += (size_t)header_.feature_count * 23 + (size_t)header_.feature_verts_total * 4;
    pos += (size_t)header_.zone_count * 20 + (size_t)header_.zone_cells_total * 4;
    pos += (size_t)header_.marker_count * 24;
    pos += (size_t)header_.note_count * 12;
    // routes (16 B: group_off @2) — group per route id
    for (int i = 0; i < header_.route_count; ++i) {
        if (!need(16)) return false;
        uint16_t id = rd_u16(buf.data() + pos);
        std::string grp = strtab_get(strtab, rd_u32(buf.data() + pos + 2));
        RouteGroup g = RouteGroup::Unknown;
        if (grp == "roads") g = RouteGroup::Road;
        else if (grp == "trails") g = RouteGroup::Trail;
        else if (grp == "searoutes") g = RouteGroup::Searoute;
        route_groups_[id] = g;
        pos += 16;
    }
    pos += (size_t)header_.route_pts_total * 12;

    // vertices
    if (!need((size_t)header_.vertex_count * 8)) return false;
    verts_.resize((size_t)header_.vertex_count * 2);
    for (uint32_t i = 0; i < header_.vertex_count; ++i) {
        verts_[(size_t)i * 2]     = rd_f32(buf.data() + pos);
        verts_[(size_t)i * 2 + 1] = rd_f32(buf.data() + pos + 4);
        pos += 8;
    }
    // cells (64 B records — offsets per the CGB1 cell layout)
    if (!need((size_t)header_.cell_count * 64)) return false;
    cells_.resize(header_.cell_count);
    for (uint32_t i = 0; i < header_.cell_count; ++i) {
        const uint8_t* p = buf.data() + pos;
        GraphCell& c = cells_[i];
        c.id          = rd_u32(p + 0);
        c.cx          = rd_f32(p + 4);
        c.cy          = rd_f32(p + 8);
        c.biome_id    = p[12];
        c.coast_tier  = (int8_t)p[13];
        c.elevation   = p[14];
        c.harbor      = p[15];
        c.realm_id    = rd_u16(p + 16);
        c.province_id = rd_u16(p + 18);
        c.culture_id  = rd_u16(p + 20);
        c.religion_id = rd_u16(p + 22);
        c.burg_id     = rd_u16(p + 24);
        c.river_id    = rd_u16(p + 26);
        c.river_flow  = rd_u16(p + 28);
        c.confluence  = rd_u16(p + 30);
        c.area        = rd_u16(p + 32);
        c.suitability = rd_u16(p + 34);
        c.feature_id  = rd_u16(p + 36);
        c.temp        = (int8_t)p[38];
        c.prec        = p[39];
        c.pop         = rd_f32(p + 40);
        c.grid_id     = rd_u32(p + 44);
        c.haven       = rd_u32(p + 48);
        c.border_start   = rd_u32(p + 52);
        c.border_count   = rd_u16(p + 56);
        c.neighbor_start = rd_u32(p + 58);
        c.neighbor_count = p[62];
        c.is_water       = p[63] != 0;
        index_by_id_[c.id] = i;
        pos += 64;
    }
    // borders
    if (!need((size_t)header_.border_total * 4)) return false;
    borders_.resize(header_.border_total);
    for (uint32_t i = 0; i < header_.border_total; ++i) { borders_[i] = rd_u32(buf.data() + pos); pos += 4; }
    // neighbors
    if (!need((size_t)header_.neighbor_total * 4)) return false;
    neighbors_.resize(header_.neighbor_total);
    for (uint32_t i = 0; i < header_.neighbor_total; ++i) { neighbors_[i] = rd_u32(buf.data() + pos); pos += 4; }
    // edge routes
    if (!need((size_t)header_.neighbor_total * 2)) return false;
    edge_routes_.resize(header_.neighbor_total);
    for (uint32_t i = 0; i < header_.neighbor_total; ++i) { edge_routes_[i] = rd_u16(buf.data() + pos); pos += 2; }
    // extras: intentionally skipped (zlib JSON; no engine consumer)
    if (!need(header_.extras_size)) return false;

    loaded_ = true;
    return true;
}

std::string CellGraph::biome_name(int biome_id) const {
    auto it = biome_names_.find(biome_id);
    return it == biome_names_.end() ? "" : it->second;
}
std::string CellGraph::realm_name(int realm_id) const {
    auto it = realm_names_.find(realm_id);
    return it == realm_names_.end() ? "" : it->second;
}
std::string CellGraph::province_name(int province_id) const {
    auto it = province_names_.find(province_id);
    return it == province_names_.end() ? "" : it->second;
}
const GraphCell* CellGraph::cell(uint32_t id) const {
    auto it = index_by_id_.find(id);
    return it == index_by_id_.end() ? nullptr : &cells_[it->second];
}
RouteGroup CellGraph::route_group(uint16_t route_id) const {
    auto it = route_groups_.find(route_id);
    return it == route_groups_.end() ? RouteGroup::Unknown : it->second;
}

} // namespace ib
