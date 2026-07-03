extends SceneTree

const BurgMarkerLayer = preload("res://scripts/shared/BurgMarkerLayer.gd")

func _initialize() -> void:
	var failures := 0

	# type/flags -> expected {base, badge, accent} coverage.
	var cases := [
		{"type": 0, "flags": 0, "want_base": "village", "want_badge": false, "want_accent": false},
		{"type": 0, "flags": 2, "want_base": "village", "want_badge": true,  "want_accent": false},
		{"type": 1, "flags": 0, "want_base": "town",    "want_badge": false, "want_accent": false},
		{"type": 1, "flags": 2, "want_base": "town",    "want_badge": true,  "want_accent": false},
		{"type": 2, "flags": 0, "want_base": "city",    "want_badge": false, "want_accent": false},
		{"type": 2, "flags": 2, "want_base": "city",    "want_badge": true,  "want_accent": false},
		{"type": 3, "flags": 0, "want_base": "harbor",  "want_badge": false, "want_accent": false},
		{"type": 3, "flags": 2, "want_base": "harbor",  "want_badge": false, "want_accent": false},
		{"type": 4, "flags": 0, "want_base": "city",    "want_badge": false, "want_accent": true},
		{"type": 4, "flags": 2, "want_base": "city",    "want_badge": true,  "want_accent": true},
	]
	for c in cases:
		var b := BurgLoader.Burg.new()
		b.type  = c["type"]
		b.flags = c["flags"]
		var spec := BurgMarkerLayer.marker_spec_for(b)
		if spec["base"] != c["want_base"] or spec["badge"] != c["want_badge"] or spec["accent"] != c["want_accent"]:
			push_error("SMOKE FAIL: type=%d flags=%d -> %s, want base=%s badge=%s accent=%s" %
				[c["type"], c["flags"], str(spec), c["want_base"], c["want_badge"], c["want_accent"]])
			failures += 1

	var burgs := BurgLoader.load_file("/home/eric/source/ironband/worlds/ancient/burgs.bin")
	if burgs.all.size() != 1847:
		push_error("SMOKE FAIL: ancient burgs.bin count = %d, want 1847" % burgs.all.size())
		failures += 1

	if failures == 0:
		print("SMOKE PASS: marker_spec_for() covers all type/flag combinations, ancient burg count correct")
		quit(0)
	else:
		push_error("SMOKE FAIL: %d failures" % failures)
		quit(1)
