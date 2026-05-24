extends Node
class_name ProtohackClient

## Protohack TCP client for the Ironband engine.
##
## Architecture:
##   Godot (StreamPeerTCP) ──TCP:127.0.0.1:port── engine_relay.py ──pipe── ibp-engine
##
## Usage:
##   var client := ProtohackClient.new()
##   add_child(client)
##   client.start(relay_script, engine_path, world_path, port)
##   client.worldmap_end.connect(func(): print("map loaded"))
##
## Call poll() every frame to read bytes and dispatch signals.
## All TCP I/O happens on the main thread — StreamPeerTCP is not thread-safe.

# ── Signals ────────────────────────────────────────────────────────────────

signal handshake_done()
signal worldmap_begin(hex_count: int, hex_size: float, origin_x: float, origin_y: float)
signal worldmap_hex(data: Dictionary)
signal worldmap_end()
signal prompt_received(type: String)
signal engine_error(code: String, message: String)

signal party_position_received(q: int, r: int, mp: int, mp_max: int)
signal party_moved(q: int, r: int, mp: int)
signal movement_stopped(reason: String)

# ── State ──────────────────────────────────────────────────────────────────

const PROTOCOL_VERSION := 1
const CONNECT_TIMEOUT_SEC := 10.0

var _tcp:       StreamPeerTCP
var _buf:       PackedByteArray = PackedByteArray()
var _running:   bool = false
var _relay_pid: int  = -1


# ── Public API ─────────────────────────────────────────────────────────────

func start(relay_script: String, engine_path: String,
           world_path: String, port: int = 7373) -> bool:
	_tcp = StreamPeerTCP.new()

	var args := PackedStringArray([
		relay_script,
		"--engine", engine_path,
		"--port",   str(port),
	])
	if world_path != "":
		args.append("--world")
		args.append(world_path)

	_relay_pid = OS.create_process("python3", args)
	if _relay_pid < 0:
		push_error("ProtohackClient: failed to launch relay: " + relay_script)
		return false

	print("[client] Relay PID %d started" % _relay_pid)

	# Give relay a moment to bind before we connect.
	OS.delay_msec(500)

	var err := _tcp.connect_to_host("127.0.0.1", port)
	if err != OK:
		push_error("ProtohackClient: TCP connect failed: %d" % err)
		return false

	var deadline := Time.get_ticks_msec() + int(CONNECT_TIMEOUT_SEC * 1000)
	while _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		_tcp.poll()
		if Time.get_ticks_msec() > deadline:
			push_error("ProtohackClient: TCP connect timed out")
			return false
		OS.delay_msec(10)

	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("ProtohackClient: TCP not connected (status %d)" % _tcp.get_status())
		return false

	print("[client] TCP connected to 127.0.0.1:%d" % port)
	_running = true
	return true


func send_command(line: String) -> void:
	if _tcp == null or _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("ProtohackClient: not connected")
		return
	_tcp.put_data((line + "\n").to_utf8_buffer())


## Read available bytes from TCP and dispatch any complete lines.
## Must be called every frame from the main thread.
func poll() -> void:
	if not _running or _tcp == null:
		return
	_tcp.poll()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("[client] TCP disconnected")
		_running = false
		return

	var available := _tcp.get_available_bytes()
	if available <= 0:
		return

	var result := _tcp.get_partial_data(available)
	if result[0] != OK:
		return
	_buf.append_array(result[1])

	while true:
		var nl := _buf.find(0x0A)  # '\n'
		if nl < 0:
			break
		var line := _buf.slice(0, nl).get_string_from_utf8()
		_buf = _buf.slice(nl + 1)
		var evt := parse_line(line)
		var ns: String = evt.get("ns", "")
		if ns == "":
			continue
		# worldmap.hex events flood the wire — skip without queuing
		if ns == "worldmap" and evt.get("event", "") == "hex":
			continue
		_dispatch(evt)


func stop() -> void:
	_running = false
	if _tcp:
		_tcp.disconnect_from_host()
	if _relay_pid > 0:
		OS.kill(_relay_pid)
		_relay_pid = -1


# ── Dispatcher ─────────────────────────────────────────────────────────────

func _dispatch(evt: Dictionary) -> void:
	var ns:    String     = evt.get("ns", "")
	var event: String     = evt.get("event", "")
	var f:     Dictionary = evt.get("fields", {})
	print("[client] dispatch: %s.%s" % [ns, event])

	match ns + "." + event:
		"engine.hello":
			send_command("> client.hello version=%d name=\"Ironband\"" % PROTOCOL_VERSION)
			emit_signal("handshake_done")

		"worldmap.map_begin":
			emit_signal("worldmap_begin",
				int(f.get("hex_count", "0")),
				float(f.get("hex_size", "1.0")),
				float(f.get("origin_x", "0.0")),
				float(f.get("origin_y", "0.0")))

		"worldmap.hex":
			emit_signal("worldmap_hex", f)

		"worldmap.map_end":
			emit_signal("worldmap_end")

		"world.prompt":
			emit_signal("prompt_received", f.get("type", ""))

		"world.party_position":
			emit_signal("party_position_received",
				int(f.get("q", "0")), int(f.get("r", "0")),
				int(f.get("mp", "0")), int(f.get("mp_max", "0")))

		"world.party_moved":
			emit_signal("party_moved",
				int(f.get("q", "0")), int(f.get("r", "0")),
				int(f.get("mp", "0")))

		"world.movement_stopped":
			emit_signal("movement_stopped", f.get("reason", ""))

		"engine.error":
			emit_signal("engine_error",
				f.get("code", "unknown"), f.get("message", ""))


# ── Parser ─────────────────────────────────────────────────────────────────

## Parse one protohack line: "< ns.event key=value key=\"string\" ..."
static func parse_line(line: String) -> Dictionary:
	line = line.strip_edges()
	if not line.begins_with("< "):
		return {}
	var parts := line.substr(2).split(" ", false)
	if parts.is_empty():
		return {}
	var ns_event := parts[0].split(".", false, 1)
	if ns_event.size() < 2:
		return {}

	var fields: Dictionary = {}
	var i := 1
	while i < parts.size():
		var kv := parts[i]
		var eq := kv.find("=")
		if eq < 0:
			i += 1
			continue
		var key := kv.substr(0, eq)
		var val := kv.substr(eq + 1)
		if val.begins_with('"') and not (val.length() > 1 and val.ends_with('"')):
			val = val.substr(1)
			i += 1
			while i < parts.size():
				if parts[i].ends_with('"'):
					val += " " + parts[i].substr(0, parts[i].length() - 1)
					i += 1
					break
				val += " " + parts[i]
				i += 1
		elif val.begins_with('"') and val.ends_with('"'):
			val = val.substr(1, val.length() - 2)
			i += 1
		else:
			i += 1
		fields[key] = val

	return {"ns": ns_event[0], "event": ns_event[1], "fields": fields}
