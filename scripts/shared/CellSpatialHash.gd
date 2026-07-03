class_name CellSpatialHash
extends RefCounted

var _bucket_size: float = 1.0
var _buckets: Dictionary = {}   # Vector2i -> Array[int] (cell ids)
var _site_by_id: Dictionary = {}  # int -> Vector2
var _site_count: int = 0

func build(ids: PackedInt64Array, sites: PackedVector2Array, bucket_size: float) -> void:
	_bucket_size = bucket_size
	_buckets.clear()
	_site_by_id.clear()
	_site_count = ids.size()
	for i in range(ids.size()):
		var id := ids[i]
		var site := sites[i]
		_site_by_id[id] = site
		var key := _bucket_key(site)
		if not _buckets.has(key):
			_buckets[key] = []
		_buckets[key].append(id)

	if _buckets.size() > 0:
		var total := 0
		var max_occ := 0
		for key in _buckets.keys():
			var n: int = _buckets[key].size()
			total += n
			max_occ = max(max_occ, n)
		print("CellSpatialHash: %d sites, %d buckets, avg %.1f, max %d per bucket" %
			[_site_count, _buckets.size(), float(total) / _buckets.size(), max_occ])

func site_count() -> int:
	return _site_count

func bucket_count() -> int:
	return _buckets.size()

func nearest(point: Vector2) -> int:
	if _site_count == 0:
		return -1
	var center := _bucket_key(point)
	var best_id := -1
	var best_dist := INF
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(center.x + dx, center.y + dy)
			if not _buckets.has(key):
				continue
			for id in _buckets[key]:
				var d: float = point.distance_squared_to(_site_by_id[id])
				if d < best_dist:
					best_dist = d
					best_id = id
	return best_id

func _bucket_key(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / _bucket_size)), int(floor(p.y / _bucket_size)))
