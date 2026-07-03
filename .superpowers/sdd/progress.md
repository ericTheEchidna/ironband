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
- [ ] Task 3: RegionMap.gd — render all-type markers filtered to locale, extend info text
- [ ] Task 4: Verification notes
