shader_type canvas_item;

// Minimal passthrough for the cell-graph global-zoom atlas (subsystem 3) —
// ColorRect has no .texture property, unlike TextureRect, so the atlas is
// applied as a shader uniform instead, mirroring how WorldMap.gdshader
// already applies hex_data/burg_data to the same node type.
uniform sampler2D atlas_tex : source_color;

void fragment() {
	COLOR = texture(atlas_tex, UV);
}
