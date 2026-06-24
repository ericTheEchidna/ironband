# Ironband World-Map Engine — Design Spec

**Date:** 2026-06-24
**Status:** Approved for planning

## Summary

Bootstrap Ironband's game-play engine by porting reverse-engineered Battle
Brothers (BB) mechanics into a native C++ GDExtension, with Godot 4.6 as a
pure rendering/UI front end. This first milestone builds **world-map
traversal** with a cleanly separated three-scale model (global / regional /
combat) and a pausable real-time simulation clock.

This spec replaces the current multi-protocol stack (Godot ↔ Protohack ↔
standalone C++ `ibp-engine` subprocess) with a single in-process engine.
`ibp-engine` is retained only as a reference archive and as the **source of
world data assets** (hex grid, provinces, realms generated from Azgaar).

## Goals

1. **Collapse the technology stack.** Remove the Protohack protocol, the
   engine subprocess, and the Python relay. The game engine is a C++
   GDExtension that Godot loads in-process.
2. **Minimise GDScript.** GDScript is used only for scene wiring (connect a
   signal to an animation, connect a button to an engine method call). No
   game logic in `.gd` files.
3. **Establish clean scale boundaries.** World-map travel, regional/settlement
   interaction, and combat are separate concerns with explicit handoffs. The
   world map never inspects combat internals; it issues a request and receives
   a result.
4. **Pausable real-time traversal.** Game-time flows continuously at a
   configurable scale, auto-pauses on events, and the player resumes.
5. **Living world.** Hexes the party is *not* in still progress via a coarser
   daily world-simulation tick.

## Non-Goals (this milestone)

- Combat resolution internals (separate future milestone; this milestone only
  defines the handoff boundary).
- Character generation, perks, inventory (future milestones).
- Settlement UI and trade screens (future; the economic data model is laid
  down here but no trade UI is built).
- Save/load (the architecture must not preclude it, but it is not implemented).
- Multiplayer / networking.

## Architecture

### Top-level shape

A single C++ GDExtension class, `IronbandEngine`, extends Godot's `Node` and
is registered as an **autoload**. It owns all simulation state and is the only
component that mutates it. Godot scenes are read-only consumers: they render
state and forward player input.

```
Godot scenes  ──commands (method calls)──▶  IronbandEngine  (C++ GDExtension autoload)
Godot scenes  ◀──signals──────────────────  IronbandEngine
```

Communication is **signal-driven** (Option B from brainstorming). The engine
runs the simulation and emits Godot signals describing what changed. Godot
connects to those signals and reacts. New UI reactions can be added without
touching engine code.

### Subsystem breakdown

All subsystems are plain C++ classes owned by `IronbandEngine`. None inherit
from Godot base classes below the top-level node, so they are unit-testable
without a running Godot instance.

```
IronbandEngine (Node, autoload)
├── WorldMap         — hex grid, terrain, fog, province/realm/religion/culture data
├── PartyController  — position, path queue, fatigue, per-hex time cost
├── WorldClock       — game-time, time scale, drives party tick + world tick
├── TriggerSystem    — per-hex checks: encounters, locations, events, borders
├── WorldSim         — daily world tick: patrols, factions, prices, off-screen events
└── SignalBus        — single point that emits all outbound Godot signals
```

### Engine ⇄ Godot interface

**Signals emitted by the engine:**

| Signal | Payload | Purpose |
| --- | --- | --- |
| `hex_entered` | `q:int, r:int, terrain_id:int, province_id:int, realm_id:int` | Party crossed into a new hex |
| `encounter_triggered` | `type:String, payload:Dictionary` | An event needs player resolution; clock has auto-paused |
| `clock_ticked` | `game_day:int, game_hour:float` | Time advanced; HUD updates |
| `fog_updated` | `revealed:PackedVector2Array` | Newly revealed hexes |
| `time_scale_changed` | `scale:float` | Travel speed / pause-state changed |
| `world_tick_completed` | `game_day:int` | A daily world simulation step finished |

**Commands accepted by the engine (callable methods):**

| Method | Args | Purpose |
| --- | --- | --- |
| `load_world` | `hex_grid_path:String` | Load world data assets |
| `move_party` | `path:PackedVector2Array` | Queue a movement path |
| `set_time_scale` | `scale:float` | `0`=pause, `1`=normal, `4`=fast march |
| `resume` | — | Resume after an auto-pause |
| `get_hex_info` | `q:int, r:int` → `Dictionary` | Read-only hex query for UI |

Read-only accessors (e.g. `get_party_position`, `get_game_time`) supplement
signals for UI that polls rather than reacts.

## Simulation Model

### Clock

`WorldClock` tracks game-time in fractional **game-hours**. Each Godot
`_process(delta)` advances game-time by `delta * time_scale * HOURS_PER_SECOND`
(target ≈ 4 game-hours per real second at scale 1). The clock drives two
cadences:

