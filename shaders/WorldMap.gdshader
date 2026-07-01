shader_type canvas_item;

// ── Hex grid parameters ────────────────────────────────────────────────────
uniform float hex_size;
uniform float origin_x;
uniform float origin_y;
uniform float map_w;
uniform float map_h;

// ── Hex data textures ──────────────────────────────────────────────────────
// hex_data:  R = biome_id/255, G = realm_id/255
// burg_data: R = province_id>>8, G = province_id&0xFF
uniform sampler2D hex_data  : filter_nearest;
uniform sampler2D burg_data : filter_nearest;
uniform int tex_width;
uniform int tex_height;
uniform int r_min;
uniform int   selected_q        = -9999;
uniform int   selected_r        = -9999;
uniform int   selected_realm_id = -1;
uniform int   selected_burg_id  = -1;
uniform int   selection_mode    = 0;
uniform float camera_zoom       = 1.0;
uniform int   color_mode        = 1;
uniform sampler2D fog_data : filter_nearest, hint_default_black;

// ── Terrain grain textures (world-space tiling, RegionMap only) ───────────
uniform bool      use_tile_texture  = false;
uniform float     tile_scale        = 5.0;
uniform sampler2D tex_grass  : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D tex_forest : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D tex_rocky  : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D tex_snow   : filter_linear_mipmap, repeat_enable, hint_default_white;

// ── Biome palette ──────────────────────────────────────────────────────────
vec3 biome_color(int id) {
	if (id == 0)  return vec3(0.10, 0.25, 0.55);
	if (id == 1)  return vec3(0.88, 0.79, 0.38);
	if (id == 2)  return vec3(0.76, 0.72, 0.60);
	if (id == 3)  return vec3(0.79, 0.78, 0.35);
	if (id == 4)  return vec3(0.38, 0.65, 0.25);
	if (id == 5)  return vec3(0.15, 0.52, 0.18);
	if (id == 6)  return vec3(0.22, 0.52, 0.20);
	if (id == 7)  return vec3(0.05, 0.40, 0.10);
	if (id == 8)  return vec3(0.10, 0.42, 0.32);
	if (id == 9)  return vec3(0.30, 0.50, 0.45);
	if (id == 10) return vec3(0.72, 0.78, 0.80);
	if (id == 11) return vec3(0.88, 0.94, 1.00);
	if (id == 12) return vec3(0.18, 0.40, 0.35);
	return vec3(1.0, 0.0, 1.0);
}

// ── Realm tint palette ─────────────────────────────────────────────────────
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

// ── Terrain grain by biome ─────────────────────────────────────────────────
vec3 terrain_grain(int biome_id, vec2 tuv) {
	vec3 t;
	if (biome_id == 11 || biome_id == 10) {
		t = texture(tex_snow, tuv).rgb;
	} else if (biome_id == 5 || biome_id == 6 ||
	           biome_id == 7 || biome_id == 8 ||
	           biome_id == 9 || biome_id == 12) {
		t = texture(tex_forest, tuv).rgb;
	} else if (biome_id == 2) {
		t = texture(tex_rocky, tuv).rgb;
	} else {
		t = texture(tex_grass, tuv).rgb;
	}
	return t * 2.0;  // normalise to mean≈1 for multiply-blend
}

// ── Utility: floor div 2 safe for negative integers ───────────────────────
int floor_div2(int r) {
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
	return ivec2(rx, rz);
}

// ── Hex data helpers ───────────────────────────────────────────────────────
vec2 hex_tex_uv(int hq, int hr) {
	int ql = -floor_div2(hr) - 2;
	int qo = hq - ql;
	int ro = hr - r_min;
	return (vec2(float(qo), float(ro)) + 0.5) / vec2(float(tex_width), float(tex_height));
}

bool hex_in_bounds(int hq, int hr) {
	int ql = -floor_div2(hr) - 2;
	int qo = hq - ql;
	int ro = hr - r_min;
	return qo >= 0 && qo < tex_width && ro >= 0 && ro < tex_height;
}

int realm_at(int hq, int hr) {
	if (!hex_in_bounds(hq, hr)) return -1;
	vec4 d = texture(hex_data, hex_tex_uv(hq, hr));
	if (d.a < 0.5) return -1;
	return int(d.g * 255.0 + 0.5);
}

int province_at(int hq, int hr) {
	if (!hex_in_bounds(hq, hr)) return -1;
	vec4 d = texture(burg_data, hex_tex_uv(hq, hr));
	return int(d.r * 255.0 + 0.5) * 256 + int(d.g * 255.0 + 0.5);
}

int biome_at(int hq, int hr) {
	if (!hex_in_bounds(hq, hr)) return 0;
	vec4 d = texture(hex_data, hex_tex_uv(hq, hr));
	if (d.a < 0.5) return 0;
	return int(d.r * 255.0 + 0.5);
}

