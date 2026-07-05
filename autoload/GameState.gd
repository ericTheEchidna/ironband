extends Node

enum Phase { GLOBAL, REGIONAL, LOCAL }

const GLOBAL_SCENE   := "res://scenes/global/GlobalMap.tscn"
const REGIONAL_SCENE := "res://scenes/regional/RegionMap.tscn"
const LOCAL_SCENE    := "res://scenes/local/CombatMap.tscn"

var current_phase: Phase = Phase.REGIONAL

## Scene-transition state — set by go_*() before a scene change, read once by
## the destination scene's _ready(). Lives here (the already-registered
## GameState autoload) instead of Engine.set_meta()/get_meta(), so a typo in a
## key string is a script error instead of a silently wrong default.
var pending_locale_col: int = -1
var pending_locale_row: int = -1
var pending_hex_q:       int = 0
var pending_hex_r:       int = 0
var pending_hex_biome_id: int = 0
var pending_entry_world:  Vector2 = Vector2.ZERO
var _has_pending_entry_world := false


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
		print("[GameState] go_regional: world clock resumed at scale=", eng.get_game_time().get("scale", "?"))
	if locale_col >= 0:
		pending_locale_col = locale_col
		pending_locale_row = locale_row
	get_tree().change_scene_to_file(REGIONAL_SCENE)


func go_local(hex_q: int, hex_r: int, biome_id: int) -> void:
	current_phase = Phase.LOCAL
	var eng := _engine()
	if eng:
		eng.set_time_scale(0.0)
		print("[GameState] go_local: world clock frozen at game_hour=", eng.get_game_time().get("game_hour", "?"))
	pending_hex_q        = hex_q
	pending_hex_r        = hex_r
	pending_hex_biome_id = biome_id
	get_tree().change_scene_to_file(LOCAL_SCENE)


func set_pending_entry_world(world_pos: Vector2) -> void:
	pending_entry_world = world_pos
	_has_pending_entry_world = true


func has_pending_entry_world() -> bool:
	return _has_pending_entry_world


## Reads pending_entry_world and clears the flag — same one-shot semantics as
## the Engine.remove_meta() calls this replaces.
func consume_pending_entry_world() -> Vector2:
	_has_pending_entry_world = false
	return pending_entry_world
