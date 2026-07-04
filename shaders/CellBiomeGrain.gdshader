shader_type canvas_item;

// Terrain-grain overlay for cell-graph biome fills (RegionMap local zoom) —
// reuses the same ground-texture assets and multiply-blend technique as
// WorldMap.gdshader's terrain_grain()/use_tile_texture path, applied to
// Polygon2D fills instead of the hex tile shader. Purely decorative: breaks
// up the flat vector look of a Voronoi cell's hard edges without touching
// any polygon geometry, so it carries none of the seam risk that geometric
// edge-smoothing does.
//
// One material is shared across every biome-fill Polygon2D; each fill sets
// its own `biome_id` via set_instance_shader_parameter so the shared
// material can pick the right grain texture and skip water.

uniform sampler2D tex_grass  : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D tex_forest : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D tex_rocky  : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D tex_snow   : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform float tile_scale = 0.15;  // world-units-per-tile-repeat scale factor

instance uniform int biome_id = 0;

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

vec3 terrain_grain(vec2 tuv) {
	if (biome_id == 10 || biome_id == 11) {
		return texture(tex_snow, tuv).rgb;
	} else if (biome_id == 5 || biome_id == 6 || biome_id == 7 ||
	           biome_id == 8 || biome_id == 9 || biome_id == 12) {
		return texture(tex_forest, tuv).rgb;
	} else if (biome_id == 2) {
		return texture(tex_rocky, tuv).rgb;
	}
	return texture(tex_grass, tuv).rgb;
}

void fragment() {
	// Marine stays flat, no grain (matches hex-mode's use_tile_texture skip) —
	// bare `return` isn't valid inside fragment(), so gate the blend instead.
	if (biome_id != 0) {
		vec2 tuv = world_pos * tile_scale;
		vec3 grain = terrain_grain(tuv) * 2.0;  // normalize to mean~=1 for multiply-blend
		COLOR.rgb *= grain;
	}
}
