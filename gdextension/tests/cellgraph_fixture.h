#pragma once
#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

// Writes a minimal valid cell_graph.bin (CGB1): 3 cells in a row, cell 2
// marine; 1 realm, 1 province, 1 road route on edge 0<->1; extras_size 0.
inline std::string write_fixture_cellgraph(const std::string& path) {
    std::vector<uint8_t> b;
    auto u8  = [&](uint8_t v){ b.push_back(v); };
    auto i8  = [&](int8_t v){ b.push_back((uint8_t)v); };
    auto u16 = [&](uint16_t v){ b.push_back(v&0xFF); b.push_back((v>>8)&0xFF); };
    auto u32 = [&](uint32_t v){ for(int i=0;i<4;i++) b.push_back((v>>(8*i))&0xFF); };
    auto f32 = [&](float v){ uint8_t p[4]; std::memcpy(p,&v,4); for(int i=0;i<4;i++) b.push_back(p[i]); };

    // ── strtab (built first so offsets are known) ────────────────────────
    std::vector<uint8_t> st; st.push_back(0);            // offset 0 = ""
    auto add_str = [&](const std::string& s)->uint32_t {
        uint32_t off = (uint32_t)st.size();
        for (char c : s) st.push_back((uint8_t)c);
        st.push_back(0);
        return off;
    };
    uint32_t off_marine = add_str("Marine");
    uint32_t off_grass  = add_str("Grassland");
    uint32_t off_forest = add_str("Forest");
    uint32_t off_realm  = add_str("Northreach");
    uint32_t off_provn  = add_str("Coldvale");
    uint32_t off_provf  = add_str("Coldvale March");
    uint32_t off_roads  = add_str("roads");
    uint32_t off_name   = add_str("Testland");
    uint32_t off_unit   = add_str("mi");

    // ── header 70 B ──────────────────────────────────────────────────────
    u8('C'); u8('G'); u8('B'); u8('1');
    u16(1);                       // version
    u16(3);                       // biome_count
    u16(0); u16(0);               // culture_count, religion_count
    u16(1); u16(1); u16(0);       // realm, province, burg
    u16(0); u16(0); u16(0);       // river, feature, zone
    u16(0); u16(0); u16(1);       // marker, note, route
    u32(3);                       // cell_count
    u32(4);                       // vertex_count
    u32(9);                       // border_total  (3 per cell)
    u32(4);                       // neighbor_total (1+2+1)
    u32(0); u32(0); u32(0); u32(0); // river_cells, feature_verts, zone_cells, route_pts
    u32((uint32_t)st.size());     // strtab_size
    u32(0);                       // extras_size
    // ── meta 48 B ────────────────────────────────────────────────────────
    f32(1280.0f); f32(768.0f); f32(3.0f);                 // map w/h, distance_scale
    f32(59.4f); f32(29.7f); f32(-29.7f);                  // latT latN latS
    f32(99.0f); f32(-49.5f); f32(49.5f);                  // lonT lonW lonE
    u32(off_name); u32(off_unit); u32(0);                 // map_name, distance_unit, seed
    // ── strtab ───────────────────────────────────────────────────────────
    for (uint8_t c : st) b.push_back(c);
    // ── biome offsets ────────────────────────────────────────────────────
    u32(off_marine); u32(off_grass); u32(off_forest);
    // ── realms: 1 row, 54 B ──────────────────────────────────────────────
    u16(1); u32(off_realm); u32(0); u32(0);               // id, name, full, form
    u16(0); u16(0); u32(0); u32(0);                       // capital, culture, center, color
    for (int i = 0; i < 7; i++) f32(0.0f);
    // ── provinces: 1 row, 34 B ───────────────────────────────────────────
    u16(1); u16(1); u16(0); u32(0);                       // id, state, burg, center
    u32(off_provn); u32(off_provf); u32(0); u32(0);       // name, full_name, form, color
    f32(0.0f); f32(0.0f);                                 // pole
    // ── burgs 0, cultures 0, religions 0, rivers 0 (+0 cells), features 0
    //    (+0 verts), zones 0 (+0 cells), markers 0, notes 0 ── nothing.
    // ── routes: 1 row, 16 B ──────────────────────────────────────────────
    u16(0); u32(off_roads); u32(0); u32(0); u16(0);       // id 0, group "roads", 0 pts
    // ── route points 0 ── nothing.
    // ── vertices: 4×8 B ──────────────────────────────────────────────────
    f32(-5.0f); f32(-5.0f);  f32(5.0f);  f32(-5.0f);
    f32(15.0f); f32(-5.0f);  f32(25.0f); f32(-5.0f);
    // ── cells: 3×64 B ────────────────────────────────────────────────────
    auto cell = [&](uint32_t id, float cx, float cy, uint8_t biome, int8_t tier,
                    uint8_t elev, uint16_t realm, uint16_t prov,
                    uint32_t bstart, uint16_t bcount,
                    uint32_t nstart, uint8_t ncount, uint8_t water) {
        u32(id); f32(cx); f32(cy);
        u8(biome); i8(tier); u8(elev); u8(0);             // biome, coast_tier, elevation, harbor
        u16(realm); u16(prov); u16(0); u16(0);            // realm, province, culture, religion
        u16(0); u16(0); u16(0); u16(0);                   // burg, river, river_flow, confluence
        u16(10); u16(0); u16(0);                          // area, suitability, feature
        i8(15); u8(20); f32(1.5f);                        // temp, prec, pop
        u32(0); u32(0);                                   // grid_id, haven
        u32(bstart); u16(bcount); u32(nstart); u8(ncount);
        u8(water);
    };
    cell(0,  0.0f, 0.0f, 1,  1, 40, 1, 1, 0, 3, 0, 1, 0);
    cell(1, 10.0f, 0.0f, 1,  1, 55, 1, 1, 3, 3, 1, 2, 0);
    cell(2, 20.0f, 0.0f, 0, -1,  0, 0, 0, 6, 3, 3, 1, 1);
    // ── borders: 9×u32 ───────────────────────────────────────────────────
    u32(0); u32(1); u32(2);   u32(1); u32(2); u32(3);   u32(2); u32(3); u32(0);
    // ── neighbors: 4×u32 ─────────────────────────────────────────────────
    u32(1);   u32(0); u32(2);   u32(1);
    // ── edge routes: 4×u16 ───────────────────────────────────────────────
    u16(0);   u16(0); u16(0xFFFF);   u16(0xFFFF);
    // ── extras: none (extras_size 0) ─────────────────────────────────────

    std::ofstream f(path, std::ios::binary);
    f.write((const char*)b.data(), (std::streamsize)b.size());
    return path;
}
