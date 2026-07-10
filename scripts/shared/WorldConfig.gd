## WorldConfig — single place to swap the active world per rendering path.
## Change HEX_WORLD_NAME / CELL_WORLD_NAME here and every script for that path
## (GlobalMap, RegionMap) picks up the new worlds/<name>/ directory
## automatically — nothing else should hardcode a world name.
class_name WorldConfig
extends RefCounted

## Live default rendering path.
const HEX_WORLD_NAME := "fantasy"

## Disabled dev-only Voronoi path (GlobalMap.gd's force_cell_test).
const CELL_WORLD_NAME := "chareland"
