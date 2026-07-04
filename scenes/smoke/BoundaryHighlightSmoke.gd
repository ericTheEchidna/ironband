extends SceneTree

## Verifies the province-boundary union used by
## GlobalMap._rebuild_boundary_highlight against real cheia cell-graph data,
## without needing a running scene/camera to visually confirm hover.
##
## Mirrors GlobalMap's approach: BFS out from a cell to collect every cell
## in the same province, then union their polygons via Geometry2D.merge_polygons
## (Godot's built-in Clipper-backed polygon union) into the region's outer
## contour(s).

const MAX_CELLS := 4000
const SAMPLE_PROVINCE_COUNT := 8

func _initialize() -> void:
	var e: Object = ClassDB.instantiate("IronbandEngine")
	get_root().add_child(e)

	var ok: bool = e.load_world("/home/eric/source/ibp-engine/worlds/cheia/cell_graph.bin")
	if not ok:
		push_error("SMOKE FAIL: world did not load"); quit(1); return

	var ids: PackedInt64Array = e.get_cell_ids()

	# Sample several distinct provinces (sizes vary a lot) rather than just
	# the first one found, so a bug that only shows up on larger regions
	# doesn't slip through.
	var seen_provinces := {}
	var samples: Array = []

	# Lepidibia Parish (cell 15529) is a known repro: the old incremental
	# (non-fixed-point) merge split its outline into two closed loops
	# depending on hover-entry BFS order. Sample it explicitly first so a
	# regression back to that algorithm fails loudly here instead of only
	# showing up as a visual artifact in-game.
	var lepidibia_info: Dictionary = e.get_location_info(15529)
	if not lepidibia_info.is_empty():
		var lepidibia_pid := int(lepidibia_info.get("province_id", 0))
		if lepidibia_pid > 0:
			seen_provinces[lepidibia_pid] = true
			samples.append({"id": 15529, "province_id": lepidibia_pid})

	for id in ids:
		var info: Dictionary = e.get_location_info(id)
		var pid := int(info.get("province_id", 0))
		if pid > 0 and not seen_provinces.has(pid):
			seen_provinces[pid] = true
			samples.append({"id": id, "province_id": pid})
			if samples.size() >= SAMPLE_PROVINCE_COUNT:
				break

	if samples.is_empty():
		push_error("SMOKE FAIL: no cell with province_id > 0 found"); quit(1); return

	for sample in samples:
		var start_id: int = sample["id"]
		var province_id: int = sample["province_id"]

		var members := _bfs_region(e, start_id, province_id)
		if members.size() < 1:
			push_error("SMOKE FAIL: province %d BFS found no members" % province_id)
			quit(1); return

		for m in members:
			var mi: Dictionary = e.get_location_info(m)
			if int(mi.get("province_id", 0)) != province_id:
				push_error("SMOKE FAIL: member %d has province_id %d, want %d" % [m, mi.get("province_id", 0), province_id])
				quit(1); return

		var loops := _union_region(e, members)
		if loops.is_empty():
			push_error("SMOKE FAIL: province %d — union produced no loops" % province_id)
			quit(1); return

		for loop in loops:
			if loop.size() < 4:  # >= 3 distinct points + closing point
				push_error("SMOKE FAIL: province %d — degenerate loop with %d points" % [province_id, loop.size()])
				quit(1); return
			if not loop[0].is_equal_approx(loop[loop.size() - 1]):
				push_error("SMOKE FAIL: province %d — loop does not close: starts %s ends %s" %
					[province_id, loop[0], loop[loop.size() - 1]])
				quit(1); return

		if start_id == 15529 and loops.size() != 1:
			push_error("SMOKE FAIL: Lepidibia Parish (province %d) — expected 1 loop, got %d (sizes %s); the merge is order-dependent again" %
				[province_id, loops.size(), _loop_sizes(loops)])
			quit(1); return

		print("province %d: %d member cells -> %d loop(s), sizes %s" %
			[province_id, members.size(), loops.size(), _loop_sizes(loops)])

	print("SMOKE PASS: %d provinces checked" % samples.size())
	quit(0)


func _loop_sizes(loops: Array) -> String:
	var sizes: Array = []
	for loop in loops:
		sizes.append(loop.size())
	return str(sizes)


func _bfs_region(e: Object, cell_id: int, province_id: int) -> Array:
	var visited := {cell_id: true}
	var members: Array = [cell_id]
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
			if int(ninfo.get("province_id", 0)) == province_id:
				members.append(nb_id)
				queue.append(nb_id)
	return members


func _union_region(e: Object, members: Array) -> Array:
	var regions: Array = []
	for member_id in members:
		var poly: PackedVector2Array = e.get_cell_polygon(member_id)
		if poly.size() >= 3:
			regions.append(poly)

	# Fixed-point union — mirrors GlobalMap._rebuild_boundary_highlight.
	# A single incremental pass (each new cell folded into the first existing
	# region it touches) is BFS-order-dependent: two cells visited before
	# their shared neighbor gives them a reason to merge can end up stranded
	# in separate regions. Repeatedly merging any touching pair until a full
	# pass finds none left avoids that.
	var merged_any := true
	while merged_any:
		merged_any = false
		for i in range(regions.size()):
			var j := i + 1
			while j < regions.size():
				var result: Array = Geometry2D.merge_polygons(regions[i], regions[j])
				if result.size() == 1:
					regions[i] = result[0]
					regions.remove_at(j)
					merged_any = true
				else:
					j += 1
			if merged_any:
				break

	var loops: Array = []
	for region in regions:
		var loop: PackedVector2Array = (region as PackedVector2Array).duplicate()
		if loop.size() > 0:
			loop.append(loop[0])
		loops.append(loop)
	return loops
