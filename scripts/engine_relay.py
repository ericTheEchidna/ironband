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
"""

from __future__ import annotations

import argparse
import select
import socket
import subprocess
import sys
import threading


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

    stop = threading.Event()

    # ── engine stdout → TCP ────────────────────────────────────────────────
    def engine_to_tcp():
        try:
            for line in proc.stdout:
                if stop.is_set():
                    break
                try:
                    conn.sendall(line)
                except (BrokenPipeError, OSError):
                    break
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
    parser.add_argument("--world",  default=None, help="Path to hex_grid.json (passed to engine)")
    args = parser.parse_args()
    sys.exit(relay(args.engine, args.world, args.port))


if __name__ == "__main__":
    main()
