class_name BiomeColors

## Biome fill palette. Transcribed 1:1 from shaders/WorldMap.gdshader's
## biome_color() (and from there into ibp-engine/tools/render_cellgraph_texture.py's
## SHADER_BIOME_COLORS) — there is no shared source of truth across
## GLSL/GDScript/Python, so keep all three in sync by hand if this changes.
const _COLORS := {
	0:  Color(0.10, 0.25, 0.55),  # Marine
	1:  Color(0.88, 0.79, 0.38),  # Hot desert
	2:  Color(0.76, 0.72, 0.60),  # Cold desert
	3:  Color(0.79, 0.78, 0.35),  # Savanna
	4:  Color(0.38, 0.65, 0.25),  # Grassland
	5:  Color(0.15, 0.52, 0.18),  # Tropical seasonal forest
	6:  Color(0.22, 0.52, 0.20),  # Temperate deciduous forest
	7:  Color(0.05, 0.40, 0.10),  # Tropical rainforest / "Boreal Forest" — name tables disagree, see
	                              # render_cellgraph_texture.py's SHADER_BIOME_COLORS comment.
	8:  Color(0.10, 0.42, 0.32),  # Temperate rainforest
	9:  Color(0.30, 0.50, 0.45),  # Taiga
	10: Color(0.72, 0.78, 0.80),  # Tundra
	11: Color(0.88, 0.94, 1.00),  # Glacier
	12: Color(0.18, 0.40, 0.35),  # Wetland
}
## Off-map margin / unmapped biome_id color — matches Marine (biome 0) so it
## reads as fading into open ocean rather than a debug-magenta bug signal.
const FALLBACK := Color(0.10, 0.25, 0.55)

static func color(biome_id: int) -> Color:
	return _COLORS.get(biome_id, FALLBACK)