void fragment() {
	vec3 out_color = vec3(0.05, 0.05, 0.10);

	float wx = UV.x * map_w + origin_x;
	float wy = UV.y * map_h + origin_y;

	float sqrt3 = 1.7320508;
	float r_f = (wy - origin_y) / (1.5 * hex_size);
	float q_f = ((wx - origin_x) / (sqrt3 * hex_size)) - r_f * 0.5;

	ivec2 qr = hex_round(q_f, r_f);
	int q = qr.x;
	int r = qr.y;

	int q_left   = -floor_div2(r) - 2;
	int q_offset = q - q_left;
	int r_offset = r - r_min;

	// ── Fractional cube position + nearest face ────────────────────────────
	// Computed early so terrain blending can use pm/nb_q/nb_r.
	float fx = q_f - float(q);
	float fz = r_f - float(r);
	float fy = -fx - fz;

	float hex_px_r = hex_size * camera_zoom * sqrt3;

	float p1 = fx - fy;
	float p2 = fy - fx;
	float p3 = fz - fy;
	float p4 = fy - fz;
	float p5 = fx - fz;
	float p6 = fz - fx;
	float pm = max(p1, max(p2, max(p3, max(p4, max(p5, p6)))));

	int nb_q = q; int nb_r = r;
	int nb_realm    = 0;
	int nb_province = 0;
	if      (p1 >= pm) { nb_q = q+1; nb_r = r;   nb_realm = realm_at(q+1,r);   nb_province = province_at(q+1,r);   }
	else if (p2 >= pm) { nb_q = q-1; nb_r = r;   nb_realm = realm_at(q-1,r);   nb_province = province_at(q-1,r);   }
	else if (p3 >= pm) { nb_q = q;   nb_r = r+1; nb_realm = realm_at(q,r+1);   nb_province = province_at(q,r+1);   }
	else if (p4 >= pm) { nb_q = q;   nb_r = r-1; nb_realm = realm_at(q,r-1);   nb_province = province_at(q,r-1);   }
	else if (p5 >= pm) { nb_q = q+1; nb_r = r-1; nb_realm = realm_at(q+1,r-1); nb_province = province_at(q+1,r-1); }
	else               { nb_q = q-1; nb_r = r+1; nb_realm = realm_at(q-1,r+1); nb_province = province_at(q-1,r+1); }

	// ── Fog of war ─────────────────────────────────────────────────────────
	bool fog_hidden = true;
	if (q_offset >= 0 && q_offset < tex_width && r_offset >= 0 && r_offset < tex_height) {
		vec2 fog_uv = (vec2(float(q_offset), float(r_offset)) + 0.5)
		            / vec2(float(tex_width), float(tex_height));
		fog_hidden = texture(fog_data, fog_uv).r <= 0.5;
	}

	// ── Hex data → color ───────────────────────────────────────────────────
	int realm_id    = 0;
	int province_id = 0;

	if (q_offset >= 0 && q_offset < tex_width && r_offset >= 0 && r_offset < tex_height) {
		vec2 tex_uv           = hex_tex_uv(q, r);
		vec4 data             = texture(hex_data,  tex_uv);
		vec4 burg_data_sample = texture(burg_data, tex_uv);

		if (data.a >= 0.5) {
			int biome_id = int(data.r * 255.0 + 0.5);
			realm_id     = int(data.g * 255.0 + 0.5);
			province_id  = int(burg_data_sample.r * 255.0 + 0.5) * 256
			             + int(burg_data_sample.g * 255.0 + 0.5);

			vec3 base;
			if (realm_id == 0) {
				base = biome_color(biome_id);
			} else if (color_mode == 2) {
				float pv = 0.65 + 0.35 * fract(float(province_id) * 0.6180339887);
				base = mix(biome_color(biome_id), realm_tint(realm_id) * pv, 0.35);
			} else {
				base = mix(biome_color(biome_id), realm_tint(realm_id), 0.35);
			}

			// ── Terrain grain + biome colour blending at hex edges ────────
			// Only in tile-texture mode (zoomed-in local view).
			if (use_tile_texture && biome_id != 0) {
				float s   = 1.0 / (hex_size * tile_scale);
				vec2  tuv = vec2((wx - origin_x) * s, (wy - origin_y) * s);

				vec3 grain = terrain_grain(biome_id, tuv);

				int nb_biome = biome_at(nb_q, nb_r);
				if (nb_biome > 0 && nb_biome != biome_id) {
					float edge_t = smoothstep(0.50, 1.0, pm);

					// Blend terrain grain textures.
					grain = mix(grain, terrain_grain(nb_biome, tuv), edge_t);

					// Blend biome colour — makes the transition clearly visible.
					// Only within the same realm (or both unclaimed) so realm
					// borders don't bleed colour across the line.
					if (nb_realm == realm_id) {
						vec3 nb_base = biome_color(nb_biome);
						if (nb_realm > 0) {
							if (color_mode == 2) {
								float pv2 = 0.65 + 0.35 * fract(float(nb_province) * 0.6180339887);
								nb_base = mix(nb_base, realm_tint(nb_realm) * pv2, 0.35);
							} else {
								nb_base = mix(nb_base, realm_tint(nb_realm), 0.35);
							}
						}
						base = mix(base, nb_base, edge_t * 0.55);
					}
				}

				base = mix(base, base * grain, 0.25);
			}

			out_color = base;
		}
	}

	// ── Borders ────────────────────────────────────────────────────────────
	if (camera_zoom > 5.0 && province_id > 0) {
		if (pm > 1.0 - 2.0 / hex_px_r)
			if (nb_province > 0 && nb_province != province_id)
				out_color = mix(out_color, vec3(0.0), 0.65);
	}

	if (camera_zoom > 2.0 && realm_id > 0) {
		if (pm > 1.0 - 3.0 / hex_px_r)
			if (nb_realm >= 0 && nb_realm != realm_id)
				out_color = mix(out_color, vec3(0.0), 0.55);
	}

	// ── Selection highlights ───────────────────────────────────────────────
	if (selection_mode == 2 && realm_id == selected_realm_id) {
		out_color = mix(out_color, vec3(0.35, 0.55, 1.0), 0.5);
	} else if (selection_mode == 1 && province_id == selected_burg_id) {
		out_color = mix(out_color, vec3(0.3, 1.0, 0.45), 0.5);
	} else if (selection_mode == 0 && q == selected_q && r == selected_r) {
		out_color = mix(out_color, vec3(1.0, 0.95, 0.2), 0.55);
	}

	if (fog_hidden) out_color = mix(out_color, vec3(0.12, 0.12, 0.15), 0.7);
	COLOR = vec4(out_color, 1.0);
}
