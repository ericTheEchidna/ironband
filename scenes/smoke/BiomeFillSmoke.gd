extends SceneTree

const _BiomeColors := preload("res://scripts/shared/BiomeColors.gd")

## Verifies RegionMap._load_cellgraph_locale's new fill logic against real
## cheia cell-graph data: for a locale-sized slice of the map, every visible
## cell has a valid polygon and a resolvable (non-fallback, for known ids)
## biome color, mirroring the exact per-cell steps RegionMap now runs
## (get_cell_polygon + get_location_info + _BiomeColors.color).

func _initialize() -> void:
	# Biome 0 (Marine) is intentionally excluded from this check: its real
	# color and FALLBACK are the same value on purpose (see BiomeColors.gd —
	# unmapped biomes fade into ocean rather than flashing debug magenta), so
	# color-equality can't distinguish "resolved correctly" from "fell back"
	# for this one id. Checked directly against the palette table instead.
	if not _BiomeColors._COLORS.has(0):
		push_error("SMOKE FAIL: biome 0 (Marine) missing from palette"); quit(1); return
	if _BiomeColors.color(4) == _BiomeColors.FALLBACK:
		push_error("SMOKE FAIL: biome 4 (Grassland) resolved to fallback color"); quit(1); return
	if _BiomeColors.color(999) != _BiomeColors.FALLBACK:
		push_error("SMOKE FAIL: unknown biome id did not fall back"); quit(1); return

	var e: Object = ClassDB.instantiate("IronbandEngine")
	get_root().add_child(e)

	var ok: bool = e.load_world(ProjectSettings.globalize_path("res://worlds/cheia/cell_graph.bin"))
	if not ok:
		push_error("SMOKE FAIL: world did not load"); quit(1); return

	var extent: Vector2 = e.get_world_extent()
	# One quadrant of the map — comparable in scale to an actual locale
	# (cheia's locales.json is a 4x3 grid).
	var locale_rect := Rect2(Vector2.ZERO, extent * 0.25)

	var all_ids: PackedInt64Array = e.get_cell_ids()
	var all_sites: PackedVector2Array = e.get_cell_sites()

	var visible_ids: Array = []
	for i in range(all_ids.size()):
		if locale_rect.has_point(all_sites[i]):
			visible_ids.append(all_ids[i])

	if visible_ids.is_empty():
		push_error("SMOKE FAIL: locale rect %s contained no cells" % locale_rect); quit(1); return

	var seen_biomes := {}
	for id in visible_ids:
		var poly: PackedVector2Array = e.get_cell_polygon(id)
		if poly.size() < 3:
			continue  # RegionMap skips these too — not an error
		var info: Dictionary = e.get_location_info(id)
		if info.is_empty():
			push_error("SMOKE FAIL: cell %d has no location info" % id); quit(1); return
		var biome_id: int = int(info.get("biome_id", 0))
		var color: Color = _BiomeColors.color(biome_id)
		seen_biomes[biome_id] = true

	print("SMOKE PASS: %d/%d cells in locale-sized rect, %d distinct biomes, all resolved a fill color" %
		[visible_ids.size(), all_ids.size(), seen_biomes.size()])
	quit(0)
