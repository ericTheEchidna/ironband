shader_type canvas_item;

// ── Hex grid parameters ────────────────────────────────────────────────────
uniform float hex_size;       // center-to-vertex radius in Azgaar units
uniform float origin_x;
uniform float origin_y;
uniform float map_w;
uniform float map_h;

// ── Hex data texture ───────────────────────────────────────────────────────
// R = biome_id / 255, G = realm_id / 255
// Indexed by (q_offset, r_offset) where:
//   q_offset = q - q_left(r),  q_left(r) = -(r >> 1) - 2
//   r_offset = r - R_MIN
uniform sampler2D hex_data : filter_nearest;
uniform int tex_width;
uniform int tex_height;
uniform int r_min;   // minimum r stored in texture (typically -1)

// ── Biome palette (indices 0–12) ───────────────────────────────────────────
vec3 biome_color(int id) {
	if (id == 0)  return vec3(0.10, 0.25, 0.55);   // Marine
	if (id == 1)  return vec3(0.88, 0.79, 0.38);   // Hot desert
	if (id == 2)  return vec3(0.76, 0.72, 0.60);   // Cold desert
	if (id == 3)  return vec3(0.79, 0.78, 0.35);   // Savanna
	if (id == 4)  return vec3(0.38, 0.65, 0.25);   // Grassland
	if (id == 5)  return vec3(0.15, 0.52, 0.18);   // Tropical seasonal forest
	if (id == 6)  return vec3(0.22, 0.52, 0.20);   // Temperate deciduous forest
	if (id == 7)  return vec3(0.05, 0.40, 0.10);   // Tropical rainforest
	if (id == 8)  return vec3(0.10, 0.42, 0.32);   // Temperate rainforest
	if (id == 9)  return vec3(0.30, 0.50, 0.45);   // Taiga
	if (id == 10) return vec3(0.72, 0.78, 0.80);   // Tundra
	if (id == 11) return vec3(0.88, 0.94, 1.00);   // Glacier
	if (id == 12) return vec3(0.18, 0.40, 0.35);   // Wetland
	return vec3(1.0, 0.0, 1.0);                    // unknown → magenta
}

// ── Realm tint palette (indices 1–22) ─────────────────────────────────────
vec3 realm_tint(int id) {
	if (id == 1)  return vec3(0.80, 0.20, 0.20);
	if (id == 2)  return vec3(0.20, 0.60, 0.80);
	if (id == 3)  return vec3(0.80, 0.70, 0.10);
	if (id == 4)  return vec3(0.60, 0.20, 0.80);
	if (id == 5)  return vec3(0.20, 0.80, 0.40);
	if (id == 6)  return vec3(0.90, 0.45, 0.10);
	if (id == 7)  return vec3(0.10, 0.60, 0.60);
	if (id == 8)  return vec3(0.80, 0.30, 0.60);
	if (id == 9)  return vec3(0.50, 0.75, 0.20);
	if (id == 10) return vec3(0.20, 0.30, 0.80);
	if (id == 11) return vec3(0.75, 0.55, 0.20);
	if (id == 12) return vec3(0.40, 0.80, 0.70);
	if (id == 13) return vec3(0.80, 0.10, 0.40);
	if (id == 14) return vec3(0.30, 0.70, 0.30);
	if (id == 15) return vec3(0.70, 0.70, 0.30);
	if (id == 16) return vec3(0.50, 0.20, 0.70);
	if (id == 17) return vec3(0.80, 0.50, 0.50);
	if (id == 18) return vec3(0.30, 0.50, 0.70);
	if (id == 19) return vec3(0.70, 0.30, 0.20);
	if (id == 20) return vec3(0.20, 0.70, 0.60);
	if (id == 21) return vec3(0.60, 0.60, 0.10);
	if (id == 22) return vec3(0.30, 0.20, 0.70);
	return vec3(0.0);
}

// ── Floor division by 2 (safe for negative integers in GLSL) ──────────────
int floor_div2(int r) {
	// GLSL integer division truncates toward zero.
	// For negative odd r we need to subtract 1 to get floor.
	return (r < 0 && (r & 1) != 0) ? (r - 1) / 2 : r / 2;
}

// ── Cube-coordinate hex rounding ──────────────────────────────────────────
ivec2 hex_round(float q_f, float r_f) {
	float x_f = q_f;
	float z_f = r_f;
	float y_f = -x_f - z_f;
	int rx = int(round(x_f));
	int ry = int(round(y_f));
	int rz = int(round(z_f));
	float xd = abs(float(rx) - x_f);
	float yd = abs(float(ry) - y_f);
	float zd = abs(float(rz) - z_f);
	if (xd > yd && xd > zd) { rx = -ry - rz; }
	else if (yd > zd)        { ry = -rx - rz; }
	else                     { rz = -rx - ry; }
	return ivec2(rx, rz);   // (q, r)
}

void fragment() {
	vec3 out_color = vec3(0.05, 0.05, 0.10);  // void / out-of-bounds default

	// UV → Azgaar world coordinates
	float wx = UV.x * map_w + origin_x;
	float wy = UV.y * map_h + origin_y;

	// World → fractional axial hex (pointy-top)
	float sqrt3 = 1.7320508;
	float r_f = wy / (1.5 * hex_size);
	float q_f = (wx / (sqrt3 * hex_size)) - r_f * 0.5;

	// Round to nearest hex
	ivec2 qr = hex_round(q_f, r_f);
	int q = qr.x;
	int r = qr.y;

	// Texture index
	int q_left   = -floor_div2(r) - 2;
	int q_offset = q - q_left;
	int r_offset = r - r_min;

	if (q_offset >= 0 && q_offset < tex_width && r_offset >= 0 && r_offset < tex_height) {
		vec2 tex_uv = (vec2(float(q_offset), float(r_offset)) + 0.5)
		            / vec2(float(tex_width), float(tex_height));
		vec4 data = texture(hex_data, tex_uv);

		if (data.a >= 0.5) {
			int biome_id = int(data.r * 255.0 + 0.5);
			int realm_id = int(data.g * 255.0 + 0.5);
			vec3 base = biome_color(biome_id);
			if (realm_id > 0) {
				base = mix(base, realm_tint(realm_id), 0.35);
			}
			out_color = base;
		}
	}

	COLOR = vec4(out_color, 1.0);
}
