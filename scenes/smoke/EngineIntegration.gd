extends SceneTree

var hexes_entered := 0
var ticks := 0
var paused_by_engine := false

func _initialize() -> void:
    var e: Object = ClassDB.instantiate("IronbandEngine")
    get_root().add_child(e)

    var ok: bool = e.load_world("/home/eric/source/ibp-engine/worlds/cheia/hex_grid.hexbin")
    if not ok:
        push_error("INTEG FAIL: world did not load"); quit(1); return

    e.hex_entered.connect(func(_q, _r, _t, _p, _rl): hexes_entered += 1)
    e.clock_ticked.connect(func(_d, _h): ticks += 1)
    e.time_scale_changed.connect(func(s): if s == 0.0: paused_by_engine = true)

    # Place party and queue a short straight path.
    e.set_party_position(200, 100)
    e.set_time_scale(1.0)
    var path := PackedVector2Array([Vector2(201, 100), Vector2(202, 100), Vector2(203, 100)])
    e.move_party(path)

    # Drive the engine manually (headless: no frame loop).
    for i in range(20):
        e.tick(0.5)

    if hexes_entered >= 1 and ticks >= 1:
        print("INTEG PASS: hexes=%d ticks=%d" % [hexes_entered, ticks])
        quit(0)
    else:
        push_error("INTEG FAIL: hexes=%d ticks=%d" % [hexes_entered, ticks])
        quit(1)
