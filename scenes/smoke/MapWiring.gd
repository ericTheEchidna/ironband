extends SceneTree

func _initialize() -> void:
	call_deferred("_check")

func _check() -> void:
	var e = root.get_node_or_null("IronbandEngine")
	if e == null:
		push_error("WIRING FAIL: IronbandEngine autoload missing"); quit(1); return
	for m in ["load_world", "move_party", "set_time_scale", "resume",
			  "get_party_position", "get_hex_info", "get_game_time"]:
		if not e.has_method(m):
			push_error("WIRING FAIL: missing method " + m); quit(1); return
	print("WIRING PASS")
	quit(0)