- **Party tick** — continuous; spends accumulated time on the active movement
  path.
- **World tick** — fires once per game-day boundary crossed; invokes
  `WorldSim`.

Both run on the *same* game-time. They differ only in granularity.

### Time scale

| Scale | Meaning |
| --- | --- |
| `0` | Paused |
| `1` | Normal travel |
| `4` | Fast march (incurs extra fatigue — BB march mechanic) |

Auto-pause from a trigger overrides any scale by setting scale to `0` and
emitting `time_scale_changed`.

### Movement

`PartyController` holds a queued path (list of hex coords). Each hex has a
**movement cost** in game-hours derived from terrain, ported from BB's
`world_assets`:

| Terrain | Cost multiplier |
| --- | ---: |
| Road | 0.5 |
| Plains | 1.0 |
| Forest | 1.5 |
| Swamp | 2.0 |
| Mountains | 2.5 |

(Exact base hour value per unit cost is a tuning constant established during
implementation; the multipliers above are the BB-derived ratios.)

The party advances along the path by spending accumulated game-time. When a
hex boundary is crossed, `hex_entered` fires and `TriggerSystem` runs **before**
movement into the next hex begins.

### Trigger check (per hex entry)

Run in priority order. The first firing trigger auto-pauses the clock, emits
`encounter_triggered(type, payload)`, and halts movement. Godot resolves it and
calls `resume()`.

1. **Encounter roll** — enemy patrol present? (faction territory + random)
2. **Location check** — settlement / dungeon / camp in this hex?
3. **Event roll** — random event (weather, ambush, disease — BB-style table)
4. **Border crossing** — province or realm boundary crossed (informational;
   may not pause)

### World simulation tick

`WorldSim` runs once per game-day, advancing everything the party is **not**
directly interacting with. The world does not wait for the player.

- Enemy patrols spawn, move within territory, and despawn.
- Faction armies reposition between provinces.
- Settlement prices drift (BB trade model applied world-wide).
- Political events fire (war declarations, succession, faction expansion).
- Off-screen random events resolve (plague spread, failed harvest).

A consequence: the party can leave a peaceful province and return to find it at
war, or avoid a patrol that has since moved on.

## Scale Boundaries

The three Godot scenes map to three simulation contexts with explicit handoffs:

- **GlobalMap** — owns the clock and party movement. Reads boundary data
  (province / realm / religion / culture) to drive triggers and rendering, but
  owns no boundary *logic* — those are hex attributes.
- **RegionMap / settlements** — a modal layer entered from the world map.
- **CombatMap** — a fully separate scene. The world map issues a combat request
  and awaits a result; it never inspects combat internals. (Combat resolution
  itself is a later milestone — this milestone defines only the request/result
  boundary.)

Political, economic, and religious boundaries are **data painted on the hex
grid** (`province_id`, `realm_id`, `religion_id`, `culture_id`), loaded from
world assets. They carry no logic of their own; higher systems (trade pricing,
faction hostility, event tables) query them.

## BB Mechanical Ports

The reverse-engineered BB knowledge (currently in Python/Squirrel under
`mod_ai_advisor`) is transliterated once into C++ and lives in the engine:

- `WorldSim` — trade price formula (already exactly reverse-engineered:
  `BASE_BUY=1.0`, `NOT_HERE_BUY=1.5`, `BASE_SELL=0.15`, `NOT_HERE_SELL=1.01`,
  `CULT_BUY_PEN=1.5`, `CULT_SELL_BONUS=1.1`) and terrain movement costs.
- `TriggerSystem` — encounter probability tables.
- `PartyController` — fatigue-per-hex math from BB march mechanics.

## Testing Strategy

Because all subsystems are plain C++ classes free of Godot base types, each is
unit-tested headless:

- `WorldClock` — time accumulation, scale changes, day-boundary detection.
- `PartyController` — path traversal, time-cost spending, fatigue accrual.
- `TriggerSystem` — deterministic trigger ordering with seeded RNG.
- `WorldSim` — price drift and patrol movement over N simulated days with
  seeded RNG.
- Trade formula — port verified against the existing `mod_ai_advisor`
  `test_trade_prices.py` expected values (cross-culture sell bonus = 511, etc.).

Integration smoke test: load `cheia` world data, queue a path across a
province boundary, run the clock, assert `hex_entered` and a border event fire.

## Open Questions (resolve during planning)

- Exact base game-hours per unit movement cost (tuning constant).
- GDExtension build toolchain choice: `godot-cpp` + SCons (canonical) vs CMake.
- Hex coordinate convention carried from `ibp-engine` (`hex_grid.hexbin`
  format) — confirm axial vs offset and reuse the existing loader logic in C++.
