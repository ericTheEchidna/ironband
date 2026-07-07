extends SceneTree

## Verifies RegionMap's new "local zoom shows only the selected province"
## logic (_nearest_cell + _bfs_same_province) against real cheia data.

const MAX_CELLS := 4000

func _initialize() -> void:
	var e: Object = ClassDB.instantiate("IronbandEngine")
	get_root().add_child(e)

	var ok: bool = e.load_world("/home/eric/source/ibp-engine/worlds/cheia/cell_graph.bin")
	if not ok:
		push_error("SMOKE FAIL: world did not load"); quit(1); return

	var all_ids: PackedInt64Array = e.get_cell_ids()
	var all_sites: PackedVector2Array = e.get_cell_sites()

	# Pick a real cell with a province as the "entry point".
	var entry_id := -1
	var entry_site := Vector2.ZERO
	var entry_province := 0
	for i in range(all_ids.size()):
		var info: Dictionary = e.get_location_info(all_ids[i])
		if int(info.get("province_id", 0)) > 0:
			entry_id = all_ids[i]
			entry_site = all_sites[i]
			entry_province = int(info["province_id"])
			break
	if entry_id == -1:
		push_error("SMOKE FAIL: no cell with province_id > 0 found"); quit(1); return

	# _nearest_cell(reference_point) with the entry cell's own site must
	# resolve back to that exact cell (distance-to-self is the guaranteed minimum).
	var nearest_id := _nearest_cell(all_ids, all_sites, entry_site)
	if nearest_id != entry_id:
		push_error("SMOKE FAIL: nearest_cell(entry_site) = %d, want %d" % [nearest_id, entry_id])
		quit(1); return

	var members := _bfs_same_province(e, entry_id)
	if members.size() < 1:
		push_error("SMOKE FAIL: BFS found no members"); quit(1); return

	for id in members:
		var info: Dictionary = e.get_location_info(id)
		if int(info.get("province_id", 0)) != entry_province:
			push_error("SMOKE FAIL: member %d has province_id %d, want %d" %
				[id, info.get("province_id", 0), entry_province])
			quit(1); return

	# The membership set must be a strict subset of all cells (sanity check
	# that this is actually filtering, not accidentally returning everything).
	if members.size() >= all_ids.size():
		push_error("SMOKE FAIL: membership set (%d) is not smaller than all cells (%d)" %
			[members.size(), all_ids.size()])
		quit(1); return

	# Bounding box + padding (mirrors RegionMap._resolve_cellgraph_province_membership):
	# every member polygon vertex must land inside the padded rect, and the
	# rect must be strictly larger than the raw (unpadded) bbox on both axes
	# for a province with any real extent.
	var raw_bbox := Rect2()
	var has_bbox := false
	for id in members:
		var poly: PackedVector2Array = e.get_cell_polygon(id)
		for p in poly:
			if not has_bbox:
				raw_bbox = Rect2(p, Vector2.ZERO)
				has_bbox = true
			else:
				raw_bbox = raw_bbox.expand(p)
	if not has_bbox:
		push_error("SMOKE FAIL: no polygon vertices found for members"); quit(1); return

	var pad := maxf(maxf(raw_bbox.size.x, raw_bbox.size.y) * 0.2, 2.0)
	var padded_bbox := raw_bbox.grow(pad)

	for id in members:
		var poly: PackedVector2Array = e.get_cell_polygon(id)
		for p in poly:
			if not padded_bbox.has_point(p):
				push_error("SMOKE FAIL: vertex %s outside padded bbox %s" % [p, padded_bbox])
				quit(1); return

	if padded_bbox.size.x <= raw_bbox.size.x or padded_bbox.size.y <= raw_bbox.size.y:
		push_error("SMOKE FAIL: padded bbox %s not larger than raw bbox %s" % [padded_bbox, raw_bbox])
		quit(1); return

	# ── Context cells (RegionMap._load_cellgraph_locale's greyed-out adjacent
	# background) — mirrors the production formula; keep CONTEXT_BBOX_GROW /
	# CONTEXT_MAX_CELLS in sync with RegionMap.gd's _CELLGRAPH_CONTEXT_* consts
	# by hand, there is no shared source of truth (same caveat as BiomeColors.gd).
	const CONTEXT_BBOX_GROW := 0.6
	const CONTEXT_MAX_CELLS := 4000

	var member_set := {}
	for id in members:
		member_set[id] = true

	var context_bbox := padded_bbox.grow(maxf(padded_bbox.size.x, padded_bbox.size.y) * CONTEXT_BBOX_GROW)

	var context_ids: Array = []
	var context_sites: Array = []
	for i in range(all_ids.size()):
		var id: int = all_ids[i]
		if member_set.has(id):
			continue
		if context_bbox.has_point(all_sites[i]):
			context_ids.append(id)
			context_sites.append(all_sites[i])

	for id in context_ids:
		if member_set.has(id):
			push_error("SMOKE FAIL: context cell %d is also a member cell (not disjoint)" % id); quit(1); return

	for site in context_sites:
		if not context_bbox.has_point(site):
			push_error("SMOKE FAIL: context cell site %s outside context_bbox %s" % [site, context_bbox])
			quit(1); return

	if context_ids.is_empty():
		push_error("SMOKE FAIL: expected at least one context cell around province %d" % entry_province)
		quit(1); return

	if context_ids.size() > CONTEXT_MAX_CELLS:
		push_error("SMOKE FAIL: context cell count %d exceeds cap %d" % [context_ids.size(), CONTEXT_MAX_CELLS])
		quit(1); return

	# ── Biome region fills + coastline stroke (RegionMap._build_biome_region_fills
	# / _build_coastline_stroke) — exercises the REAL shared PolygonSmoothing/
	# CellRegionUnion classes (not a reimplementation, unlike the context-cell
	# checks above), since those are standalone reusable utilities rather than
	# RegionMap-specific logic.
	var rendered_ids: Array = members.duplicate()
	rendered_ids.append_array(context_ids)
	var biome_by_id := {}
	var is_member_by_id := {}
	for id in members:
		is_member_by_id[id] = true
	for id in context_ids:
		is_member_by_id[id] = false
	for id in rendered_ids:
		var info: Dictionary = e.get_location_info(id)
		biome_by_id[id] = int(info.get("biome_id", 0)) if not info.is_empty() else 0

	var rendered_set := {}
	for id in rendered_ids:
		rendered_set[id] = true

	var region_start_ms := Time.get_ticks_msec()

	# Fine-grained (biome_id, is_member) partition -> region fills.
	var visited := {}
	var region_count := 0
	var region_fill_shape_count := 0
	for start_id in rendered_ids:
		if visited.has(start_id):
			continue
		var biome_id: int = biome_by_id[start_id]
		var is_member: bool = is_member_by_id[start_id]

		var component: Array = [start_id]
		visited[start_id] = true
		var queue: Array = [start_id]
		var qi := 0
		while qi < queue.size():
			var cur: int = queue[qi]
			qi += 1
			for nb in e.get_location_neighbors(cur):
				var nb_id := int(nb)
				if visited.has(nb_id) or not rendered_set.has(nb_id):
					continue
				if biome_by_id[nb_id] != biome_id or is_member_by_id[nb_id] != is_member:
					continue
				visited[nb_id] = true
				component.append(nb_id)
				queue.append(nb_id)

		# Homogeneity: every cell in this component must share the partition key.
		for id in component:
			if biome_by_id[id] != biome_id or is_member_by_id[id] != is_member:
				push_error("SMOKE FAIL: region component %d mixes partition keys" % region_count)
				quit(1); return

		var polys: Array = []
		for id in component:
			var poly: PackedVector2Array = e.get_cell_polygon(id)
			if poly.size() >= 3:
				polys.append(poly)
		if polys.is_empty():
			continue
		region_count += 1

		for raw_loop in CellRegionUnion.union_polygons(polys):
			if raw_loop.size() < 3:
				push_error("SMOKE FAIL: degenerate region loop (%d points)" % raw_loop.size())
				quit(1); return
			var smoothed: PackedVector2Array = PolygonSmoothing.chaikin_closed(raw_loop, 2)
			if smoothed.size() <= raw_loop.size():
				push_error("SMOKE FAIL: chaikin_closed did not increase point count (%d -> %d)" %
					[raw_loop.size(), smoothed.size()])
				quit(1); return

			# fractal_jitter_closed determinism: same input + same fixed-seed
			# noise must produce byte-identical output every time (this is the
			# whole point vs. true randomness) — call it twice and compare.
			var jitter_noise := FastNoiseLite.new()
			jitter_noise.seed = 1337
			jitter_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
			jitter_noise.frequency = 1.0
			var jittered_a := PolygonSmoothing.fractal_jitter_closed(smoothed, jitter_noise, 1.2, 0.15)
			var jittered_b := PolygonSmoothing.fractal_jitter_closed(smoothed, jitter_noise, 1.2, 0.15)
			if jittered_a.size() != smoothed.size():
				push_error("SMOKE FAIL: fractal_jitter_closed changed point count (%d -> %d)" %
					[smoothed.size(), jittered_a.size()])
				quit(1); return
			for pi in jittered_a.size():
				if not jittered_a[pi].is_equal_approx(jittered_b[pi]):
					push_error("SMOKE FAIL: fractal_jitter_closed not deterministic at point %d: %s vs %s" %
						[pi, jittered_a[pi], jittered_b[pi]])
					quit(1); return

			for shape in Geometry2D.offset_polygon(jittered_a, 1.5):
				if shape.size() < 3:
					push_error("SMOKE FAIL: degenerate offset shape (%d points)" % shape.size())
					quit(1); return
				region_fill_shape_count += 1

	# Coarse land/water-only partition -> coastline stroke.
	visited = {}
	var coastline_loops: Array = []
	var any_water := false
	for start_id in rendered_ids:
		if visited.has(start_id):
			continue
		var is_water: bool = biome_by_id[start_id] == 0
		if is_water:
			any_water = true

		var component: Array = [start_id]
		visited[start_id] = true
		var queue: Array = [start_id]
		var qi := 0
		while qi < queue.size():
			var cur: int = queue[qi]
			qi += 1
			for nb in e.get_location_neighbors(cur):
				var nb_id := int(nb)
				if visited.has(nb_id) or not rendered_set.has(nb_id):
					continue
				if (biome_by_id[nb_id] == 0) != is_water:
					continue
				visited[nb_id] = true
				component.append(nb_id)
				queue.append(nb_id)

		if is_water:
			continue

		var polys: Array = []
		for id in component:
			var poly: PackedVector2Array = e.get_cell_polygon(id)
			if poly.size() >= 3:
				polys.append(poly)
		if polys.is_empty():
			continue

		for loop in CellRegionUnion.union_polygons(polys):
			coastline_loops.append(PolygonSmoothing.chaikin_closed(loop, 2))

	if any_water and coastline_loops.is_empty():
		push_error("SMOKE FAIL: rendered set includes water cells but produced no coastline loops")
		quit(1); return

	var region_ms := Time.get_ticks_msec() - region_start_ms

	print("SMOKE PASS: entry cell %d -> province %d, %d/%d cells selected, bbox=%s padded=%s, %d context cells, %d biome region(s)/%d fill shape(s), %d coastline loop(s) (any_water=%s), %dms" %
		[entry_id, entry_province, members.size(), all_ids.size(), raw_bbox, padded_bbox, context_ids.size(),
		 region_count, region_fill_shape_count, coastline_loops.size(), any_water, region_ms])
	quit(0)


