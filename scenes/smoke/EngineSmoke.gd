extends SceneTree

func _initialize() -> void:
    var e = ClassDB.instantiate("IronbandEngine")
    if e == null:
        push_error("SMOKE FAIL: IronbandEngine not registered")
        quit(1)
        return
    var r: String = e.ping()
    if r == "ironband-engine-ok":
        print("SMOKE PASS: ", r)
        quit(0)
    else:
        push_error("SMOKE FAIL: ping returned " + r)
        quit(1)
