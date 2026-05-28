extends Node

enum Phase { GLOBAL, REGIONAL, LOCAL }

const GLOBAL_SCENE   := "res://scenes/global/GlobalMap.tscn"
const REGIONAL_SCENE := "res://scenes/regional/RegionMap.tscn"
const LOCAL_SCENE    := "res://scenes/local/CombatMap.tscn"

var current_phase: Phase = Phase.REGIONAL


func go_global() -> void:
	current_phase = Phase.GLOBAL
	get_tree().change_scene_to_file(GLOBAL_SCENE)


func go_regional() -> void:
	current_phase = Phase.REGIONAL
	get_tree().change_scene_to_file(REGIONAL_SCENE)


func go_local(hex_q: int, hex_r: int, biome_id: int) -> void:
	current_phase = Phase.LOCAL
	Engine.set_meta("hex_q",        hex_q)
	Engine.set_meta("hex_r",        hex_r)
	Engine.set_meta("hex_biome_id", biome_id)
	get_tree().change_scene_to_file(LOCAL_SCENE)
