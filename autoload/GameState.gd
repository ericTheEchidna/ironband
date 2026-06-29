extends Node

enum Phase { GLOBAL, REGIONAL, LOCAL }

const GLOBAL_SCENE   := "res://scenes/global/GlobalMap.tscn"
const REGIONAL_SCENE := "res://scenes/regional/RegionMap.tscn"
const LOCAL_SCENE    := "res://scenes/local/CombatMap.tscn"

var current_phase: Phase = Phase.REGIONAL


func _engine() -> Node:
	return get_node_or_null("/root/IronbandEngine")


func go_global() -> void:
	current_phase = Phase.GLOBAL
	var eng := _engine()
	if eng:
		eng.resume()
	get_tree().change_scene_to_file(GLOBAL_SCENE)


func go_regional(locale_col: int = -1, locale_row: int = -1) -> void:
	current_phase = Phase.REGIONAL
	var eng := _engine()
	if eng:
		eng.resume()
	if locale_col >= 0:
		Engine.set_meta("locale_col", locale_col)
		Engine.set_meta("locale_row", locale_row)
	get_tree().change_scene_to_file(REGIONAL_SCENE)


func go_local(hex_q: int, hex_r: int, biome_id: int) -> void:
	current_phase = Phase.LOCAL
	var eng := _engine()
	if eng:
		eng.set_time_scale(0.0)
	Engine.set_meta("hex_q",        hex_q)
	Engine.set_meta("hex_r",        hex_r)
	Engine.set_meta("hex_biome_id", biome_id)
	get_tree().change_scene_to_file(LOCAL_SCENE)
