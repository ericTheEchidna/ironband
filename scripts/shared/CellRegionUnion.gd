class_name CellRegionUnion
extends RefCounted

## Fixed-point polygon union: repeatedly merges any two regions that touch,
## until a full pass finds none left to merge. A single incremental pass
## (each new region folded into the first existing region it touches, never
## revisited) is order-dependent — two regions that both touch a third but
## not each other directly can end up stranded rather than merged into one,
## which shows up as an outline splitting into extra closed loops depending
## on iteration order. Uses Godot's built-in polygon-clipping (Geometry2D
## wraps Clipper) rather than hand-rolled edge-parity/vertex-stitching, which
## broke on real data (degenerate zero-length cell edges produced bogus
## self-loops).
static func union_polygons(polygons: Array) -> Array:
	var regions := polygons.duplicate()
	var merged_any := true
	while merged_any:
		merged_any = false
		for i in range(regions.size()):
			var j := i + 1
			while j < regions.size():
				var result: Array = Geometry2D.merge_polygons(regions[i], regions[j])
				if result.size() == 1:
					regions[i] = result[0]
					regions.remove_at(j)
					merged_any = true
				else:
					j += 1
			if merged_any:
				break
	return regions
