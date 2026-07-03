extends SceneTree

const CellSpatialHash = preload("res://scripts/shared/CellSpatialHash.gd")

func _initialize() -> void:
	# 20x20 grid of synthetic sites, spacing 10 world units, ids 0..399.
	var ids := PackedInt64Array()
	var sites := PackedVector2Array()
	for gy in range(20):
		for gx in range(20):
			ids.push_back(gy * 20 + gx)
			sites.push_back(Vector2(gx * 10.0, gy * 10.0))

	var hash := CellSpatialHash.new()
	hash.build(ids, sites, 25.0)  # bucket larger than spacing, several sites/bucket

	if hash.site_count() != 400:
		push_error("SMOKE FAIL: site_count = %d, want 400" % hash.site_count())
		quit(1); return

	# Brute-force cross-check: for 50 random-ish sample points, the hash's
	# nearest() must agree with a linear scan.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var mismatches := 0
	for i in range(50):
		var p := Vector2(rng.randf_range(-5.0, 195.0), rng.randf_range(-5.0, 195.0))
		var hash_result := hash.nearest(p)
		var brute_best := -1
		var brute_dist := INF
		for j in range(ids.size()):
			var d := p.distance_squared_to(sites[j])
			if d < brute_dist:
				brute_dist = d
				brute_best = ids[j]
		if hash_result != brute_best:
			mismatches += 1
			push_error("mismatch at %s: hash=%d brute=%d" % [p, hash_result, brute_best])

	if mismatches == 0:
		print("SMOKE PASS: 50/50 nearest() calls matched brute force")
		quit(0)
	else:
		push_error("SMOKE FAIL: %d/50 mismatches" % mismatches)
		quit(1)
