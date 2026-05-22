#!/usr/bin/env bash
# Launch Ironband in the Godot editor (or just run it headless with --headless)
# Usage:
#   ./play.sh          — open in Godot editor
#   ./play.sh --run    — run the project (no editor UI)
GODOT="/home/eric/bin/Godot_v4.6.2-stable_linux.x86_64"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "$1" == "--run" ]]; then
  exec "$GODOT" --path "$PROJECT_DIR" --quit-after 0
else
  exec "$GODOT" --path "$PROJECT_DIR" --editor
fi
