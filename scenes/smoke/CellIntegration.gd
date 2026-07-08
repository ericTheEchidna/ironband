extends SceneTree

var locations_entered := 0

func _initialize() -> void:
	var e: Object = ClassDB.instantiate("IronbandEngine")
	get_root().add_child(e)

	var ok: bool = e.load_world(ProjectSettings.globalize_path("res://worlds/cheia/cell_graph.bin"))
	if not ok:
		push_error("CELL INTEG FAIL: world did not load"); quit(1); return

	if e.get_world_format() != "cellgraph":
		push_error("CELL INTEG FAIL: format = " + e.get_world_format()); quit(1); return

	var ids: PackedInt64Array = e.get_cell_ids()
	var sites: PackedVector2Array = e.get_cell_sites()
	if ids.size() != 26924 or sites.size() != 26924:
		push_error("CELL INTEG FAIL: ids=%d sites=%d, want 26924" % [ids.size(), sites.size()])
		quit(1); return

	var sample_id: int = ids[100]
	var info: Dictionary = e.get_location_info(sample_id)
	if not info.has("biome_id") or not info.has("realm_name"):
		push_error("CELL INTEG FAIL: get_location_info missing fields: " + str(info.keys()))
		quit(1); return

	var poly: PackedVector2Array = e.get_cell_polygon(sample_id)
	if poly.size() < 3:
		push_error("CELL INTEG FAIL: cell %d polygon has %d verts, want >=3" % [sample_id, poly.size()])
		quit(1); return

	var neighbors: PackedInt64Array = e.get_location_neighbors(sample_id)
	if neighbors.size() == 0:
		push_error("CELL INTEG FAIL: cell %d has no neighbors" % sample_id)
		quit(1); return

	var cost: float = e.get_move_cost(sample_id, neighbors[0])
	if cost <= 0.0:
		push_error("CELL INTEG FAIL: move_cost = %f, want > 0" % cost)
		quit(1); return

	e.location_entered.connect(func(_id, _t, _p, _r): locations_entered += 1)
	e.tick(0.1)  # no party path queued; just confirms the signal wiring doesn't error

	print("CELL INTEG PASS: cells=%d sample_polygon_verts=%d neighbors=%d move_cost=%.2f" %
		[ids.size(), poly.size(), neighbors.size(), cost])
	quit(0)
