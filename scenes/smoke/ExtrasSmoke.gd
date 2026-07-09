extends SceneTree

## Verifies ExtrasLoader against real cheia data: file loads, decompresses,
## and top_goods_for_burg()/garrisons_for_burg() return sane results for a
## known burg (Nabad, burg_id 1 — a state capital with both a market and a
## regiment garrisoned in it).

func _initialize() -> void:
	var failures := 0

	var extras := ExtrasLoader.load_file("res://worlds/cheia/extras.bin")
	if extras.is_empty():
		push_error("SMOKE FAIL: extras.bin loaded empty")
		quit(1); return

	var top := extras.top_goods_for_burg(1, 5)
	if top.is_empty():
		push_error("SMOKE FAIL: burg 1 (Nabad) expected market goods, got none")
		failures += 1
	else:
		for i in range(top.size() - 1):
			if top[i]["stock"] < top[i + 1]["stock"]:
				push_error("SMOKE FAIL: top_goods_for_burg not sorted descending by stock")
				failures += 1
				break

	var garrisons := extras.garrisons_for_burg(1)
	if garrisons.is_empty():
		push_error("SMOKE FAIL: burg 1 (Nabad) expected a garrison, got none")
		failures += 1
	else:
		var units: Dictionary = garrisons[0].get("units", {})
		if units.is_empty():
			push_error("SMOKE FAIL: garrison record has no unit counts")
			failures += 1

	var none := extras.garrisons_for_burg(999999)
	if not none.is_empty():
		push_error("SMOKE FAIL: nonexistent burg_id returned a non-empty garrison list")
		failures += 1

	if failures == 0:
		print("SMOKE PASS: ExtrasLoader parses extras.bin, top_goods_for_burg and garrisons_for_burg resolve correctly")
		quit(0)
	else:
		push_error("SMOKE FAIL: %d failures" % failures)
		quit(1)
