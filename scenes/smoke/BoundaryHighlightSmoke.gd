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
		if poly.size() < 3:
			continue
		var merged := false
		for i in range(regions.size()):
			var result: Array = Geometry2D.merge_polygons(regions[i], poly)
			if result.size() == 1:
				regions[i] = result[0]
				merged = true
				break
		if not merged:
			regions.append(poly)

	var loops: Array = []
	for region in regions:
		var loop: PackedVector2Array = (region as PackedVector2Array).duplicate()
		if loop.size() > 0:
			loop.append(loop[0])
		loops.append(loop)
	return loops
