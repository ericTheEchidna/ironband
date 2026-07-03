# azgaar_to_cellgraph.py Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `azgaar_to_cellgraph.py`, an offline converter that turns an Azgaar Fantasy Map Generator JSON export into a `cell_graph.bin` binary — Azgaar's native Voronoi cells kept as the graph, with no hex rasterization step — as the first, independently-shippable subsystem of the freeform-worldmap design.

**Architecture:** A single Python script mirroring the structure and binary-format conventions of the existing `tools/azgaar_to_hex.py`. Cell/vertex data is extracted from `pack.cells`/`pack.vertices` into an in-memory `CellRecord` list, repaired (degenerate cells merged, adjacency symmetrized), validated (site-separation warnings logged), then packed into `cell_graph.bin`. A `read_cellgraph_bin()` function in the same module provides a round-trip reader used by tests (and later, as a reference for the eventual C++ reader). No engine, no frontend, no `WorldMap` involvement — this plan produces a working, testable file format and converter on its own, per [2026-07-02-freeform-worldmap-design.md](../specs/2026-07-02-freeform-worldmap-design.md).

**Tech Stack:** Python 3.14 (matches the environment; script itself only requires 3.10+ for `from __future__ import annotations` + dataclasses, matching `azgaar_to_hex.py`'s style), stdlib only (`json`, `struct`, `argparse`, `logging`, `dataclasses`, `pathlib`, `zlib`) — no new dependencies. Tests use stdlib `unittest` (no `pytest` installed anywhere in this repo; do not add it).

---

## AMENDMENT (2026-07-03): Full-fidelity format — supersedes the embedded code below

**User direction:** carry *all* available data from the Azgaar JSON, not just the fields the hex path carries. A
fresh-eyes reassessment had found the original v1 cell record was missing three fields hexbin carries (`elevation`,
`river_flow`, route flags) — two of them load-bearing (the active `feature/rivers-elevation` branch needs elevation;
the spec's own `move_cost` formula needs road flags). The user then widened the scope to full fidelity, including
the economy module (`goods` ×71, `deals` ×30,598, `markets` ×66, per-burg `production`) that a parallel review
agent confirmed was heading for silent omission.

**Resulting design (implemented and verified 2026-07-03):**
- Every flat per-cell field is carried (all 23 keys of `pack.cells`, incl. `h`, `fl`, `conf`, `area`, `s`, `t`,
  `f`, `g`, `haven`, `culture`, `religion`, `pop`), 64-byte cell records.
- Grid climate (`temp`, `prec`) is baked per-cell at build time by dereferencing `grid.cells` via each cell's `g`.
- Per-edge route ids (`cell.routes`) are stored as a u16 array parallel to the neighbors array (0xFFFF = no route).
- Full flat tables: cultures, religions, rivers **including ordered cell paths** (this resolves the spec's
  "rivers on the cell graph" open question — Azgaar exports each river's cell path directly), features including
  coastline outline vertices, zones, markers, notes, routes including world-space polylines, expanded
  burgs/states/provinces.
- A 48-byte meta block carries map extent, `settings.distanceScale`/`distanceUnit` (the real-world calibration
  `move_cost`'s `HOURS_PER_UNIT` needs), lat/lon extents, map name and seed.
- Everything nested/cold — goods/deals/markets, production recipes, COA heraldry, diplomacy/campaign histories,
  culture/religion origins, nameBases, full settings/info — is carried verbatim in a zlib-compressed JSON
  **extras** section at the end of the file. Nothing in the Azgaar export is dropped.
- **Id convention change:** every id in `cell_graph.bin` is Azgaar's *native* id (the original plan borrowed
  hexbin's 1-based-table-index convention for `burg_id`). Every table row carries its own id field; loaders build
  id→index maps in one pass. With eleven cross-referencing tables, one uniform convention beats per-table remaps.

**Verification:** 30/30 unit tests; real cheia conversion (26,924 cells, 0 merged/dropped, 4.9 MB, ~1.3 s) with
field-exact round-trip spot-checks against the source JSON, river-path fidelity, 23,180 routed edges, extras
integrity. Two real-data bugs caught and fixed during verification: header strtab-size captured before meta strings
were added; unpaired UTF-16 surrogates in note legends (now replaced with a logged warning).

**Status of the embedded code below:** the code blocks in Tasks 1 and 5 (and the fixture/`make_cell` helpers)
reflect the original narrow format and are **superseded** by the implementation on the `feature/azgaar-cellgraph`
branch (`tools/azgaar_to_cellgraph.py`, commits `e59c811..863cfad`). The authoritative binary-format spec is the
module docstring in that file. Task structure, repair semantics (Tasks 2-4), CLI shape (Task 6), and the smoke-test
procedure (Task 7) are unchanged. All seven tasks are complete as of this amendment.

---

## Global Constraints

- **Repo:** all files in this plan live in `~/source/ibp-engine` (NOT `ironband` — this plan doc lives in `ironband/docs/superpowers/plans/` per project convention, but every file path below is relative to `ibp-engine`).
- **No hex rasterization.** This converter must never build a hex grid, call `hex_round`, or reference `q`/`r` axial coordinates — that's `azgaar_to_hex.py`'s job. This script reads `pack.cells`/`pack.vertices` directly.
- **Binary format is little-endian throughout** (`struct` format strings start with `<`, no padding).
- **Follow `azgaar_to_hex.py`'s conventions exactly** where they overlap: string table with offset 0 = empty string, `u32` string offsets, biome offsets indexed by `biome_id`. ~~burg table indexed `burg_id=1 → index 0`~~ *(superseded by the 2026-07-03 amendment: all ids are Azgaar-native; see above)*.
- **Logging, not print.** Use the stdlib `logging` module (`logger = logging.getLogger("azgaar_to_cellgraph")`) for every diagnostic — degenerate-cell merges, adjacency repairs, site-separation warnings, per-run summary. Do not use `print()` for anything except final CLI success/failure messages.
- **Binary format spec** *(SUPERSEDED by the 2026-07-03 full-fidelity amendment above — the authoritative spec is now the module docstring of `tools/azgaar_to_cellgraph.py` on `feature/azgaar-cellgraph`; the original narrow v1 layout is kept below for history)*:
  - Header, 34 bytes, format `<4sHHIIHHHIII`: `magic[4]="CGB1"`, `version:u16=1`, `biome_count:u16`, `cell_count:u32`, `strtab_size:u32`, `realm_count:u16`, `province_count:u16`, `burg_count:u16`, `vertex_count:u32`, `neighbor_total:u32`, `border_total:u32`.
  - Sections in order after header: strtab (`strtab_size` bytes), biome offsets (`biome_count`×u32), realms (`realm_count`×`<HI>` = 6 bytes: `{id:u16, name_offset:u32}`), provinces (`province_count`×`<HII>` = 10 bytes: `{id:u16, name_offset:u32, capital_offset:u32}`), burgs (`burg_count`×u32 name offsets), vertices (`vertex_count`×`<ff>` = 8 bytes: `{x:f32, y:f32}`), cells (`cell_count`×34-byte records, format `<IffBHHHBBHIHIB`: `{id:u32, cx:f32, cy:f32, biome_id:u8, realm_id:u16, province_id:u16, burg_id:u16, is_water:u8, harbor:u8, river_id:u16, border_start:u32, border_count:u16, neighbor_start:u32, neighbor_count:u8}`), borders (`border_total`×u32 vertex indices, sliced per cell via `border_start`/`border_count`), neighbors (`neighbor_total`×u32 cell ids, sliced per cell via `neighbor_start`/`neighbor_count`).

---

## File Structure

- **Create:** `tools/azgaar_to_cellgraph.py` — the converter: `CellRecord` dataclass, extraction, repair, validation, binary writer, binary reader, CLI.
- **Create:** `tools/test_azgaar_to_cellgraph.py` — `unittest`-based tests. Builds tiny synthetic Azgaar-shaped fixtures inline (no committed fixture JSON files — a real Azgaar export is 25-40MB, far too large for a unit-test fixture).

---

### Task 1: Cell and vertex extraction

**Files:**
- Create: `tools/azgaar_to_cellgraph.py`
- Test: `tools/test_azgaar_to_cellgraph.py`

**Interfaces:**
- Produces: `CellRecord` dataclass with fields `id: int`, `cx: float`, `cy: float`, `biome_id: int`, `realm_id: int`, `realm_name: str`, `province_id: int`, `province_name: str`, `province_capital: str`, `is_water: bool`, `burg: str`, `burg_azgaar_id: int` (Azgaar's own `burg["i"]`, `0` if no burg — resolved to the binary format's 1-based table index in Task 5, not written directly), `harbor: int`, `river_id: int`, `border: list[int]` (vertex indices, in polygon order), `neighbors: list[int]` (cell ids). Produces `extract_cells(data: dict) -> list[CellRecord]`.

- [ ] **Step 1: Write the failing test**

Create `tools/test_azgaar_to_cellgraph.py`:

```python
"""Tests for azgaar_to_cellgraph.py."""
from __future__ import annotations

import unittest

from azgaar_to_cellgraph import CellRecord, extract_cells


def make_fixture() -> dict:
    """A tiny synthetic Azgaar-shaped export: 4 cells in a diamond, one
    marine (biome 0), plus enough vertices/states/provinces/burgs to
    exercise every extraction path."""
    return {
        "biomesData": {"name": ["Marine", "Grassland", "Forest"]},
        "pack": {
            "cells": [
                {  # cell 0: land, has a burg, in state 1 / province 1
                    "i": 0, "p": [10.0, 10.0], "v": [0, 1, 2, 3],
                    "c": [1, 2, 3], "biome": 1, "state": 1, "province": 1,
                    "h": 40, "fl": 5, "r": 0, "t": 2, "harbor": 0,
                    "culture": 1, "religion": 1, "routes": {},
                },
                {  # cell 1: marine neighbor (is_water)
                    "i": 1, "p": [20.0, 10.0], "v": [1, 4, 5, 2],
                    "c": [0, 2], "biome": 0, "state": 0, "province": 0,
                    "h": 0, "fl": 0, "r": 0, "t": -1, "harbor": 0,
                    "culture": 0, "religion": 0, "routes": {},
                },
                {  # cell 2: land, no burg, has a named river
                    "i": 2, "p": [10.0, 20.0], "v": [2, 5, 6, 3],
                    "c": [0, 1, 3], "biome": 2, "state": 1, "province": 1,
                    "h": 55, "fl": 30, "r": 7, "t": 1, "harbor": 0,
                    "culture": 1, "religion": 1, "routes": {},
                },
                {  # cell 3: land, coastal harbor
                    "i": 3, "p": [0.0, 10.0], "v": [0, 3, 6, 7],
                    "c": [0, 2], "biome": 1, "state": 1, "province": 1,
                    "h": 45, "fl": 5, "r": 0, "t": 1, "harbor": 1,
                    "culture": 1, "religion": 1, "routes": {},
                },
            ],
            "vertices": [
                {"i": 0, "p": [5.0, 5.0]},
                {"i": 1, "p": [15.0, 5.0]},
                {"i": 2, "p": [15.0, 15.0]},
                {"i": 3, "p": [5.0, 15.0]},
                {"i": 4, "p": [25.0, 5.0]},
                {"i": 5, "p": [15.0, 20.0]},
                {"i": 6, "p": [5.0, 20.0]},
                {"i": 7, "p": [0.0, 15.0]},
            ],
            "burgs": [{"i": 1, "name": "Rivergate", "cell": 0}],
            "states": [{"i": 1, "name": "Freehold"}],
            "provinces": [
                {"i": 1, "name": "Vale", "fullName": "The Vale", "burg": 1},
            ],
            "routes": [],
        },
    }


class ExtractCellsTest(unittest.TestCase):
    def test_extracts_all_cells(self) -> None:
        records = extract_cells(make_fixture())
        self.assertEqual(len(records), 4)

    def test_land_cell_attributes(self) -> None:
        records = extract_cells(make_fixture())
        c0 = records[0]
        self.assertEqual(c0.id, 0)
        self.assertEqual((c0.cx, c0.cy), (10.0, 10.0))
        self.assertEqual(c0.biome_id, 1)
        self.assertEqual(c0.realm_id, 1)
        self.assertEqual(c0.realm_name, "Freehold")
        self.assertEqual(c0.province_id, 1)
        self.assertEqual(c0.province_name, "The Vale")
        self.assertEqual(c0.province_capital, "Rivergate")
        self.assertFalse(c0.is_water)
        self.assertEqual(c0.burg, "Rivergate")
        self.assertEqual(c0.burg_azgaar_id, 1)
        self.assertEqual(c0.border, [0, 1, 2, 3])
        self.assertEqual(c0.neighbors, [1, 2, 3])

    def test_marine_cell_is_water(self) -> None:
        records = extract_cells(make_fixture())
        self.assertTrue(records[1].is_water)
        self.assertEqual(records[1].burg, "")
        self.assertEqual(records[1].burg_azgaar_id, 0)

    def test_river_id_carried_through(self) -> None:
        records = extract_cells(make_fixture())
        self.assertEqual(records[2].river_id, 7)
        self.assertEqual(records[0].river_id, 0)

    def test_harbor_flag_carried_through(self) -> None:
        records = extract_cells(make_fixture())
        self.assertEqual(records[3].harbor, 1)
        self.assertEqual(records[0].harbor, 0)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_azgaar_to_cellgraph -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'azgaar_to_cellgraph'`

- [ ] **Step 3: Write minimal implementation**

Create `tools/azgaar_to_cellgraph.py`:

```python
#!/usr/bin/env python3
"""
azgaar_to_cellgraph.py — Convert an Azgaar Fantasy Map Generator JSON
export to a native-cell graph binary (.bin) for the Ironband engine.

Unlike azgaar_to_hex.py, this converter performs NO rasterization: Azgaar's
own Voronoi cells (pack.cells) are the graph's nodes, and pack.cells[i]["c"]
is used directly as the adjacency list. See
docs/superpowers/specs/2026-07-02-freeform-worldmap-design.md (ironband repo)
for the design this implements.

Usage:
    python tools/azgaar_to_cellgraph.py worlds/cheia/azgaar.json

Output: cell_graph.bin alongside the input file.

Binary format (.bin), all little-endian:
  Header    34 bytes  magic "CGB1", counts
  Strtab    variable  null-terminated UTF-8 strings; offset 0 = empty string
  Biomes    N×4 B     u32 offsets into strtab, indexed by biome_id
  Realms    N×6 B     { u16 realm_id, u32 name_offset }
  Provs     N×10 B    { u16 province_id, u32 name_offset, u32 capital_offset }
  Burgs     N×4 B     u32 offsets (burg_id=1 -> index 0)
  Vertices  N×8 B     { f32 x, f32 y }
  Cells     N×34 B    { u32 id, f32 cx, f32 cy, u8 biome_id, u16 realm_id,
                        u16 province_id, u16 burg_id, u8 is_water, u8 harbor,
                        u16 river_id, u32 border_start, u16 border_count,
                        u32 neighbor_start, u8 neighbor_count }
  Borders   N×4 B     u32 vertex indices, sliced per cell
  Neighbors N×4 B     u32 cell ids, sliced per cell
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger("azgaar_to_cellgraph")


@dataclass
class CellRecord:
    id: int
    cx: float
    cy: float
    biome_id: int
    realm_id: int
    realm_name: str
    province_id: int
    province_name: str
    province_capital: str
    is_water: bool
    burg: str
    burg_azgaar_id: int
    harbor: int
    river_id: int
    border: list[int] = field(default_factory=list)
    neighbors: list[int] = field(default_factory=list)


def extract_cells(data: dict[str, Any]) -> list[CellRecord]:
    """Return one CellRecord per pack.cells entry, in cell-index order."""
    pack = data["pack"]
    cells = pack["cells"]
    biome_names: list[str] = data["biomesData"]["name"]

    burg_id_by_cell: dict[int, int] = {}
    burg_name_by_idx: dict[int, str] = {}
    for burg in pack.get("burgs", []):
        if isinstance(burg, dict) and "i" in burg:
            burg_name_by_idx[burg["i"]] = burg.get("name", "")
        if isinstance(burg, dict) and "cell" in burg:
            burg_id_by_cell[burg["cell"]] = burg.get("i", 0)

    state_name: dict[int, str] = {
        s["i"]: s.get("name", "") for s in pack.get("states", []) if isinstance(s, dict)
    }

    province_info: dict[int, dict[str, str]] = {}
    for p in pack.get("provinces", []):
        if isinstance(p, dict) and "i" in p:
            capital = burg_name_by_idx.get(p.get("burg", 0), "")
            province_info[p["i"]] = {
                "name": p.get("name", ""),
                "full_name": p.get("fullName", p.get("name", "")),
                "capital": capital,
            }

    records: list[CellRecord] = []
    for cell in cells:
        biome_idx = cell.get("biome", 0)
        state_id = cell.get("state", 0)
        province_id = cell.get("province", 0)
        prov = province_info.get(province_id, {})
        x, y = cell["p"]
        burg_azgaar_id = burg_id_by_cell.get(cell["i"], 0)

        records.append(CellRecord(
            id=cell["i"],
            cx=float(x),
            cy=float(y),
            biome_id=biome_idx,
            realm_id=state_id,
            realm_name=state_name.get(state_id, ""),
            province_id=province_id,
            province_name=prov.get("full_name", ""),
            province_capital=prov.get("capital", ""),
            is_water=biome_idx == 0,
            burg=burg_name_by_idx.get(burg_azgaar_id, ""),
            burg_azgaar_id=burg_azgaar_id,
            harbor=cell.get("harbor", 0),
            river_id=cell.get("r", 0),
            border=list(cell.get("v", [])),
            neighbors=list(cell.get("c", [])),
        ))

    return records
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_azgaar_to_cellgraph -v`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
cd ~/source/ibp-engine
git add tools/azgaar_to_cellgraph.py tools/test_azgaar_to_cellgraph.py
git commit -m "feat(cellgraph): extract CellRecords from Azgaar pack.cells"
```

---

### Task 2: Degenerate-cell detection and repair

**Files:**
- Modify: `tools/azgaar_to_cellgraph.py`
- Test: `tools/test_azgaar_to_cellgraph.py`

**Interfaces:**
- Consumes: `CellRecord` (Task 1).
- Produces: `repair_degenerate_cells(records: list[CellRecord]) -> list[CellRecord]`. A cell is degenerate if `len(border) < 3` (can't form a polygon) or `len(neighbors) < 1` (disconnected). Degenerate cells are merged into their first remaining valid neighbor (or, if they have zero neighbors, dropped entirely and logged as unrepairable) — every other cell's `neighbors` list has the merged cell's id replaced by the target's id (deduplicated, self-references removed). Every merge/drop is logged via `logger.warning` with the cell id and reason.

- [ ] **Step 1: Write the failing test**

Add to `tools/test_azgaar_to_cellgraph.py` (new imports and test class):

```python
from azgaar_to_cellgraph import CellRecord, extract_cells, repair_degenerate_cells


def make_cell(id: int, neighbors: list[int], border: list[int] | None = None) -> CellRecord:
    return CellRecord(
        id=id, cx=float(id), cy=0.0, biome_id=1, realm_id=0, realm_name="",
        province_id=0, province_name="", province_capital="", is_water=False,
        burg="", burg_azgaar_id=0, harbor=0, river_id=0,
        border=border if border is not None else [id, id + 100, id + 200],
        neighbors=neighbors,
    )


class RepairDegenerateCellsTest(unittest.TestCase):
    def test_no_degenerate_cells_unchanged(self) -> None:
        records = [make_cell(0, [1]), make_cell(1, [0])]
        repaired = repair_degenerate_cells(records)
        self.assertEqual({c.id for c in repaired}, {0, 1})

    def test_short_border_cell_merged_into_first_neighbor(self) -> None:
        # cell 2 has only 2 border vertices -> degenerate, merges into cell 0
        records = [
            make_cell(0, [1, 2]),
            make_cell(1, [0, 2]),
            make_cell(2, [0, 1], border=[5, 6]),
        ]
        repaired = repair_degenerate_cells(records)
        self.assertEqual({c.id for c in repaired}, {0, 1})
        # cell 1's neighbor list no longer references dropped cell 2
        by_id = {c.id: c for c in repaired}
        self.assertEqual(sorted(by_id[1].neighbors), [0])

    def test_neighborless_cell_dropped_and_logged(self) -> None:
        records = [make_cell(0, []), make_cell(1, [])]
        with self.assertLogs("azgaar_to_cellgraph", level="WARNING") as log:
            repaired = repair_degenerate_cells(records)
        self.assertEqual(repaired, [])
        self.assertTrue(any("zero neighbors" in msg for msg in log.output))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_azgaar_to_cellgraph -v`
Expected: FAIL with `ImportError: cannot import name 'repair_degenerate_cells'`

- [ ] **Step 3: Write minimal implementation**

Add to `tools/azgaar_to_cellgraph.py`:

```python
def repair_degenerate_cells(records: list[CellRecord]) -> list[CellRecord]:
    """Merge cells with <3 border vertices into a neighbor; drop cells with
    zero neighbors entirely (nothing to merge into). Every removed cell's id
    is replaced by its merge target in every remaining cell's neighbor list.
    """
    by_id = {r.id: r for r in records}
    merge_target: dict[int, int] = {}

    for r in records:
        if len(r.neighbors) == 0:
            logger.warning("cell %d has zero neighbors — dropping (unrepairable)", r.id)
            merge_target[r.id] = -1
        elif len(r.border) < 3:
            target = r.neighbors[0]
            logger.warning(
                "cell %d has degenerate border (%d vertices) — merging into cell %d",
                r.id, len(r.border), target,
            )
            merge_target[r.id] = target

    survivors = [r for r in records if r.id not in merge_target]

    def resolve(cell_id: int) -> int:
        seen = set()
        while cell_id in merge_target:
            if cell_id in seen:
                return -1  # merge cycle guard, treat as dropped
            seen.add(cell_id)
            cell_id = merge_target[cell_id]
        return cell_id

    for r in survivors:
        resolved = []
        for n in r.neighbors:
            rn = resolve(n)
            if rn != -1 and rn != r.id and rn not in resolved:
                resolved.append(rn)
        r.neighbors = resolved

    return survivors
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_azgaar_to_cellgraph -v`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
cd ~/source/ibp-engine
git add tools/azgaar_to_cellgraph.py tools/test_azgaar_to_cellgraph.py
git commit -m "feat(cellgraph): merge/drop degenerate cells with logging"
```

---

### Task 3: Adjacency symmetry repair

**Files:**
- Modify: `tools/azgaar_to_cellgraph.py`
- Test: `tools/test_azgaar_to_cellgraph.py`

**Interfaces:**
- Consumes: `CellRecord` (Task 1), output of `repair_degenerate_cells` (Task 2).
- Produces: `repair_adjacency_symmetry(records: list[CellRecord]) -> list[CellRecord]`. For every cell A that lists B as a neighbor, ensures B lists A too — mutates and returns the same records. Logs one `logger.warning` per asymmetric pair fixed, plus a final `logger.info` summary count.

- [ ] **Step 1: Write the failing test**

Add to `tools/test_azgaar_to_cellgraph.py`:

```python
from azgaar_to_cellgraph import (
    CellRecord, extract_cells, repair_degenerate_cells, repair_adjacency_symmetry,
)


class RepairAdjacencySymmetryTest(unittest.TestCase):
    def test_symmetric_adjacency_unchanged(self) -> None:
        records = [make_cell(0, [1]), make_cell(1, [0])]
        repaired = repair_adjacency_symmetry(records)
        by_id = {c.id: c for c in repaired}
        self.assertEqual(by_id[0].neighbors, [1])
        self.assertEqual(by_id[1].neighbors, [0])

    def test_asymmetric_adjacency_fixed(self) -> None:
        # 0 -> 1 but not 1 -> 0
        records = [make_cell(0, [1]), make_cell(1, [])]
        with self.assertLogs("azgaar_to_cellgraph", level="WARNING") as log:
            repaired = repair_adjacency_symmetry(records)
        by_id = {c.id: c for c in repaired}
        self.assertIn(0, by_id[1].neighbors)
        self.assertTrue(any("asymmetric" in msg for msg in log.output))

    def test_all_pairs_symmetric_after_repair(self) -> None:
        records = [make_cell(0, [1, 2]), make_cell(1, []), make_cell(2, [0])]
        repaired = repair_adjacency_symmetry(records)
        by_id = {c.id: c for c in repaired}
        for c in repaired:
            for n in c.neighbors:
                self.assertIn(c.id, by_id[n].neighbors, f"{c.id}->{n} not reciprocated")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_azgaar_to_cellgraph -v`
Expected: FAIL with `ImportError: cannot import name 'repair_adjacency_symmetry'`

- [ ] **Step 3: Write minimal implementation**

Add to `tools/azgaar_to_cellgraph.py`:

```python
def repair_adjacency_symmetry(records: list[CellRecord]) -> list[CellRecord]:
    """Ensure every neighbor relationship is reciprocated. Mutates in place."""
    by_id = {r.id: r for r in records}
    fixed = 0

    for r in records:
        for n in r.neighbors:
            neighbor = by_id.get(n)
            if neighbor is not None and r.id not in neighbor.neighbors:
                logger.warning("asymmetric adjacency %d->%d — adding reverse edge", r.id, n)
                neighbor.neighbors.append(r.id)
                fixed += 1

    logger.info("adjacency symmetry: %d reverse edges added", fixed)
    return records
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_azgaar_to_cellgraph -v`
Expected: PASS (11 tests)

- [ ] **Step 5: Commit**

```bash
cd ~/source/ibp-engine
git add tools/azgaar_to_cellgraph.py tools/test_azgaar_to_cellgraph.py
git commit -m "feat(cellgraph): repair asymmetric adjacency with logging"
```

---

### Task 4: Site-separation validation

**Files:**
- Modify: `tools/azgaar_to_cellgraph.py`
- Test: `tools/test_azgaar_to_cellgraph.py`

**Interfaces:**
- Consumes: `CellRecord` (Task 1).
- Produces: `check_site_separation(records: list[CellRecord], min_separation: float = 0.5) -> int`. Checks each cell's centroid distance against its direct neighbors only (not full O(n²) — real worlds have tens of thousands of cells, and near-duplicate sites are a neighbor-adjacency phenomenon, not a global one). Logs one `logger.warning` per pair closer than `min_separation`, in Azgaar's world-space units matching `cell.p`. Returns the count of violations found (logging-only — no coordinate nudging in this iteration, matching the spec's decision to defer nudging).

- [ ] **Step 1: Write the failing test**

Add to `tools/test_azgaar_to_cellgraph.py`:

```python
from azgaar_to_cellgraph import (
    CellRecord, extract_cells, repair_degenerate_cells, repair_adjacency_symmetry,
    check_site_separation,
)


def make_cell_at(id: int, cx: float, cy: float, neighbors: list[int]) -> CellRecord:
    c = make_cell(id, neighbors)
    c.cx, c.cy = cx, cy
    return c


class CheckSiteSeparationTest(unittest.TestCase):
    def test_well_separated_sites_no_warnings(self) -> None:
        records = [make_cell_at(0, 0.0, 0.0, [1]), make_cell_at(1, 10.0, 0.0, [0])]
        count = check_site_separation(records, min_separation=0.5)
        self.assertEqual(count, 0)

    def test_near_duplicate_sites_logged(self) -> None:
        records = [make_cell_at(0, 0.0, 0.0, [1]), make_cell_at(1, 0.1, 0.0, [0])]
        with self.assertLogs("azgaar_to_cellgraph", level="WARNING") as log:
            count = check_site_separation(records, min_separation=0.5)
        self.assertEqual(count, 1)
        self.assertTrue(any("near-duplicate" in msg for msg in log.output))

    def test_only_checks_direct_neighbors(self) -> None:
        # cells 0 and 2 are near-duplicate but NOT neighbors -> not checked
        records = [
            make_cell_at(0, 0.0, 0.0, [1]),
            make_cell_at(1, 10.0, 0.0, [0]),
            make_cell_at(2, 0.05, 0.0, []),
        ]
        count = check_site_separation(records, min_separation=0.5)
        self.assertEqual(count, 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_azgaar_to_cellgraph -v`
Expected: FAIL with `ImportError: cannot import name 'check_site_separation'`

- [ ] **Step 3: Write minimal implementation**

Add to `tools/azgaar_to_cellgraph.py`:

```python
import math


def check_site_separation(records: list[CellRecord], min_separation: float = 0.5) -> int:
    """Log a warning for every pair of adjacent cells whose centroids are
    closer than min_separation. Logging only — does not move any site."""
    by_id = {r.id: r for r in records}
    seen_pairs: set[tuple[int, int]] = set()
    violations = 0

    for r in records:
        for n in r.neighbors:
            pair = (min(r.id, n), max(r.id, n))
            if pair in seen_pairs:
                continue
            seen_pairs.add(pair)
            neighbor = by_id.get(n)
            if neighbor is None:
                continue
            dist = math.hypot(r.cx - neighbor.cx, r.cy - neighbor.cy)
            if dist < min_separation:
                logger.warning(
                    "near-duplicate sites: cells %d and %d are %.4f apart (min %.4f)",
                    r.id, n, dist, min_separation,
                )
                violations += 1

    return violations
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_azgaar_to_cellgraph -v`
Expected: PASS (14 tests)

- [ ] **Step 5: Commit**

```bash
cd ~/source/ibp-engine
git add tools/azgaar_to_cellgraph.py tools/test_azgaar_to_cellgraph.py
git commit -m "feat(cellgraph): log near-duplicate site-separation warnings"
```

---

### Task 5: Binary writer and reader

**Files:**
- Modify: `tools/azgaar_to_cellgraph.py`
- Test: `tools/test_azgaar_to_cellgraph.py`

**Interfaces:**
- Consumes: `CellRecord` (Task 1), `data: dict` (raw Azgaar JSON, for `pack.vertices`/`biomesData`/`states`/`provinces`/`burgs` needed at write time).
- Produces: `write_cellgraph_bin(records: list[CellRecord], data: dict, out_path: Path) -> None` and `read_cellgraph_bin(path: Path) -> dict` (returns `{"header": {...}, "cells": [{...}, ...]}` — enough structure for round-trip assertions; not a full production reader).

- [ ] **Step 1: Write the failing test**

Add to `tools/test_azgaar_to_cellgraph.py` (new imports at top of file):

```python
import tempfile
from pathlib import Path

from azgaar_to_cellgraph import (
    CellRecord, extract_cells, repair_degenerate_cells, repair_adjacency_symmetry,
    check_site_separation, write_cellgraph_bin, read_cellgraph_bin,
)


class WriteReadCellgraphBinTest(unittest.TestCase):
    def test_round_trip_header_counts(self) -> None:
        data = make_fixture()
        records = extract_cells(data)
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "cell_graph.bin"
            write_cellgraph_bin(records, data, out_path)
            result = read_cellgraph_bin(out_path)
        self.assertEqual(result["header"]["magic"], b"CGB1")
        self.assertEqual(result["header"]["cell_count"], 4)
        self.assertEqual(result["header"]["realm_count"], 1)
        self.assertEqual(result["header"]["province_count"], 1)
        self.assertEqual(result["header"]["burg_count"], 1)
        self.assertEqual(len(result["cells"]), 4)

    def test_round_trip_cell_fields(self) -> None:
        data = make_fixture()
        records = extract_cells(data)
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "cell_graph.bin"
            write_cellgraph_bin(records, data, out_path)
            result = read_cellgraph_bin(out_path)
        c0 = next(c for c in result["cells"] if c["id"] == 0)
        self.assertAlmostEqual(c0["cx"], 10.0, places=3)
        self.assertAlmostEqual(c0["cy"], 10.0, places=3)
        self.assertEqual(c0["biome_id"], 1)
        self.assertEqual(c0["is_water"], 0)
        self.assertEqual(sorted(c0["neighbors"]), [1, 2, 3])
        self.assertEqual(c0["border"], [0, 1, 2, 3])

    def test_round_trip_water_cell(self) -> None:
        data = make_fixture()
        records = extract_cells(data)
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "cell_graph.bin"
            write_cellgraph_bin(records, data, out_path)
            result = read_cellgraph_bin(out_path)
        c1 = next(c for c in result["cells"] if c["id"] == 1)
        self.assertEqual(c1["is_water"], 1)

    def test_round_trip_burg_id(self) -> None:
        # The fixture has exactly one burg (Azgaar id 1) on cell 0; the
        # binary format's burg_id is a 1-based index into the *output*
        # burgs table (matching hexbin's "burg_id=1 -> index 0" convention),
        # not Azgaar's own burg["i"] — with one burg, both happen to be 1.
        data = make_fixture()
        records = extract_cells(data)
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "cell_graph.bin"
            write_cellgraph_bin(records, data, out_path)
            result = read_cellgraph_bin(out_path)
        c0 = next(c for c in result["cells"] if c["id"] == 0)
        c1 = next(c for c in result["cells"] if c["id"] == 1)
        self.assertEqual(c0["burg_id"], 1)
        self.assertEqual(c1["burg_id"], 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_azgaar_to_cellgraph -v`
Expected: FAIL with `ImportError: cannot import name 'write_cellgraph_bin'`

- [ ] **Step 3: Write minimal implementation**

Add to `tools/azgaar_to_cellgraph.py` (near the top, after the existing imports):

```python
import struct
from pathlib import Path

HEADER_FMT = "<4sHHIIHHHIII"
REALM_FMT = "<HI"
PROVINCE_FMT = "<HII"
VERTEX_FMT = "<ff"
CELL_FMT = "<IffBHHHBBHIHIB"
MAGIC = b"CGB1"
VERSION = 1
```

Add the writer and reader at the end of `tools/azgaar_to_cellgraph.py`:

```python
def _build_strtab(strings: list[str]) -> tuple[bytes, list[int]]:
    """Pack strings into a null-terminated strtab; offset 0 = empty string.
    Returns (strtab_bytes, offset_per_input_string)."""
    strtab = bytearray(b"\x00")  # offset 0 is the empty string
    offsets: list[int] = []
    cache: dict[str, int] = {"": 0}
    for s in strings:
        if s in cache:
            offsets.append(cache[s])
            continue
        offset = len(strtab)
        strtab += s.encode("utf-8") + b"\x00"
        cache[s] = offset
        offsets.append(offset)
    return bytes(strtab), offsets


def write_cellgraph_bin(records: list[CellRecord], data: dict[str, Any], out_path: Path) -> None:
    pack = data["pack"]
    biome_names: list[str] = data["biomesData"]["name"]

    states = [s for s in pack.get("states", []) if isinstance(s, dict) and s.get("i")]
    provinces = [p for p in pack.get("provinces", []) if isinstance(p, dict) and p.get("i")]
    burgs = [b for b in pack.get("burgs", []) if isinstance(b, dict) and b.get("i")]

    burg_name_by_idx = {b["i"]: b.get("name", "") for b in burgs}
    province_capital = {
        p["i"]: burg_name_by_idx.get(p.get("burg", 0), "") for p in provinces
    }
    # burg_id in the binary format is a 1-based index into THIS output
    # table (matching hexbin's "burg_id=1 -> index 0" convention), not
    # Azgaar's own burg["i"] — those only coincide when burgs are dense
    # and start at 1, which is not guaranteed.
    burg_output_id_by_azgaar_id = {b["i"]: idx + 1 for idx, b in enumerate(burgs)}

    strings: list[str] = list(biome_names)
    realm_name_idx = {s["i"]: len(strings) + i for i, s in enumerate(states)}
    strings += [s.get("name", "") for s in states]
    province_name_idx = {p["i"]: len(strings) + 2 * i for i, p in enumerate(provinces)}
    for p in provinces:
        strings.append(p.get("fullName", p.get("name", "")))
        strings.append(province_capital.get(p["i"], ""))
    burg_name_idx = {b["i"]: len(strings) + i for i, b in enumerate(burgs)}
    strings += [b.get("name", "") for b in burgs]

    strtab, offsets = _build_strtab(strings)

    biome_offsets = offsets[: len(biome_names)]
    realm_rows = [
        struct.pack(REALM_FMT, s["i"], offsets[realm_name_idx[s["i"]]]) for s in states
    ]
    province_rows = [
        struct.pack(
            PROVINCE_FMT, p["i"],
            offsets[province_name_idx[p["i"]]],
            offsets[province_name_idx[p["i"]] + 1],
        )
        for p in provinces
    ]
    burg_rows = [struct.pack("<I", offsets[burg_name_idx[b["i"]]]) for b in burgs]

    vertices = pack["vertices"]
    vertex_bytes = b"".join(
        struct.pack(VERTEX_FMT, float(v["p"][0]), float(v["p"][1])) for v in vertices
    )

    border_flat: list[int] = []
    neighbor_flat: list[int] = []
    cell_rows = bytearray()
    for r in records:
        border_start = len(border_flat)
        border_flat.extend(r.border)
        neighbor_start = len(neighbor_flat)
        neighbor_flat.extend(r.neighbors)
        cell_rows += struct.pack(
            CELL_FMT, r.id, r.cx, r.cy, r.biome_id, r.realm_id, r.province_id,
            burg_output_id_by_azgaar_id.get(r.burg_azgaar_id, 0),
            1 if r.is_water else 0, r.harbor, r.river_id,
            border_start, len(r.border), neighbor_start, len(r.neighbors),
        )

    border_bytes = b"".join(struct.pack("<I", v) for v in border_flat)
    neighbor_bytes = b"".join(struct.pack("<I", n) for n in neighbor_flat)

    header = struct.pack(
        HEADER_FMT, MAGIC, VERSION, len(biome_names), len(records), len(strtab),
        len(states), len(provinces), len(burgs), len(vertices),
        len(neighbor_flat), len(border_flat),
    )

    with out_path.open("wb") as f:
        f.write(header)
        f.write(strtab)
        for off in biome_offsets:
            f.write(struct.pack("<I", off))
        for row in realm_rows:
            f.write(row)
        for row in province_rows:
            f.write(row)
        for row in burg_rows:
            f.write(row)
        f.write(vertex_bytes)
        f.write(cell_rows)
        f.write(border_bytes)
        f.write(neighbor_bytes)


def read_cellgraph_bin(path: Path) -> dict[str, Any]:
    """Round-trip reader for tests. Not a production consumer."""
    with path.open("rb") as f:
        raw = f.read()

    header_size = struct.calcsize(HEADER_FMT)
    (magic, version, biome_count, cell_count, strtab_size, realm_count,
     province_count, burg_count, vertex_count, neighbor_total,
     border_total) = struct.unpack_from(HEADER_FMT, raw, 0)

    offset = header_size
    strtab = raw[offset:offset + strtab_size]
    offset += strtab_size
    offset += 4 * biome_count  # skip biome offsets
    offset += struct.calcsize(REALM_FMT) * realm_count
    offset += struct.calcsize(PROVINCE_FMT) * province_count
    offset += 4 * burg_count
    offset += struct.calcsize(VERTEX_FMT) * vertex_count

    cell_fmt_size = struct.calcsize(CELL_FMT)
    cells_raw = []
    for i in range(cell_count):
        cells_raw.append(struct.unpack_from(CELL_FMT, raw, offset + i * cell_fmt_size))
    offset += cell_fmt_size * cell_count

    borders_raw = struct.unpack_from(f"<{border_total}I", raw, offset)
    offset += 4 * border_total
    neighbors_raw = struct.unpack_from(f"<{neighbor_total}I", raw, offset)

    cells = []
    for row in cells_raw:
        (cid, cx, cy, biome_id, realm_id, province_id, burg_id, is_water,
         harbor, river_id, border_start, border_count, neighbor_start,
         neighbor_count) = row
        cells.append({
            "id": cid, "cx": cx, "cy": cy, "biome_id": biome_id,
            "realm_id": realm_id, "province_id": province_id, "burg_id": burg_id,
            "is_water": is_water, "harbor": harbor, "river_id": river_id,
            "border": list(borders_raw[border_start:border_start + border_count]),
            "neighbors": list(neighbors_raw[neighbor_start:neighbor_start + neighbor_count]),
        })

    return {
        "header": {
            "magic": magic, "version": version, "biome_count": biome_count,
            "cell_count": cell_count, "realm_count": realm_count,
            "province_count": province_count, "burg_count": burg_count,
            "vertex_count": vertex_count,
        },
        "cells": cells,
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_azgaar_to_cellgraph -v`
Expected: PASS (18 tests)

- [ ] **Step 5: Commit**

```bash
cd ~/source/ibp-engine
git add tools/azgaar_to_cellgraph.py tools/test_azgaar_to_cellgraph.py
git commit -m "feat(cellgraph): binary writer + round-trip reader for cell_graph.bin"
```

---

### Task 6: CLI entry point and end-to-end summary logging

**Files:**
- Modify: `tools/azgaar_to_cellgraph.py`
- Test: `tools/test_azgaar_to_cellgraph.py`

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: `convert(input_path: Path, output_path: Path | None = None) -> Path` (the full pipeline: load JSON, extract, repair degenerate, repair symmetry, check site separation, write binary, log a per-run summary — cell count, merged/dropped count, adjacency violations fixed, site-separation violations, build time — returns the output path) and a `main()` CLI entry point using `argparse`, mirroring `azgaar_to_hex.py`'s CLI shape.

- [ ] **Step 1: Write the failing test**

Add to `tools/test_azgaar_to_cellgraph.py`:

```python
import json
import time

from azgaar_to_cellgraph import convert


class ConvertEndToEndTest(unittest.TestCase):
    def test_convert_writes_output_and_logs_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            in_path = Path(tmp) / "azgaar.json"
            in_path.write_text(json.dumps(make_fixture()))
            with self.assertLogs("azgaar_to_cellgraph", level="INFO") as log:
                out_path = convert(in_path)
            self.assertTrue(out_path.exists())
            self.assertEqual(out_path.name, "cell_graph.bin")
            self.assertTrue(any("cell_count=4" in msg for msg in log.output))

    def test_convert_custom_output_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            in_path = Path(tmp) / "azgaar.json"
            in_path.write_text(json.dumps(make_fixture()))
            out_path = Path(tmp) / "custom.bin"
            result = convert(in_path, out_path)
            self.assertEqual(result, out_path)
            self.assertTrue(out_path.exists())
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_azgaar_to_cellgraph -v`
Expected: FAIL with `ImportError: cannot import name 'convert'`

- [ ] **Step 3: Write minimal implementation**

Add to `tools/azgaar_to_cellgraph.py` (near the top, with other imports):

```python
import argparse
import json
import sys
import time
```

Add at the end of `tools/azgaar_to_cellgraph.py`:

```python
def convert(input_path: Path, output_path: Path | None = None) -> Path:
    start = time.monotonic()
    with input_path.open(encoding="utf-8") as f:
        data = json.load(f)

    records = extract_cells(data)
    original_count = len(records)
    records = repair_degenerate_cells(records)
    merged_or_dropped = original_count - len(records)
    records = repair_adjacency_symmetry(records)
    separation_violations = check_site_separation(records)

    out_path = output_path or (input_path.parent / "cell_graph.bin")
    write_cellgraph_bin(records, data, out_path)

    elapsed = time.monotonic() - start
    logger.info(
        "azgaar_to_cellgraph summary: cell_count=%d merged_or_dropped=%d "
        "site_separation_violations=%d build_time=%.2fs -> %s",
        len(records), merged_or_dropped, separation_violations, elapsed, out_path,
    )
    return out_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Path to Azgaar .json export")
    parser.add_argument("-o", "--output", type=Path, default=None,
                         help="Output path (default: cell_graph.bin next to input)")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
    )

    out_path = convert(args.input, args.output)
    print(f"Wrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/source/ibp-engine/tools && python3 -m unittest test_azgaar_to_cellgraph -v`
Expected: PASS (20 tests)

- [ ] **Step 5: Commit**

```bash
cd ~/source/ibp-engine
git add tools/azgaar_to_cellgraph.py tools/test_azgaar_to_cellgraph.py
git commit -m "feat(cellgraph): CLI entry point with per-run summary logging"
```

---

### Task 7: Smoke test against real world data

**Files:**
- None created — this is a manual verification task using the existing `worlds/cheia/azgaar.json`.

**Interfaces:**
- Consumes: `convert()` (Task 6).

- [ ] **Step 1: Run the converter against the real cheia world**

Run: `cd ~/source/ibp-engine && python3 tools/azgaar_to_cellgraph.py worlds/cheia/azgaar.json -o /tmp/cheia_cell_graph.bin -v`
Expected: exits 0, prints `Wrote /tmp/cheia_cell_graph.bin`, and the INFO summary log line shows `cell_count=` a number close to 26924 (the known cheia cell count — a large drop would indicate a repair-logic bug, not real degenerate data, since the earlier investigation confirmed 0 zero-neighbor cells and no border <3 vertices in this specific world).

- [ ] **Step 2: Verify the file is well-formed**

Run:
```bash
cd ~/source/ibp-engine && python3 -c "
from pathlib import Path
import sys
sys.path.insert(0, 'tools')
from azgaar_to_cellgraph import read_cellgraph_bin
result = read_cellgraph_bin(Path('/tmp/cheia_cell_graph.bin'))
print(result['header'])
print('first cell:', result['cells'][0])
print('last cell:', result['cells'][-1])
"
```
Expected: prints a header dict with `cell_count` close to 26924, `magic: b'CGB1'`, and two cell dicts with populated `border`/`neighbors` lists (not empty).

- [ ] **Step 3: Record actual counts in a follow-up note**

No code change. If `cell_count` in the header differs meaningfully from the raw `pack.cells` count in `worlds/cheia/azgaar.json` (i.e. more than a handful of cells were merged/dropped), note the exact numbers from the log output — this is real signal for whether Task 2's degenerate-cell thresholds need tuning on production data, to be handled in a follow-up plan rather than blocking this one.

- [ ] **Step 4: Clean up the smoke-test output**

Run: `rm /tmp/cheia_cell_graph.bin`

(No commit for this task — it's manual verification only, produces no repo changes.)

---

## Self-Review Notes

- **Spec coverage:** Task 1 covers extraction (spec's Architecture: world-gen tooling). Tasks 2-4 cover the spec's Error Handling and Logging section (degenerate cells, adjacency symmetry, near-duplicate sites) — nudging sites is explicitly deferred per the spec's revised text, matching Task 4's logging-only scope. Task 5 covers the binary format defined in Global Constraints. Task 6 covers the CLI + "per-run summary" logging requirement. Task 7 is the spec's "manual/visual" smoke-test category, scoped to what's checkable without a renderer (no engine/frontend exists yet to do the side-by-side visual comparison the spec's Testing Strategy also calls for — that requires Tasks from the follow-up WorldMap/frontend plans and is explicitly out of scope here).
- **Not covered by this plan (belongs to subsystems 2/3, per the scope split agreed before writing this plan):** the adjacency interface inside `WorldMap`, `move_cost` implementation, `location_entered` signal, spatial-hash hover/click, texture-atlas rendering at global zoom, province/realm hierarchy grouping (still an open question in the spec itself), and golden-file fixture-based contract tests shared between the hex and cell-graph backings.
- **Placeholder scan:** no TODOs. Task 5's `burg_id` is fully resolved (Azgaar burg id → 1-based output-table index, `0` for no burg) rather than left as a placeholder — an earlier draft of this plan left it as a stub; that gap was caught during pre-flight review and fixed before Task 1 was dispatched (see `test_round_trip_burg_id`).
- **Type consistency:** `CellRecord` fields are used identically across all six tasks (`border: list[int]`, `neighbors: list[int]`, etc.); `convert()`'s return type (`Path`) matches what Task 7's manual verification expects.
