# Frontend Cell-Mode Rendering + Spatial-Hash Hover — Implementation Plan (subsystem 3)

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax for tracking. Written after subsystem 2
> ([2026-07-03-worldmap-cellgraph-backing.md](2026-07-03-worldmap-cellgraph-backing.md)) landed — this plan codes
> against the actual, merged `IronbandEngine` binding surface, not a projected one.

**Goal:** Godot frontend renders `cell_graph.bin` (Voronoi) worlds end-to-end — pre-baked terrain atlas at global
zoom, true cell polygons + spatial-hash hover/click at regional zoom — using only engine-served data (no second
CGB1 parser in GDScript). Produces the evidence needed for the hex-retirement criteria (b) and (c) in the spec.

**Spec:** [2026-07-02-freeform-worldmap-design.md](../specs/2026-07-02-freeform-worldmap-design.md) — Interaction
Model, Rendering at Scale, Testing Strategy, hex-retirement criterion.
**Brief:** [2026-07-03-frontend-cellmode-brief.md](2026-07-03-frontend-cellmode-brief.md) — decisions already made,
carried forward unchanged below.

## Landed engine surface this plan codes against

(`gdextension/src/ironband_engine.h`/`.cpp`, merged `be7c05b`)

```
get_world_format() -> String                          # "hex" | "cellgraph" | ""
get_location_info(id) -> Dictionary                    # id, biome_id, is_water, realm_id, province_id, burg_id,
                                                        #   elevation, realm_name, province_name, (q, r if hex)
get_location_neighbors(id) -> PackedInt64Array
get_move_cost(from, to) -> float
get_cell_ids() -> PackedInt64Array
get_cell_sites() -> PackedVector2Array                 # same order as get_cell_ids()
get_cell_polygon(id) -> PackedVector2Array              # border vertices, polygon order
location_entered(id, terrain, province, realm)          # both formats; terrain is a numeric-id string today
hex_entered(q, r, terrain_id, province_id, realm_id)     # hex worlds only
```

Nothing at the engine level does a spatial hash, nearest-cell query, or texture-atlas build — those are frontend
and tooling responsibilities per the spec's Components table. `get_cell_polygon` return order matches
`cell_graph.bin`'s border winding, directly usable in `Line2D`/`Polygon2D`.

## Global Constraints

- **No `CellGraphLoader.gd`, no second CGB1 parser in GDScript** (brief decision, do not re-litigate) — all cell
  data comes from `IronbandEngine` bindings above.
- **World data:** only `cheia` has a `cell_graph.bin` (`ibp-engine/worlds/cheia/cell_graph.bin`, 26,924 cells).
  `GlobalMap.gd`'s live default (`WORLD_NAME := "ancient"`, line 9) has no cell data and must NOT be changed by
  this plan — `ancient` is the actual in-progress game world; `cheia` is the format's test bed. Task 0 adds a
  cell-mode smoke/dev path without touching the default.
- **Test convention:** this project has no GDScript unit-test addon (`addons/` has no GUT/gdUnit). The existing,
  only automated GDScript convention is headless `SceneTree` smoke scripts under `scenes/smoke/` (see
  `EngineIntegration.gd`, `MapWiring.gd`), run via `godot --headless --script <path>`, asserting via `push_error`
  + `quit(1)`/`quit(0)`. This plan uses that convention for anything callable without a live render loop (spatial
  hash correctness, engine data wiring). Actual on-screen rendering/hover-feel is manual/visual verification per
  the spec's Testing Strategy — there is no way to automate pixel-level Godot rendering checks in this repo today,
  and inventing a new test harness is out of scope for this plan.
- **Palette:** three biome-color/name tables already exist in this repo and disagree with each other
  (`render_map.py` print palette, `WorldMap.gdshader`'s `biome_color()`, `GlobalMap.gd`'s `_biome_name()` — e.g.
  biome id 7 is "Boreal Forest" in one and "Tropical rainforest" in another). Reconciling all three is out of
  scope. This plan's new atlas tool matches the **runtime shader's** palette (`WorldMap.gdshader`), since that's
  the one users actually see on screen today — visual consistency between hex and cell rendering of the same
  biome matters more than fixing the pre-existing print-tool/shader mismatch.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.
- ibp-engine work commits in that repo; ironband work commits here — same split as subsystem 2.

## File Structure

