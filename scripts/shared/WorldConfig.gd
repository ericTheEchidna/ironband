## WorldConfig — single place to swap the active cell-graph world.
## Change CELL_WORLD_NAME here and every cell-graph-mode script (GlobalMap,
## RegionMap) picks up the new worlds/<name>/ directory automatically —
## nothing else should hardcode a world name.
class_name WorldConfig
extends RefCounted

const CELL_WORLD_NAME := "chareland"
