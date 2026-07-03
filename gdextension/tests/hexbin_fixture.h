#pragma once
#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

// Writes a minimal valid .hexbin: 1 biome, 1 realm, 1 province, 0 burgs,
// 2 hex records. Returns the path written.
inline std::string write_fixture_hexbin(const std::string& path) {
    auto u16 = [](std::vector<uint8_t>& b, uint16_t v){ b.push_back(v&0xFF); b.push_back((v>>8)&0xFF); };
    auto u32 = [](std::vector<uint8_t>& b, uint32_t v){ for(int i=0;i<4;i++) b.push_back((v>>(8*i))&0xFF); };
    auto i16 = [&](std::vector<uint8_t>& b, int16_t v){ u16(b,(uint16_t)v); };
    auto f64 = [](std::vector<uint8_t>& b, double v){ uint8_t* p=(uint8_t*)&v; for(int i=0;i<8;i++) b.push_back(p[i]); };

    // String table: [0]="" , then "Forest", "Northreach", "Coldvale", "Coldvale Keep"
    std::vector<uint8_t> strtab;
    strtab.push_back(0); // offset 0 = empty
    uint32_t off_forest = strtab.size();
    for (char c : std::string("Forest")) strtab.push_back(c); strtab.push_back(0);
    uint32_t off_realm = strtab.size();
    for (char c : std::string("Northreach")) strtab.push_back(c); strtab.push_back(0);
    uint32_t off_prov = strtab.size();
    for (char c : std::string("Coldvale")) strtab.push_back(c); strtab.push_back(0);
    uint32_t off_cap = strtab.size();
    for (char c : std::string("Coldvale Keep")) strtab.push_back(c); strtab.push_back(0);

    std::vector<uint8_t> body;
    // Header (72 bytes)
    body.push_back('H'); body.push_back('X'); body.push_back('B'); body.push_back('1');
    u16(body, 2);                       // version
    u16(body, 2);                       // biome_count (index 0 empty, 1 = Forest)
    u32(body, 2);                       // hex_count
    u32(body, (uint32_t)strtab.size()); // strtab_size
    u16(body, 1);                       // realm_count
    u16(body, 1);                       // province_count
    u16(body, 0);                       // burg_count
    i16(body, 0);                       // r_min
    i16(body, 1);                       // r_max
    u16(body, 4);                       // tex_w
    u16(body, 2);                       // tex_h
    u16(body, 0);                       // reserved
    f64(body, 10.0);                    // hex_size
    f64(body, 100.0);                   // origin_x
    f64(body, -50.0);                   // origin_y
    f64(body, 400.0);                   // map_w
    f64(body, 200.0);                   // map_h

    for (uint8_t b : strtab) body.push_back(b);

    // biome offsets (biome_count = 2): [0]=empty, [1]=Forest
    u32(body, 0);
    u32(body, off_forest);
    // realms: id=1 -> Northreach
    u16(body, 1); u32(body, off_realm);
    // provinces: id=1 -> Coldvale / Coldvale Keep
    u16(body, 1); u32(body, off_prov); u32(body, off_cap);
    // burgs: none
    // hex records: {q,r,biome_id,realm_id,province_id,burg_id,elevation}
    i16(body, 5); i16(body, 0); body.push_back(1); body.push_back(1); u16(body, 1); u16(body, 0); body.push_back(42);
    i16(body, 6); i16(body, 0); body.push_back(1); body.push_back(1); u16(body, 1); u16(body, 0); body.push_back(7);

    std::ofstream f(path, std::ios::binary);
    f.write((const char*)body.data(), (std::streamsize)body.size());
    f.close();
    return path;
}