- Create (ibp-engine): `tools/render_cellgraph_texture.py` — atlas rasterizer.
- Create (ibp-engine): `tools/test_render_cellgraph_texture.py` — pytest-style tests (mirrors
  `test_azgaar_to_cellgraph.py`'s conventions: stdlib `unittest`, synthetic fixtures, no pytest dependency).
- Create: `worlds/cheia/cell_graph.bin` symlink, `worlds/cheia/rivers.bin` symlink (both missing today — the
  latter is a pre-existing gap unrelated to cell-mode, fixed here since it blocks river rendering on cheia
  regardless of format).
- Create: `scripts/shared/CellSpatialHash.gd` — bucket-grid nearest-site lookup, used by both `GlobalMap.gd` and
  `RegionMap.gd` (this repo already duplicates hex helpers between those two scenes with no shared module; this
  plan does not fix that pre-existing duplication, but does not add to it either — the new spatial hash is shared
  from the start).
- Create: `scenes/smoke/CellSpatialHashSmoke.gd` — headless correctness check (brute-force cross-check).
- Create: `scenes/smoke/CellIntegration.gd` — headless load/query smoke test for `cell_graph.bin`, mirrors
  `EngineIntegration.gd`.
- Modify: `scripts/global/GlobalMap.gd` — world-format branch for texture load, hover, selection, info panel,
  `location_entered` wiring.
- Modify: `scripts/regional/RegionMap.gd` — world-format branch for regional true-polygon rendering (deferred to
  Task 6; RegionMap's locale-window loading is hex-specific in more places, see Task 6 notes).

---

### Task 0: World-data plumbing for cell-mode testing

**Files:**
- Create: `worlds/cheia/cell_graph.bin` (symlink), `worlds/cheia/rivers.bin` (symlink)

**Interfaces:** none (data plumbing only).

- [ ] **Step 1: Add the missing symlinks**

```bash
cd ~/source/ironband/worlds/cheia
ln -s /home/eric/source/ibp-engine/worlds/cheia/cell_graph.bin cell_graph.bin
ln -s /home/eric/source/ibp-engine/worlds/cheia/rivers.bin rivers.bin
```

- [ ] **Step 2: Verify**

`ls -la worlds/cheia/` shows both new symlinks resolving (not dangling) via `test -e`.

- [ ] **Step 3: Commit**

```bash
cd ~/source/ironband
git add worlds/cheia/cell_graph.bin worlds/cheia/rivers.bin
git commit -m "data: symlink cheia cell_graph.bin + rivers.bin into ironband worlds dir"
```

---

### Task 1: `render_cellgraph_texture.py` — build-time atlas rasterizer

**Files:**
- Create (ibp-engine): `tools/render_cellgraph_texture.py`
- Create (ibp-engine): `tools/test_render_cellgraph_texture.py`

**Interfaces:**
- Produces: `render_cellgraph_texture(cellgraph_path: Path, out_path: Path, width: int, height: int) -> Path`.
  Reads `cell_graph.bin` via `read_cellgraph_bin()` (already exists in `azgaar_to_cellgraph.py` — import it, do not
  write a fourth CGB1 reader), draws each cell's filled polygon via `PIL.ImageDraw.polygon(vertices, fill=color)`
  scaled from world-space (`meta.map_width` × `meta.map_height`) into the `width`×`height` canvas, colored by
  `SHADER_BIOME_COLORS[biome_id]` (a new palette dict transcribed 1:1 from `WorldMap.gdshader`'s `biome_color()`
  floats × 255, rounded — see Global Constraints), falling back to magenta `(255, 0, 255)` for unknown ids
  (matches `render_map.py`'s existing fallback convention). `main()` CLI: `input` (cell_graph.bin path),
  `--width`/`--height` (default 2048×2048, matching typical hexbin `tex_w`/`tex_h` magnitude — exact default is a
  reasonable starting point, not a hard requirement; retunable without a format change), `-o/--output` (default
  `input.parent / "cell_terrain.png"`), `-v` verbose logging via stdlib `logging` (matches `azgaar_to_cellgraph.py`
  conventions — no `print()` except final CLI success message).

- [ ] **Step 1: Write the failing test**

Create `tools/test_render_cellgraph_texture.py`:

```python
"""Tests for render_cellgraph_texture.py."""
from __future__ import annotations

import struct
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from render_cellgraph_texture import render_cellgraph_texture, SHADER_BIOME_COLORS
from azgaar_to_cellgraph import CellRecord, write_cellgraph_bin


def make_fixture_bin(path: Path) -> None:
    """3 cells in a row (reuses azgaar_to_cellgraph's own fixture shape),
    written via the real writer so this test exercises the real CGB1
    reader path, not a hand-rolled binary."""
    from tools.test_azgaar_to_cellgraph import make_fixture  # type: ignore
    data = make_fixture()
    records = [
        CellRecord(id=0, cx=0.0, cy=0.0, biome_id=1, realm_id=0, realm_name="",
                   province_id=0, province_name="", province_capital="", is_water=False,
                   burg="", burg_azgaar_id=0, harbor=0, river_id=0,
                   border=[0, 1, 2, 3], neighbors=[1]),
        CellRecord(id=1, cx=10.0, cy=0.0, biome_id=0, realm_id=0, realm_name="",
                   province_id=0, province_name="", province_capital="", is_water=True,
                   burg="", burg_azgaar_id=0, harbor=0, river_id=0,
                   border=[1, 4, 5, 2], neighbors=[0]),
    ]
    write_cellgraph_bin(records, data, path)


class RenderCellgraphTextureTest(unittest.TestCase):
    def test_writes_png_of_requested_size(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bin_path = Path(tmp) / "cell_graph.bin"
            make_fixture_bin(bin_path)
            out_path = Path(tmp) / "cell_terrain.png"
            result = render_cellgraph_texture(bin_path, out_path, width=64, height=64)
            self.assertEqual(result, out_path)
            img = Image.open(out_path)
            self.assertEqual(img.size, (64, 64))

    def test_unknown_biome_falls_back_to_magenta(self) -> None:
        self.assertEqual(SHADER_BIOME_COLORS.get(999, (255, 0, 255)), (255, 0, 255))

    def test_known_biome_id_has_a_color(self) -> None:
        self.assertIn(1, SHADER_BIOME_COLORS)  # Grassland or similar, must be populated


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_render_cellgraph_texture -v`
Expected: `ModuleNotFoundError: No module named 'render_cellgraph_texture'`

- [ ] **Step 3: Transcribe the shader palette**

Read `~/source/ironband/shaders/WorldMap.gdshader`'s `biome_color(int id)` function (GLSL `vec3(r,g,b)` in 0-1
floats, ~13 entries per the investigation). Transcribe each entry to `SHADER_BIOME_COLORS: dict[int, tuple[int,
int, int]]` in the new tool as `(round(r*255), round(g*255), round(b*255))` — a mechanical, 1:1 transcription, not
a re-derivation. Double-check the id→biome semantic mapping against `GlobalMap.gd`'s `_biome_name()` table while
transcribing (both should agree; if they don't, transcribe from the shader — the shader is what's actually
rendered — and leave a one-line comment noting the name-table disagreement without attempting to fix it).

- [ ] **Step 4: Write minimal implementation**

Create `tools/render_cellgraph_texture.py`:

```python
#!/usr/bin/env python3
"""
render_cellgraph_texture.py — Rasterize a cell_graph.bin's cell fills to a
build-time texture atlas (cell_terrain.png), for global-zoom rendering of
cell-graph worlds. Mirrors azgaar_to_hex.py's runtime hex-image technique
(GlobalMap.gd._load_hexbin builds _hex_img at load time; this tool does the
equivalent for cell worlds at build time, since per-cell fills at global
zoom are too many polygons to rasterize live — see the freeform-worldmap
spec's "Rendering at Scale" section).

Usage:
    python tools/render_cellgraph_texture.py worlds/cheia/cell_graph.bin

Output: cell_terrain.png alongside the input file.
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from PIL import Image, ImageDraw

from azgaar_to_cellgraph import read_cellgraph_bin

logger = logging.getLogger("render_cellgraph_texture")

# Transcribed 1:1 from ironband/shaders/WorldMap.gdshader's biome_color(),
# floats * 255 rounded. Keep in sync by hand if the shader palette changes —
# there is no shared source of truth between GDScript/GLSL and this tool.
SHADER_BIOME_COLORS: dict[int, tuple[int, int, int]] = {
    0:  (15, 40, 92),    # Marine
    1:  (196, 178, 138),  # Hot desert
    2:  (191, 191, 158),  # Cold desert
    3:  (166, 178, 87),   # Savanna
    4:  (97, 166, 64),    # Grassland
    5:  (77, 138, 61),    # Tropical seasonal forest
    6:  (48, 105, 43),    # Temperate deciduous forest
    7:  (13, 102, 26),    # Tropical rainforest / Boreal Forest (name disagreement — see plan Task 1 note)
    8:  (33, 87, 61),     # Temperate rainforest
    9:  (74, 97, 71),     # Taiga
    10: (145, 158, 140),  # Tundra
    11: (224, 240, 255),  # Glacier
    12: (74, continue_placeholder := 110, 92),  # Wetland — placeholder, replace during Step 3 transcription
}
FALLBACK_COLOR = (255, 0, 255)


def render_cellgraph_texture(cellgraph_path: Path, out_path: Path, width: int = 2048, height: int = 2048) -> Path:
    result = read_cellgraph_bin(cellgraph_path)
    meta = result["meta"]
    map_w, map_h = meta["map_width"], meta["map_height"]
    verts = result["vertices"]

    img = Image.new("RGB", (width, height), FALLBACK_COLOR)
    draw = ImageDraw.Draw(img)

    def to_px(vid: int) -> tuple[float, float]:
        vx, vy = verts[vid]
        return (vx / map_w) * width, (vy / map_h) * height

    drawn = 0
    for cell in result["cells"]:
        if len(cell["border"]) < 3:
            continue  # degenerate cells already filtered upstream; defensive skip
        color = SHADER_BIOME_COLORS.get(cell["biome_id"], FALLBACK_COLOR)
        poly = [to_px(vid) for vid in cell["border"]]
        draw.polygon(poly, fill=color)
        drawn += 1

    logger.info("render_cellgraph_texture: drew %d/%d cells -> %s", drawn, len(result["cells"]), out_path)
    img.save(out_path)
    return out_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--width", type=int, default=2048)
    parser.add_argument("--height", type=int, default=2048)
    parser.add_argument("-o", "--output", type=Path, default=None)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                         format="%(levelname)s %(message)s")

    out_path = args.output or (args.input.parent / "cell_terrain.png")
    render_cellgraph_texture(args.input, out_path, args.width, args.height)
    print(f"Wrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

(The `continue_placeholder :=` line is a deliberate marker — Step 3 replaces every color in this table with the
real transcribed shader values before this task is considered done; do not ship the placeholder walrus hack.)

`read_cellgraph_bin`'s existing return shape must include `vertices` (list of `(x,y)` tuples) and `meta` with
`map_width`/`map_height` — confirm this against the actual function in `azgaar_to_cellgraph.py` before relying on
the exact key names above; adjust the reader-consuming code to match if the real keys differ (the function exists
and is tested — this plan trusts its existing contract, but the exact dict key spelling should be verified against
the source, not assumed from this plan's memory of it).

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_render_cellgraph_texture -v`
Expected: PASS (3 tests). If PIL (`Pillow`) isn't installed in this environment, install it first
(`pip install Pillow` or check how `render_map.py` gets its Pillow dependency today — same environment should
already have it since `render_map.py` already imports `PIL.ImageDraw`).

- [ ] **Step 6: Generate the real cheia atlas**

Run: `cd ~/source/ibp-engine && python3 tools/render_cellgraph_texture.py worlds/cheia/cell_graph.bin -v`
Expected: exits 0, `worlds/cheia/cell_terrain.png` written, log line shows `drew 26924/26924 cells` (0 skipped —
cheia has 0 degenerate cells per subsystem 2's Task 9 smoke test).

- [ ] **Step 7: Commit (ibp-engine)**

```bash
cd ~/source/ibp-engine
git add tools/render_cellgraph_texture.py tools/test_render_cellgraph_texture.py worlds/cheia/cell_terrain.png
git commit -m "feat(cellgraph): render_cellgraph_texture.py — build-time global-zoom atlas

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

- [ ] **Step 8: Symlink the atlas into ironband (ironband repo)**

```bash
cd ~/source/ironband/worlds/cheia
ln -s /home/eric/source/ibp-engine/worlds/cheia/cell_terrain.png cell_terrain.png
git add cell_terrain.png
git commit -m "data: symlink cheia cell_terrain.png atlas

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: `CellSpatialHash.gd` — bucket-grid nearest-site lookup

**Files:**
- Create: `scripts/shared/CellSpatialHash.gd`
- Create: `scenes/smoke/CellSpatialHashSmoke.gd`

**Interfaces:**
- Produces: a `RefCounted` class (`class_name CellSpatialHash`) with:
  - `build(ids: PackedInt64Array, sites: PackedVector2Array, bucket_size: float) -> void` — buckets every site into
    a `Dictionary` keyed by `Vector2i(floor(x/bucket_size), floor(y/bucket_size))`, value = `Array[int]` of cell
    ids sharing that bucket. Logs bucket occupancy stats (avg/max cells per bucket) via `print()` after building —
    spec Error-Handling/Logging requirement ("Frontend logs spatial-hash bucket occupancy stats at load").
  - `nearest(point: Vector2) -> int` — returns the nearest site's cell id by checking the point's bucket plus its 8
    neighbors (3×3), returns `-1` if the hash is empty or (pathologically) no site found within the checked
    buckets — callers must handle `-1`.
  - `bucket_count() -> int`, `site_count() -> int` — introspection for the smoke test and for dev-build logging.

- [ ] **Step 1: Write the smoke test first**

Create `scenes/smoke/CellSpatialHashSmoke.gd` (headless `SceneTree` script per this repo's only test convention —
see Global Constraints):

```gdscript
extends SceneTree

const CellSpatialHash = preload("res://scripts/shared/CellSpatialHash.gd")

func _initialize() -> void:
    # 20x20 grid of synthetic sites, spacing 10 world units, ids 0..399.
    var ids := PackedInt64Array()
    var sites := PackedVector2Array()
    for gy in range(20):
        for gx in range(20):
            ids.push_back(gy * 20 + gx)
            sites.push_back(Vector2(gx * 10.0, gy * 10.0))

    var hash := CellSpatialHash.new()
    hash.build(ids, sites, 25.0)  # bucket larger than spacing, several sites/bucket

    if hash.site_count() != 400:
        push_error("SMOKE FAIL: site_count = %d, want 400" % hash.site_count())
        quit(1); return

    # Brute-force cross-check: for 50 random-ish sample points, the hash's
    # nearest() must agree with a linear scan.
    var rng := RandomNumberGenerator.new()
    rng.seed = 1337
    var mismatches := 0
    for i in range(50):
        var p := Vector2(rng.randf_range(-5.0, 195.0), rng.randf_range(-5.0, 195.0))
        var hash_result := hash.nearest(p)
        var brute_best := -1
        var brute_dist := INF
        for j in range(ids.size()):
            var d := p.distance_squared_to(sites[j])
            if d < brute_dist:
                brute_dist = d
                brute_best = ids[j]
        if hash_result != brute_best:
            mismatches += 1
            push_error("mismatch at %s: hash=%d brute=%d" % [p, hash_result, brute_best])

    if mismatches == 0:
        print("SMOKE PASS: 50/50 nearest() calls matched brute force")
        quit(0)
    else:
        push_error("SMOKE FAIL: %d/50 mismatches" % mismatches)
        quit(1)
```

- [ ] **Step 2: Run to verify it fails**

Run: `godot --headless --script scenes/smoke/CellSpatialHashSmoke.gd`
Expected: parse/load error — `scripts/shared/CellSpatialHash.gd` does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `scripts/shared/CellSpatialHash.gd`:

```gdscript
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
```

Note the 3×3 neighborhood is an approximation, not a mathematically exhaustive nearest-neighbor search — a site
just outside the 3×3 window can, in rare edge cases, be nearer than anything found inside it (classic bucket-grid
tradeoff). The smoke test's 50-sample brute-force cross-check is the acceptance bar per the spec ("hover/click
accuracy test... assert the spatial-hash selected cell matches a brute-force nearest-site check"), not a proof of
mathematical exhaustiveness — if `bucket_size` is chosen sensibly relative to site spacing (as Task 3/5 will do,
sized from the world's actual site density), the error rate is negligible in practice. Do not over-engineer this
into a full R-tree; the spec explicitly scoped this to the simpler bucket-grid approach.

- [ ] **Step 4: Run to verify it passes**

Run: `godot --headless --script scenes/smoke/CellSpatialHashSmoke.gd`
Expected: `SMOKE PASS: 50/50 nearest() calls matched brute force`, exit 0.

- [ ] **Step 5: Commit**

```bash
cd ~/source/ironband
git add scripts/shared/CellSpatialHash.gd scenes/smoke/CellSpatialHashSmoke.gd
git commit -m "feat(frontend): CellSpatialHash bucket-grid nearest-site lookup

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: `CellIntegration.gd` — headless engine-wiring smoke test for cell worlds

**Files:**
- Create: `scenes/smoke/CellIntegration.gd`

**Interfaces:** none new — exercises the landed engine surface end-to-end headlessly, mirroring
`EngineIntegration.gd`'s pattern but for `cell_graph.bin`. This is the plan's proof that `get_cell_ids`/
`get_cell_sites`/`get_cell_polygon`/`get_location_info`/`location_entered` actually work against real data before
any GlobalMap.gd rendering code depends on them — cheaper to catch data-layer bugs here than in a rendering
context.

- [ ] **Step 1: Write it**

Create `scenes/smoke/CellIntegration.gd`:

```gdscript
extends SceneTree

var locations_entered := 0

func _initialize() -> void:
    var e: Object = ClassDB.instantiate("IronbandEngine")
    get_root().add_child(e)

    var ok: bool = e.load_world("/home/eric/source/ibp-engine/worlds/cheia/cell_graph.bin")
    if not ok:
        push_error("CELL INTEG FAIL: world did not load"); quit(1); return

    if e.get_world_format() != "cellgraph":
        push_error("CELL INTEG FAIL: format = " + e.get_world_format()); quit(1); return

    var ids: PackedInt64Array = e.get_cell_ids()
    var sites: PackedVector2Array = e.get_cell_sites()
    if ids.size() != 26924 or sites.size() != 26924:
        push_error("CELL INTEG FAIL: ids=%d sites=%d, want 26924" % [ids.size(), sites.size()])
        quit(1); return

    var sample_id: int = ids[100]
    var info: Dictionary = e.get_location_info(sample_id)
    if not info.has("biome_id") or not info.has("realm_name"):
        push_error("CELL INTEG FAIL: get_location_info missing fields: " + str(info.keys()))
        quit(1); return

    var poly: PackedVector2Array = e.get_cell_polygon(sample_id)
    if poly.size() < 3:
        push_error("CELL INTEG FAIL: cell %d polygon has %d verts, want >=3" % [sample_id, poly.size()])
        quit(1); return

    var neighbors: PackedInt64Array = e.get_location_neighbors(sample_id)
    if neighbors.size() == 0:
        push_error("CELL INTEG FAIL: cell %d has no neighbors" % sample_id)
        quit(1); return

    var cost: float = e.get_move_cost(sample_id, neighbors[0])
    if cost <= 0.0:
        push_error("CELL INTEG FAIL: move_cost = %f, want > 0" % cost)
        quit(1); return

    e.location_entered.connect(func(_id, _t, _p, _r): locations_entered += 1)
    e.tick(0.1)  # no party path queued; just confirms the signal wiring doesn't error

    print("CELL INTEG PASS: cells=%d sample_polygon_verts=%d neighbors=%d move_cost=%.2f" %
        [ids.size(), poly.size(), neighbors.size(), cost])
    quit(0)
```

- [ ] **Step 2: Run**

Run: `cd ~/source/ironband && godot --headless --script scenes/smoke/CellIntegration.gd`
Expected: `CELL INTEG PASS: cells=26924 ...`, exit 0. If this fails, it is an engine-surface bug (subsystem 2's
territory) surfacing under real data volume rather than the small fixture — fix at the engine layer, not by
weakening this test.

- [ ] **Step 3: Commit**

```bash
cd ~/source/ironband
git add scenes/smoke/CellIntegration.gd
git commit -m "test(frontend): headless smoke test for cell-graph engine wiring

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: `GlobalMap.gd` — world-format branch for texture load

**Files:**
- Modify: `scripts/global/GlobalMap.gd`

**Interfaces:**
- Produces: `GlobalMap.gd` branches on `_engine.get_world_format()` after `load_world` (in `_connect_engine()`,
  L500-507) — on `"cellgraph"`, loads `worlds/<name>/cell_terrain.png` as the base texture instead of building
  `_hex_img` via `_load_hexbin()`; on `"hex"` (or `""`, back-compat), unchanged existing behavior. Does not change
  `WORLD_NAME`'s default (`"ancient"`) — cell-mode is reached via a new `@export var force_cell_test: bool = false`
  dev toggle in the Inspector (or an env/CLI override — implementer's call at Step 3, whichever is less invasive
  to the existing `_ready()` flow) that swaps in `worlds/cheia/cell_graph.bin` for manual testing, per this plan's
  Global Constraints (must not destabilize the live "ancient" hex game world).

- [ ] **Step 1: Read the exact current wiring before editing**

Re-read `scripts/global/GlobalMap.gd` lines 213-284 (`_load_and_render`) and 500-507 (`_connect_engine`) fresh —
this plan's investigation notes are a snapshot; confirm line numbers and exact variable names against the live
file before writing the diff, since Tasks 1-3 above didn't touch this file and it may have moved.

- [ ] **Step 2: Add the format branch**

In `_connect_engine()`, after `_engine.load_world(WORLD_HEX_PATH)` (or the equivalent world-path variable — rename
awareness: if `force_cell_test` is on, load `worlds/cheia/cell_graph.bin` instead), branch:

```gdscript
var world_path := WORLD_HEX_PATH
if force_cell_test:
    world_path = "res://worlds/cheia/cell_graph.bin"
var ok: bool = _engine.load_world(world_path)
...
if _engine.get_world_format() == "cellgraph":
    _load_cellgraph_texture()
else:
    _load_and_render()  # existing hex path, unchanged
```

`_load_cellgraph_texture()` — new method, loads the pre-baked atlas as a straight `Texture2D` (no shader-param
`hex_data`/`burg_data` wiring needed for the base fill — those params are hex-encoding-specific; cell worlds show
routes/rivers as an overlay on top of the flat atlas image, not through the hex shader's per-hex uniform arrays):

```gdscript
func _load_cellgraph_texture() -> void:
    var atlas_path := "res://worlds/cheia/cell_terrain.png"  # TODO: derive from WORLD_NAME once >1 world has an atlas
    var img := Image.load_from_file(ProjectSettings.globalize_path(atlas_path))
    if img == null:
        push_error("GlobalMap: failed to load cell atlas at " + atlas_path)
        return
    var tex := ImageTexture.create_from_image(img)
    _rect.texture = tex
    _rect.material = null  # bypass WorldMap.gdshader entirely for cell worlds' base fill
    _cell_ids = _engine.get_cell_ids()
    _cell_sites = _engine.get_cell_sites()
    _cell_hash = CellSpatialHash.new()
    # Bucket size ~ average nearest-neighbor spacing; cheia's 26924 cells over
    # its map extent gives a reasonable default. Tune during Task 4 Step 4's
    # manual verification if hover feels off, per the spec's bucket-tuning note.
    _cell_hash.build(_cell_ids, _cell_sites, _estimate_bucket_size())
```

`_estimate_bucket_size()` — a small helper: `map_area / cell_count`, square-rooted, times a small constant (e.g.
2.0) so buckets hold a handful of sites each — exact formula is a tuning judgment call at implementation time, not
a spec requirement; log the chosen value.

- [ ] **Step 3: Keep routes/rivers drawing as-is, verify it degrades gracefully**

Per the brief, `_load_routes`/`_load_rivers` are "world-space polylines — format-agnostic, reuse as-is" — but the
investigation found the current hex-snapping/gap-bridging logic (`_world_to_hex` + `_hex_line`,
`BRIDGE_GAP`) is hex-math-specific. For this task, do NOT attempt the land/ocean-aware dash treatment on cell
worlds yet (that requires a cell-aware water test, deferred — see Task 5's note); instead, skip route/river
drawing entirely when `get_world_format() == "cellgraph"` (an explicit, logged skip — "not yet implemented for
cell worlds", not a silent gap) rather than calling hex-specific code with wrong-format assumptions and producing
garbage. This is a scoped reduction from the brief's "reuse as-is" framing, justified by the investigation's
finding that "reuse as-is" undersold the hex-coupling in the current implementation; revisit in a follow-up once
cell-mode routes/rivers rendering is prioritized.

- [ ] **Step 4: Manual verification**

Open the project in Godot 4.6, enable `force_cell_test` on the `GlobalMap` node in the Inspector, run the main
scene. Verify: the cell atlas renders as the base map (visually similar coastline/biome layout to the hex
rendering of the same world), no console errors, camera pan/zoom still works (camera logic is coordinate-system
agnostic, untouched by this task).

- [ ] **Step 5: Commit**

```bash
cd ~/source/ironband
git add scripts/global/GlobalMap.gd
git commit -m "feat(frontend): GlobalMap branches on world format, loads cell atlas

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 5: Spatial-hash hover + polygon outline

**Files:**
- Modify: `scripts/global/GlobalMap.gd`

**Interfaces:**
- Produces: `_update_hover()` (existing, L831-884) branches on world format — cell worlds call
  `_cell_hash.nearest(mouse_world_pos)`, then `get_cell_polygon(id)` to build/update a `Line2D` outline node (new
  child, e.g. `_hover_outline`), replacing the hex-silhouette highlight for that branch. Dev-build accuracy
  self-check (spec requirement: "in dev builds, logs every hover resolution... at the same granularity `_dbg()`
  already provides for hex") — sample-compare against a brute-force scan periodically (e.g. every Nth hover event,
  not every frame, to avoid tanking dev-build frame time) and log any mismatch.

- [ ] **Step 1: Locate the exact insertion point**

Re-read `_update_hover()` (L831-884 per investigation) fresh, confirm current zoom-tier branching
(`zoom_thresh_province`/`zoom_thresh_hex`) still applies at these line numbers.

- [ ] **Step 2: Implement the cell-mode hover branch**

```gdscript
func _update_hover() -> void:
    if _engine.get_world_format() == "cellgraph":
        _update_hover_cellmode()
        return
    # ... existing hex hover logic, unchanged ...

func _update_hover_cellmode() -> void:
    var mouse_world := _rect.get_local_mouse_position()  # or the equivalent existing mouse->world conversion
    var id := _cell_hash.nearest(mouse_world)
    if id == -1:
        return
    if id == _hovered_cell_id:
        return  # no change, skip rebuilding the Line2D every frame
    _hovered_cell_id = id
    var poly: PackedVector2Array = _engine.get_cell_polygon(id)
    if _hover_outline == null:
        _hover_outline = Line2D.new()
        _hover_outline.width = 2.0
        _hover_outline.default_color = Color.YELLOW
        add_child(_hover_outline)
    _hover_outline.points = poly
    _hover_outline.closed = true

    if OS.is_debug_build() and randi() % 20 == 0:  # sample, not every hover — avoid frame-time cost
        _dbg_check_hover_accuracy(mouse_world, id)

func _dbg_check_hover_accuracy(point: Vector2, hash_result: int) -> void:
    var brute_best := -1
    var brute_dist := INF
    for i in range(_cell_sites.size()):
        var d := point.distance_squared_to(_cell_sites[i])
        if d < brute_dist:
            brute_dist = d
            brute_best = _cell_ids[i]
    if brute_best != hash_result:
        push_warning("CellSpatialHash hover mismatch at %s: hash=%d brute=%d" % [point, hash_result, brute_best])
```

Exact mouse→world conversion must match whatever the existing hex `_update_hover` uses (re-read it rather than
guessing — GlobalMap likely already has a `get_global_mouse_position()` or `_rect`-relative conversion in scope).

- [ ] **Step 3: Manual verification**

With `force_cell_test` on, run the scene, move the mouse over the map at both global and (if reachable) closer
zoom — confirm the yellow outline tracks the cell under the cursor, no console warnings from the accuracy
self-check during normal movement (occasional false positives near bucket boundaries are expected per Task 2's
note — a `push_warning`, not a hard failure — but should be rare, not constant).

- [ ] **Step 4: Commit**

```bash
cd ~/source/ironband
git add scripts/global/GlobalMap.gd
git commit -m "feat(frontend): spatial-hash hover + polygon outline for cell worlds

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 6: Selection / info panel + `location_entered` wiring

**Files:**
- Modify: `scripts/global/GlobalMap.gd`

**Interfaces:**
- Produces: click on a cell world calls `get_location_info(id)` (using the same `_cell_hash.nearest()` id already
  resolved by hover) and feeds the existing, format-agnostic info-panel widgets (`_show_info`/`_update_sel_panel`,
  confirmed reusable as-is per the investigation). Connects `_engine.location_entered` (new, alongside the existing
  `hex_entered` connection in `_connect_engine()`) for party-position-driven panel updates — per the brief,
  `hex_entered` stays wired for hex worlds; this task only adds the `location_entered` connection, does not remove
  `hex_entered`.

- [ ] **Step 1: Wire click → info panel**

In whatever click handler currently calls `_select_by_zoom()` (L709-742) for hex worlds, branch: cell worlds use
the id already resolved by `_cell_hash.nearest()` at the click position (same lookup as hover, just triggered on
click instead of continuous mouse-move) and call `_show_info(_engine.get_location_info(id))` or the equivalent
existing panel-population entry point — re-read `_show_info`'s current call sites before wiring, since the
existing hex path likely passes it a differently-shaped dictionary (hex-specific keys) that needs reconciling with
`get_location_info`'s keys (`id, biome_id, is_water, realm_id, province_id, burg_id, elevation, realm_name,
province_name`, plus `q`/`r` only on hex worlds — the panel code must tolerate the missing `q`/`r` on cell worlds,
e.g. hide or omit that row rather than erroring on a missing key).

- [ ] **Step 2: Wire `location_entered`**

In `_connect_engine()`, alongside the existing `_engine.hex_entered.connect(_on_hex_entered)`:

```gdscript
_engine.location_entered.connect(_on_location_entered)
```

```gdscript
func _on_location_entered(id: int, terrain: String, province: String, realm: String) -> void:
    # Fires on BOTH formats (hex_entered only fires on hex worlds) — for hex
    # worlds this duplicates _on_hex_entered's work today; that's expected
    # per the brief ("hex_entered stays until this subsystem migrates the
    # frontend to location_entered" — this task adds the new signal
    # alongside the old one, full migration/removal of _on_hex_entered is a
    # later cleanup once cell-mode is proven out, not part of this task).
    if _engine.get_world_format() != "cellgraph":
        return  # avoid double-handling on hex worlds until the migration happens
    # ... party-position-driven panel/HUD update, cell-world equivalent of
    # whatever _on_hex_entered currently does — re-read that function before
    # writing this body, it is the source of truth for what "entering a
    # location" should trigger in the UI.
```

- [ ] **Step 3: Manual verification**

Click various cells on the cheia cell-world test view — confirm the info panel populates with realm/province
names and biome/elevation data, no errors on cells with no realm (ocean cells, `realm_id == 0`).

- [ ] **Step 4: Commit**

```bash
cd ~/source/ironband
git add scripts/global/GlobalMap.gd
git commit -m "feat(frontend): cell-world click selection + location_entered wiring

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 7: Regional-zoom true polygon borders

**Files:**
- Modify: `scripts/regional/RegionMap.gd`

**Interfaces:**
- Produces: at regional zoom, cell worlds render true polygon borders for viewport-visible cells (spec's
  Rendering-at-Scale decision: "True per-cell polygon rendering... is reserved for regional zoom, where cell
  counts on-screen are low enough"). Culling: build a `CellSpatialHash` over cells whose sites fall within the
  locale's padded world-rect (reusing `_locale_world_rect`, confirmed coordinate-system-agnostic by the
  investigation), then only draw `Line2D`/`Polygon2D` per-cell for that filtered set — not all 26,924 cells.

**This task carries the most open implementation risk in the plan.** The investigation found `RegionMap.gd`'s
windowed-load strategy (`_locale_hex_bounds`, `_hex_to_locale`, the windowed `_load_hexbin(path, wx_min, wx_max,
wy_min, wy_max, pad)` variant) is more deeply hex-coordinate-coupled than `GlobalMap.gd`'s — it computes locale
bounds by scanning hex q/r ranges, not just filtering by world-space rect. A cell-world equivalent needs bounds
computed from cell site/polygon extents within the same world-space locale rect `_apply_fit_camera()` already
produces (that method itself is confirmed coordinate-agnostic). Before writing code:

- [ ] **Step 1: Re-investigate `_locale_hex_bounds`/`_hex_to_locale` at their current line numbers**

Confirm whether `_locale_world_rect` (used by the coordinate-agnostic `_apply_fit_camera`/`_clamp_camera_to_locale`)
is computed independently of `_locale_hex_bounds`, or derived from it. If independent, cell-mode regional loading
can skip the hex-bounds-scanning path entirely and just filter `get_cell_ids()`/`get_cell_sites()` against
`_locale_world_rect` directly — the simple case. If `_locale_world_rect` itself is derived from
`_locale_hex_bounds`'s hex scan, a cell-mode bounds equivalent must be written first (compute the locale rect from
the 5×2 locale grid's world-space cell directly, independent of any hex scan — likely already possible since the
locale grid itself is presumably a fixed world-space partition, not hex-derived, but confirm rather than assume).

- [ ] **Step 2: Implement filtered cell loading + rendering**

```gdscript
func _load_cellmode_locale() -> void:
    var all_ids: PackedInt64Array = _engine.get_cell_ids()
    var all_sites: PackedVector2Array = _engine.get_cell_sites()
    var visible_ids: Array[int] = []
    var visible_sites := PackedVector2Array()
    for i in range(all_ids.size()):
        if _locale_world_rect.has_point(all_sites[i]):
            visible_ids.append(all_ids[i])
            visible_sites.append(all_sites[i])
    _cell_hash = CellSpatialHash.new()
    _cell_hash.build(PackedInt64Array(visible_ids), visible_sites, _estimate_bucket_size())
    for id in visible_ids:
        var poly: PackedVector2Array = _engine.get_cell_polygon(id)
        var outline := Line2D.new()
        outline.points = poly
        outline.closed = true
        outline.width = 1.0
        outline.default_color = _biome_border_color(id)  # or a flat color; polish detail, not a spec requirement
        add_child(outline)
```

No fill needed at regional zoom per the brief's decision (global atlas covers fills; regional adds true borders on
top of... note: regional zoom currently has NO base fill for cell worlds yet, since Task 4 only wired the global
atlas — regional zoom will need either the same atlas texture zoomed in, or per-cell `Polygon2D` fills. Re-check
the brief/spec: the brief's item 5 says "true polygons at regional zoom" without specifying fill vs. outline-only
— the spec's Rendering at Scale section discusses fills as the expensive part specifically at global zoom, and is
silent on whether regional needs filled polygons or just outlines over the atlas. Implementer's call at this step:
outline-only (reusing the global atlas, zoomed, as the base fill even at regional zoom) is the lower-risk default
if ambiguous — document the choice in the commit message so it's revisitable.

- [ ] **Step 3: Manual verification**

Enter a locale on the cheia cell world (via whatever entry path `force_cell_test` + double-click currently
triggers, or a temporary direct scene-load shortcut for testing) — confirm true polygon outlines render for
cells in view, camera pan/zoom/clamp behavior unchanged from the hex path (since `_apply_fit_camera`/
`_clamp_camera_to_locale` are untouched), no errors when the locale contains 0 cells (edge locale near map border).

- [ ] **Step 4: Commit**

```bash
cd ~/source/ironband
git add scripts/regional/RegionMap.gd
git commit -m "feat(frontend): regional-zoom true polygon borders for cell worlds

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 8: Side-by-side verification + retirement-criterion evidence

**Files:** none created — manual/scripted verification, documented in a follow-up note (per spec Testing
Strategy's "Manual/visual" category, and matching how subsystem 2 handled its own real-data smoke task).

**Interfaces:** none new.

- [ ] **Step 1: Side-by-side hex vs. cell comparison (retirement criterion c)**

With both `force_cell_test = false` and `= true` loading the same underlying cheia source data (hex via
`hex_grid.hexbin`, cell via `cell_graph.bin` — both generated from the same `azgaar.json`), visually compare
coastline placement, river continuity, and route alignment at a few sample regions. Record findings (pass/fail per
bug class: coastal, river, route) in a short note appended to this plan file's bottom (not a new doc) — this is
the evidence criterion (c) in the spec's hex-retirement section needs, not a pass/fail gate for this plan itself
(criterion evaluation is a separate, later decision per the spec).

- [ ] **Step 2: Global-zoom frame-time comparison (retirement criterion b)**

Using Godot's built-in profiler (or a simple `Time.get_ticks_usec()` bracket around the render/process step),
compare global-zoom frame time for the cheia hex world vs. the cheia cell world (both should be rendering a
pre-baked texture at this zoom tier per Task 4 — if cell-mode frame time is notably worse, that indicates a bug in
the atlas-loading path, not an inherent cost, per the spec's "Performance target" note). Record the numbers in the
same follow-up note as Step 1.

- [ ] **Step 3: Append findings**

Add a `## Verification Findings (post-implementation)` section to the bottom of this plan file with the two
results above, dated. No commit message template needed — this is documentation, committed as its own small commit:

```bash
cd ~/source/ironband
git add docs/superpowers/plans/2026-07-03-frontend-cellmode-plan.md
git commit -m "docs: record hex-vs-cell verification findings (retirement criteria b/c)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Self-Review Notes

- **Spec coverage:** Interaction Model (hover/click spatial hash) → Tasks 2, 5, 6. Rendering at Scale (texture
  atlas at global, true polygons at regional) → Tasks 1, 4, 7. Error Handling/Logging (bucket occupancy stats,
  dev-build hover accuracy self-check) → Tasks 2, 5. Testing Strategy's four categories: offline-tooling golden
  tests → Task 1; adjacency contract tests → already covered by subsystem 2, not re-scoped here; hover/click
  accuracy test → Task 2's smoke test + Task 5's dev-build sampling; manual/visual side-by-side → Task 8.
  Hex-retirement criteria (b) performance and (c) bug-class-absence → Task 8 (evidence-gathering only; the
  retirement decision itself stays a separate, outcome-based call per the spec).
- **Deliberate scope reduction vs. the brief:** routes/rivers rendering on cell worlds is explicitly skipped (Task
  4 Step 3) rather than "reused as-is" as the brief's wording suggested — the investigation found the current
  implementation more hex-coupled than the brief assumed. This is flagged, not silently dropped; a follow-up task
  should pick this up once the core rendering/hover/selection loop is proven out.
- **Genuinely open implementation risk:** Task 7 (regional-zoom cell rendering) depends on confirming whether
  `RegionMap.gd`'s locale-bounds computation is hex-coupled beyond what the investigation could fully resolve
  without deeper reading — Step 1 of that task is explicitly a re-investigation step before code, not a
  copy-paste-ready diff, unlike subsystem 2's fully-specified C++ tasks. This reflects genuine uncertainty in the
  source material, not a shortcut.
- **Not covered (deferred by design, matching the brief and spec):** retiring `hex_entered`/full frontend
  migration to `location_entered` (only additive wiring here); cell-world route/river rendering (Task 4 Step 3);
  `TriggerSystem` generalization to cell worlds (subsystem-2 self-review note, still applies — party movement
  isn't wired to cell worlds at the gameplay level, only to the test/dev `force_cell_test` rendering path this
  plan adds); reconciling the three disagreeing biome palettes (Global Constraints) beyond this plan's own new
  tool matching the shader.
- **Test-strategy honesty:** unlike subsystem 2 (C++, full doctest TDD), this plan cannot claim unit-test coverage
  for on-screen rendering correctness — there is no harness for that in this repo. What IS tested automatically:
  the Python atlas tool (pytest-style), the spatial hash's correctness (headless smoke, brute-force cross-check),
  and the engine data-wiring surface under real data volume (headless smoke). Rendering/hover-feel/visual
  correctness is manual, and this plan says so explicitly rather than overclaiming.

## Verification Findings (post-implementation)

**2026-07-03, first manual verification pass:**

- **Pre-existing blocker found and fixed:** `bin/libironband.linux.template_debug.x86_64.so` was stale (built
  2026-06-29), predating the `feature/rivers-elevation` merge that added `CellGraph`/`get_world_format()`/
  `get_cell_ids()` etc. to the engine. Enabling `force_cell_test` against the stale binary produced "could not
  load cell graph" (`GlobalMap.gd`'s `CELL_GRAPH_PATH` load-failure branch). Rebuilt via
  `scons platform=linux target=template_debug -j24` in `gdextension/` — links clean, `strings` on the output
  confirms `cellgraph`/`get_world_format` symbols present. After a Godot editor project reload (required — the
  editor does not hot-reload a GDExtension `.so` replaced on disk), `force_cell_test` loads and renders cheia's
  cell-graph world correctly.
- **Step 1 (coastal/river/route comparison, criterion c):** user's initial visual check with `force_cell_test`
  enabled reports the cell-world rendering "looks good so far" — no crashes, no console errors observed, basic
  coastline/biome layout renders as expected. This is a preliminary sanity check, not the full side-by-side
  hex-vs-cell comparison the plan calls for (route/river drawing is explicitly skipped on cell worlds per Task 4
  Step 3, so those two bug classes are not yet evaluable here — only coastal placement is currently comparable).
  **Still open:** deliberate side-by-side against the hex rendering of the same cheia region, and a documented
  pass/fail per bug class (coastal/river/route).
- **Follow-up side-by-side:** user then stopped the scene, toggled `force_cell_test` off, re-ran (hex mode), and
  compared against the cell-mode run — reports it "looks fine". Coastal placement matches between the two
  renderings of cheia; no other discrepancies flagged. Route/river bug classes remain not-evaluable on the cell
  side per the note above (they're not drawn there yet), so this is a coastal-placement pass, not a full three-way
  bug-class clearance.
- **Step 2 (global-zoom frame-time comparison, criterion b):** not yet measured. Still open — needs a profiler
  read (Debugger → Monitors/Profiler) at global zoom for both `force_cell_test = false` and `= true`.

**Next steps for whoever picks this back up:** gather the two open items above with the now-working build, then
replace this note with the full findings this section is meant to hold.
