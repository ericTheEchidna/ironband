#!/usr/bin/env python3
"""
engine_relay.py — Bridge between the ibp-engine C++ engine (stdin/stdout) and a
TCP client (Godot). Spawns the engine as a subprocess, accepts one TCP
connection, then relays bidirectionally until either side closes.

Usage:
    python3 engine_relay.py --engine /path/to/app --port 7373
    python3 engine_relay.py --engine /path/to/app --port 7373 --world /path/to/hex_grid.json

# TEMPORARY: fold into engine TCP (--tcp-port flag) in IRONBAND-010 to remove
# this shim entirely. The engine's stdin/stdout protocol is already correct;
# this file exists only because Godot 4 has no subprocess pipe API.

## State persistence (IRONBAND-025)
#
# The relay intercepts two extra Protohack messages without forwarding them:
#   > player.state_sync data=<url-encoded-json>   (Godot → relay)
#       Decode JSON, write atomically to <world_dir>/player_state.json,
#       then reply  < world.state_ack
#   < world.player_state data=<url-encoded-json>  (relay → Godot)
#       Injected once per session, immediately after the engine emits
#       < world.party_position (so Godot can restore state after placement).
#
# URL-encoding keeps JSON blobs single-token on the wire (no spaces).
# Python encodes with urllib.parse.quote(); GDScript with String.uri_encode().
"""

from __future__ import annotations

import argparse
import json
import os
import select
import socket
import subprocess
import sys
import threading
import urllib.parse


# ── State helpers ──────────────────────────────────────────────────────────────

_EMPTY_STATE: dict = {
    "schema_version": 1,
    "inventory":      {},
    "ground_items":   {},
    "visited_hexes":  [],
    "npcs":           {},
    "quests":         [],
    "journal":        [],
    "journal_summary": "",
    "chat_summary":   "",
}


def _state_path(world_path: str | None) -> str | None:
    if world_path is None:
        return None
    return os.path.join(os.path.dirname(world_path), "player_state.json")


def _load_state_line(path: str | None) -> bytes:
    """Return b'< world.player_state data=...\\n' from disk, or an empty-state line."""
    state = _EMPTY_STATE
    if path is not None and os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                state = json.loads(f.read())
        except Exception as exc:
            print(f"[relay] Warning: could not load player state: {exc}", file=sys.stderr)
    encoded = urllib.parse.quote(json.dumps(state, separators=(",", ":")))
    return f"< world.player_state data={encoded}\n".encode()


def _save_state(path: str, state: dict) -> None:
    """Atomic write: temp file + rename."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, path)
    print(f"[relay] Player state saved → {path}", file=sys.stderr)


def _handle_state_sync(line_str: str, path: str | None, send_fn) -> None:
    """Parse player.state_sync, persist to disk, reply with state_ack."""
    try:
        data_token = next(
            (t for t in line_str.split() if t.startswith("data=")), None
        )
        if data_token is None:
            print("[relay] Warning: player.state_sync missing data= token", file=sys.stderr)
        else:
            state = json.loads(urllib.parse.unquote(data_token[5:]))
            if path is not None:
                _save_state(path, state)
    except Exception as exc:
        print(f"[relay] Warning: failed to handle player.state_sync: {exc}", file=sys.stderr)
    send_fn(b"< world.state_ack\n")


# ── Main relay ─────────────────────────────────────────────────────────────────

def relay(engine_path: str, world_path: str | None, port: int) -> int:
    # ── Launch engine ──────────────────────────────────────────────────────
    cmd = [engine_path]
    if world_path:
        cmd += ["--world", world_path]

    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,   # engine diagnostics pass through to terminal
        )
    except FileNotFoundError:
        print(f"[relay] ERROR: engine not found: {engine_path}", file=sys.stderr)
        return 1

    print(f"[relay] Engine PID {proc.pid} started", file=sys.stderr)

    # ── TCP server — accept exactly one client ─────────────────────────────
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    print(f"[relay] Listening on 127.0.0.1:{port}", file=sys.stderr)

    srv.settimeout(30.0)
    try:
        conn, addr = srv.accept()
    except socket.timeout:
        print("[relay] Timeout waiting for client — shutting down", file=sys.stderr)
        proc.terminate()
        srv.close()
        return 1
    finally:
        srv.close()   # stop accepting new connections

    print(f"[relay] Client connected from {addr}", file=sys.stderr)
    conn.setblocking(False)

    stop      = threading.Event()
    send_lock = threading.Lock()
    s_path    = _state_path(world_path)

    def _send(data: bytes) -> None:
        with send_lock:
            try:
                conn.sendall(data)
            except (BrokenPipeError, OSError):
                stop.set()

    # ── engine stdout → TCP ────────────────────────────────────────────────
    state_injected = [False]

    def engine_to_tcp():
        try:
            for line in proc.stdout:
                if stop.is_set():
                    break
                _send(line)
                # Inject saved player state once, right after party placement.
                if not state_injected[0] and b"world.party_position" in line:
                    state_injected[0] = True
                    _send(_load_state_line(s_path))
        finally:
            stop.set()

    # ── TCP → engine stdin ─────────────────────────────────────────────────
    def tcp_to_engine():
        buf = b""
        try:
            while not stop.is_set():
                ready, _, _ = select.select([conn], [], [], 0.1)
                if not ready:
                    continue
                data = conn.recv(4096)
                if not data:
                    break
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line_str = line.decode("utf-8", errors="replace")
                    if line_str.startswith("> player.state_sync"):
                        # Handled locally — do not forward to engine.
                        _handle_state_sync(line_str, s_path, _send)
                    else:
                        try:
                            proc.stdin.write(line + b"\n")
                            proc.stdin.flush()
                        except (BrokenPipeError, OSError):
                            stop.set()
                            return
        finally:
            stop.set()

    t1 = threading.Thread(target=engine_to_tcp, daemon=True)
    t2 = threading.Thread(target=tcp_to_engine, daemon=True)
    t1.start()
    t2.start()

    stop.wait()

    # ── Teardown ───────────────────────────────────────────────────────────
    print("[relay] Connection closed — shutting down", file=sys.stderr)
    try:
        conn.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    conn.close()

    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()

    print(f"[relay] Engine exited with code {proc.returncode}", file=sys.stderr)
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Protohack TCP relay for ibp-engine")
    parser.add_argument("--engine", required=True, help="Path to ibp-engine app binary")
    parser.add_argument("--port",   type=int, default=7373, help="TCP port (default 7373)")
    parser.add_argument("--world",  default=None, help="Path to hex_grid.hexbin (passed to engine)")
    args = parser.parse_args()
    sys.exit(relay(args.engine, args.world, args.port))


if __name__ == "__main__":
    main()
