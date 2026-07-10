# Ironband

Godot 4.6 frontend for Ironband — a hex-map overworld with global, regional,
and local (dungeon) scales. Pure display layer: world/party/trigger simulation
runs in native C++ via an in-process GDExtension, not in GDScript.

For architecture, ownership map, and conventions, see **[CLAUDE.md](CLAUDE.md)**
(also readable as `AGENTS.md`, symlinked to the same file) — that's the
canonical entry point for working in this repo, human or agent.

## Documentation map

- **[CLAUDE.md](CLAUDE.md)** — architecture, where-to-edit-what, task tracking conventions
- **`docs/superpowers/specs/`** — design specs (dated, one per feature)
- **`docs/superpowers/plans/`** — implementation plans (dated, one per feature)
- **[docs/player_state_schema.md](docs/player_state_schema.md)** — player state schema shared with `ibp-engine`
- **[docs/azgaar-import-coverage.md](docs/azgaar-import-coverage.md)** — Azgaar world-export import coverage

There is no Ironband-level `CHANGELOG.md` yet — use `git log` for change history.

`addons/gdt_terrain/` is a vendored third-party Godot addon (procedural terrain
generator) with its own `README.md`/`CHANGELOG.md`/`THIRD_PARTY_NOTICES.md` —
those describe the addon, not Ironband.

## Quick start

```sh
./play.sh
```

Builds/runs the GDExtension-backed Godot project. See `CLAUDE.md` for the
extension build command and test suite.
