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

	# build()/set_camera() coverage — the component's actual rendering entry
	# points, previously untested.
	var layer := BurgMarkerLayer.new()
	get_root().add_child(layer)

	var village := BurgLoader.Burg.new()
	village.type    = 0
	village.flags   = 0
	village.hex_q   = 0
	village.hex_r   = 0
	village.name    = "Plainville"
	village.population = 100.0

	var port_town := BurgLoader.Burg.new()
	port_town.type    = 1
	port_town.flags   = 2
	port_town.hex_q   = 1
	port_town.hex_r   = 1
	port_town.name    = "Porttown"
	port_town.population = 500.0

	var capital := BurgLoader.Burg.new()
	capital.type    = 4
	capital.flags   = 0
	capital.hex_q   = 2
	capital.hex_r   = 2
	capital.name    = "Capitalis"
	capital.population = 5000.0

	var fixture_burgs: Array[BurgLoader.Burg] = [village, port_town, capital]
	layer.build(fixture_burgs, Callable(self, "_stub_hex_to_world"))

	if layer.get_child_count() != 3:
		push_error("SMOKE FAIL: build() produced %d marker nodes, want 3" % layer.get_child_count())
		failures += 1
	else:
		var village_marker := layer.get_child(0)
		var port_marker     := layer.get_child(1)
		var capital_marker  := layer.get_child(2)

		if village_marker.get_child_count() != 1:
			push_error("SMOKE FAIL: village marker has %d children, want 1 (base sprite only)" % village_marker.get_child_count())
			failures += 1

		if port_marker.get_child_count() <= 1:
			push_error("SMOKE FAIL: port town marker has %d children, want > 1 (base sprite + badge)" % port_marker.get_child_count())
			failures += 1

		if capital_marker.get_child_count() <= 1:
			push_error("SMOKE FAIL: capital marker has %d children, want > 1 (base sprite + accent)" % capital_marker.get_child_count())
			failures += 1

	if failures == 0:
		print("SMOKE PASS: marker_spec_for() covers all type/flag combinations, ancient burg count correct, build() marker/child counts correct")
		quit(0)
	else:
		push_error("SMOKE FAIL: %d failures" % failures)
		quit(1)


func _stub_hex_to_world(q: int, r: int) -> Vector2:
	return Vector2(q * 10.0, r * 10.0)