func _nearest_cell(ids: PackedInt64Array, sites: PackedVector2Array, point: Vector2) -> int:
	var best_id := -1
	var best_dist := INF
	for i in range(ids.size()):
		var d := point.distance_squared_to(sites[i])
		if d < best_dist:
			best_dist = d
			best_id = ids[i]
	return best_id


func _bfs_same_province(e: Object, cell_id: int) -> PackedInt64Array:
	var info: Dictionary = e.get_location_info(cell_id)
	var province_id: int = int(info.get("province_id", 0)) if not info.is_empty() else 0
	var realm_id: int    = int(info.get("realm_id", 0))    if not info.is_empty() else 0

	var visited := {cell_id: true}
	var members := PackedInt64Array([cell_id])
	var queue: Array = [cell_id]
	var qi := 0
	while qi < queue.size() and members.size() < MAX_CELLS:
		var cur: int = queue[qi]
		qi += 1
		for nb in e.get_location_neighbors(cur):
			var nb_id := int(nb)
			if visited.has(nb_id):
				continue
			visited[nb_id] = true
			var ninfo: Dictionary = e.get_location_info(nb_id)
			if ninfo.is_empty():
				continue
			var same := (province_id > 0 and int(ninfo.get("province_id", 0)) == province_id) \
					 or (province_id <= 0 and int(ninfo.get("realm_id", 0)) == realm_id)
			if same:
				members.push_back(nb_id)
				queue.append(nb_id)
	return members
