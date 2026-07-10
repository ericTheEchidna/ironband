#pragma once
#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

// Writes a minimal hex_terrain.bin (HXT1) with exactly 2 records, matching
// write_fixture_hexbin's 2 hexes in sequential order: record 0 = (5,0), record 1 = (6,0).
// Only route_flags/river_id are meaningful for move_cost tests; other fields are zeroed.
inline std::string write_fixture_hex_terrain(
        const std::string& path,
        uint16_t route_flags_0, uint16_t river_id_0,
        uint16_t route_flags_1, uint16_t river_id_1) {
    auto u16 = [](std::vector<uint8_t>& b, uint16_t v){ b.push_back(v&0xFF); b.push_back((v>>8)&0xFF); };
    auto u32 = [](std::vector<uint8_t>& b, uint32_t v){ for(int i=0;i<4;i++) b.push_back((v>>(8*i))&0xFF); };

    std::vector<uint8_t> body;
    body.push_back('H'); body.push_back('X'); body.push_back('T'); body.push_back('1');
    u16(body, 1);   // version
    u32(body, 2);   // hex_count

    auto rec = [&](uint16_t route_flags, uint16_t river_id) {
        body.push_back(0);            // height (unused by move_cost)
        body.push_back(0);            // type_flags (unused)
        u16(body, 0);                 // culture_id (unused)
        u16(body, 0);                 // religion_id (unused)
        u16(body, 0);                 // river_flow (unused)
        u16(body, river_id);
        u16(body, route_flags);
    };
    rec(route_flags_0, river_id_0);
    rec(route_flags_1, river_id_1);

    std::ofstream f(path, std::ios::binary);
    f.write((const char*)body.data(), (std::streamsize)body.size());
    f.close();
    return path;
}
