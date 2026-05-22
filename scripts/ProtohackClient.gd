extends Node
class_name ProtohackClient

## Protohack client — launches the Hack2 engine as a subprocess and reads
## events line-by-line. Emits parsed events as signals.

signal handshake_done()
signal worldmap_begin(hex_count: int, hex_size: float, origin_x: float, origin_y: float)
signal worldmap_hex(data: Dictionary)
signal worldmap_end()
signal prompt_received(type: String)
signal engine_error(code: String, message: String)

var _process: int = -1
var _thread: Thread
var _running: bool = false
var _pending: Array[Dictionary] = []
var _mutex: Mutex

const PROTOCOL_VERSION := 1


func start(engine_path: String, args: Array[String] = []) -> bool:
	_mutex = Mutex.new()
	var full_args := args.duplicate()

	_process = OS.create_process(engine_path, full_args)
	if _process < 0:
		push_error("ProtohackClient: failed to launch engine at: " + engine_path)
		return false

	# Godot 4 uses OS.create_process which gives a PID but no pipe.
	# We use the pipe-based approach via stdin/stdout redirection instead.
	push_error("ProtohackClient: OS.create_process does not provide pipes. Use _start_piped().")
	return false


func start_piped(engine_path: String, engine_args: Array[String] = []) -> bool:
	_mutex = Mutex.new()
	_running = true

	_thread = Thread.new()
	_thread.start(_reader_thread.bind(engine_path, engine_args))
	return true


func _reader_thread(engine_path: String, engine_args: Array[String]) -> void:
	# Build command: engine_path + args
	var argv: PackedStringArray = PackedStringArray()
	argv.append(engine_path)
	for a in engine_args:
		argv.append(a)

	# Use Godot's OS.execute in blocking mode isn't ideal, but for a local
	# prototype we read the full output then parse. For streaming, this needs
	# a proper pipe (use Python shim or gdnative for production).
	#
	# For now, we spawn a Python shim that relays the pipe as a TCP connection.
	# See: scripts/engine_relay.py
	#
	# This thread implementation reads from a pre-opened pipe file descriptor.
	# The actual streaming is handled by WorldMap.gd via the relay approach.
	pass


func poll() -> void:
	_mutex.lock()
	var events := _pending.duplicate()
	_pending.clear()
	_mutex.unlock()
	for evt in events:
		_dispatch(evt)


func _dispatch(evt: Dictionary) -> void:
	var ns: String = evt.get("ns", "")
	var event: String = evt.get("event", "")
	var fields: Dictionary = evt.get("fields", {})

	match ns + "." + event:
		"engine.hello":
			emit_signal("handshake_done")
		"worldmap.map_begin":
			emit_signal("worldmap_begin",
				int(fields.get("hex_count", "0")),
				float(fields.get("hex_size", "1.0")),
				float(fields.get("origin_x", "0.0")),
				float(fields.get("origin_y", "0.0")))
		"worldmap.hex":
			emit_signal("worldmap_hex", fields)
		"worldmap.map_end":
			emit_signal("worldmap_end")
		"world.prompt":
			emit_signal("prompt_received", fields.get("type", ""))
		"engine.error":
			emit_signal("engine_error",
				fields.get("code", "unknown"),
				fields.get("message", ""))


## Parse one protohack line: "< ns.event key=value key=\"string\" ..."
static func parse_line(line: String) -> Dictionary:
	var result := {"ns": "", "event": "", "fields": {}}
	line = line.strip_edges()
	if not line.begins_with("< "):
		return result

	var parts := line.substr(2).split(" ", false)
	if parts.is_empty():
		return result

	var ns_event := parts[0].split(".", false, 1)
	if ns_event.size() < 2:
		return result

	result["ns"] = ns_event[0]
	result["event"] = ns_event[1]

	var fields: Dictionary = {}
	for i in range(1, parts.size()):
		var kv := parts[i]
		var eq := kv.find("=")
		if eq < 0:
			continue
		var key := kv.substr(0, eq)
		var val := kv.substr(eq + 1)
		# Strip surrounding quotes if present
		if val.begins_with('"') and val.ends_with('"'):
			val = val.substr(1, val.length() - 2)
		fields[key] = val
	result["fields"] = fields
	return result
