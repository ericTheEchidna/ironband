# SDD Progress Ledger
# Plan: docs/superpowers/plans/2026-06-24-world-map-engine.md
# Branch started from: 2c6c73c42b4a7f532341ff4076e13096d62169e2
# Started: 2026-06-24

## Tasks
- [x] Task 1: GDExtension build scaffold + load smoke test (commit ddde70d, review clean; godot-cpp 4.5 branch accepted by user — 4.6 doesn't exist upstream; minor: EngineSmoke.tscn not created but not functionally needed)
- [x] Task 2: Core hex math + doctest harness (commit 93f1e22, 3/3 tests 248 assertions, review clean)
- [x] Task 3: Core BB trade formula port (commit 84427c6, 4/4 tests, review clean; note: stub clobbered by parallel Task5 agent, restored in d7f1128)
- [x] Task 4: Core hexbin loader + WorldMap (commit b5e6457, 2/2 tests, real cheia loaded=1 hex_count=128137, review clean)
- [x] Task 5: Core WorldClock (commit 013aa2c, 4/4 tests, review clean)
- [x] Task 6: Core PartyController (commit 109c04c, 3/3 tests, review clean)
- [x] Task 7: Core TriggerSystem (commit ee67496, 3/3 tests, review clean; minor: test name misleads — "fires Location" tests no-fire baseline)
- [x] Task 8: Core WorldSim daily tick (commit 66a96c6, 3/3 tests, review clean)
- [x] Task 9: Binding layer — IronbandEngine (commit 9806f9c, INTEG PASS hexes=3 ticks=20, review clean; deviations: tick() alias for _process, SConstruct core glob — both accepted as necessary)
- [x] Task 10: Godot integration (commit 9d3887a, WIRING PASS, 22/22 core tests, review clean; minor: @onready var placement mid-file)

## Final Review + Fixes
- Final review: Ready to merge with 4 Important fixes
- Fixes commit 881a512: dead `prev` var, day-emit correctness, @onready placement, test name rename, dead RegionMap callbacks removed
- Post-fix: 22/22 core tests, SMOKE PASS, WIRING PASS

## Post-Merge Launch Fixes
- Merge 329cc23 brought in remote changes; resolved conflicts in project.godot, RegionMap.gd, engine relay files
- Fix 264f0c4: GlobalMap.gd:209 — `var p: Vector2i` (GDExtension return type not inferrable by `:=`, causes parse error)
- Fix 7685c16: RegionMap.gd — 3 stale `_client` call-sites survived merge: deferred `_start_engine_client` call, `_explore_move` null guard, `_push_state_sync` body; all cleaned up
- Launch verified 2026-06-24: world map renders, 128137 hexes, zoom/pan HUD working, no errors

---

# SDD Progress Ledger — Burg Markers
# Plan: docs/superpowers/plans/2026-07-03-burg-markers-plan.md
# Branch: feature/burg-markers
# Branch started from: be7c05b (origin/main, merge base)
# Started: 2026-07-03

## Tasks
- [x] Task 1: BurgMarkerLayer.gd — icon selection logic + rendering component (commit 1bd9ea8, review approved; Important/plan-mandated: smoke test never exercises build()/set_camera(), only marker_spec_for() + burg count — flagged for final review, covered indirectly by Tasks 2-4)
- [x] Task 2: GlobalMap.gd — load burgs, render filtered markers, click-to-inspect (commit 257c736, review clean, approved)
- [x] Task 3: RegionMap.gd — render all-type markers filtered to locale, extend info text (commit cb4212c, review clean, approved)
- [x] Task 4: Verification notes (commit 51cabde; partial — global-zoom icon transparency confirmed working after user fixed 3/4 source PNGs, harbor.png still needs re-export; regional-zoom/badge/star/click-info not independently user-confirmed yet, code-level review already verified correctness; user flagged art quality, tracked as follow-up IRONBAND-053)

## Final Review + Fixes
- Final review: With fixes — Important finding: burg click-to-inspect unreachable at province/realm zoom tiers
  (markers render there, but clicks routed to _select_province/_select_realm, never _select_hex where the burg
  lookup lived) and non-persistent even when reachable (_info_locked never set, hover overwrote it). Root cause:
  plan's Task 2 Step 4 under-specified relative to spec's explicit "priority over province/realm" requirement.
- Fix commit 353980f: moved burg-hex lookup to the top of _select_by_zoom (before zoom-tier branching), locks
  info panel; removed now-redundant call from _select_hex. Also fixed BurgMarkerLayer.gd param-shadowing warnings
  (name->icon_name, sign->corner_sign) and added build()/set_camera() smoke coverage (3 fixtures, child-count
  assertions).
- Re-review: all 3 findings independently verified resolved by tracing actual control flow (not just trusting
  the fix report). No regressions. One new Minor observation (clicking a village/town hex at global zoom now
  shows settlement info despite no visible marker there — debatable-by-design, not a bug). Ready to merge: Yes.

## Known follow-ups (not blocking)
- harbor.png still has baked-in opaque checkerboard (not real alpha) — needs re-export by user. Affects naval
  base icon + port badge visuals. Not a code issue.
- Regional-zoom rendering, badge/star visual placement, and click-info text on RegionMap were not independently
  human-confirmed in the editor (code-level review verified correctness, no visual check yet).
- IRONBAND-053 (separate memex task): user feedback that sprite art quality is subpar, suggested emoji glyphs as
  an alternative — tracked as a follow-up, confirmed low-risk since BurgMarkerLayer.gd isolates icon rendering.

---

# SDD Progress Ledger — Hex-Terrain Move Cost
# Plan: docs/superpowers/plans/2026-07-10-hex-terrain-move-cost-plan.md
# Branch: hex-terrain-move-cost (worktree .worktrees/hex-terrain-move-cost)
# Branch started from: cb78025 (origin/main, merge base)
# Started: 2026-07-10

## Tasks
- [x] Task 1: Load hex_terrain.bin and apply road/river cost in move_cost() (commits cb78025..43d5ef0, review clean — Approved. Minor findings deferred to final review: world_map.cpp:135 load_hex_terrain_ untested for corrupt/truncated hex_terrain.bin (only missing-file tested); world_map.cpp:65 discards load_hex_terrain_'s return value without explicit (void) cast. Note: implementer's original self-report falsely claimed 36/36 passing — independent rerun found 35/36 due to a test-isolation bug (baseline test shared a mutable fixture path with new tests); fixed via per-test isolated subdirectories, commit 43d5ef0, independently re-verified 36/36 on two consecutive runs before proceeding to review)
- [x] Task 2: Share ROAD_COST_MULTIPLIER constant, fix stale route_flags doc comment (commit 43d5ef0..f2615fd, review clean — Approved, no findings)

## Final Review + Fixes
- Final review (opus): Ready to merge = Yes. No Critical/Important findings.
- Deferred Minor findings from Task 1 (untested corrupt-file path, no (void) cast) explicitly triaged as
  non-blocking by final reviewer — left as-is per reviewer's own recommendation (no (void)-cast convention
  exists in this codebase; existing comment already documents intent).
- Fixed the one real Minor finding from final review (stale contradictory inline comment surviving in
  HexTerrainLoader.gd:42 after Task 2's docblock fix) directly, commit 5da59c8.
- Merged to main via fast-forward (cb78025..5da59c8), 36/36 tests passing.
