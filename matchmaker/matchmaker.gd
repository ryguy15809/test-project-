extends Node

## Matchmaking server (standalone Godot headless project).
## Keeps a registry of open game hosts and lets game clients find them.
## Protocol: JSON messages over WebSocket (see README/plan).

const PORT := 8080
const STALE_TIMEOUT := 90.0

var tcp_server := TCPServer.new()
# ws -> { "tcp": StreamPeerTCP, "registered_id": int }
var clients := {}
# { "id": int, "ip": String, "port": int, "mode": String, "last_seen": float }
var games := []
var _next_id := 0


func _ready() -> void:
	var err: Error = tcp_server.listen(PORT)
	if err != OK:
		push_error("Matchmaker failed to listen on port %d: %s" % [PORT, error_string(err)])
	else:
		print("Matchmaker listening on port %d" % PORT)


func _process(_delta: float) -> void:
	_accept_new_connections()
	_poll_clients()
	_cleanup_stale(_now())


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _accept_new_connections() -> void:
	while tcp_server.is_connection_available():
		var tcp: StreamPeerTCP = tcp_server.take_connection()
		var ws := WebSocketPeer.new()
		if ws.accept_stream(tcp) != OK:
			tcp.disconnect_from_host()
			continue
		clients[ws] = {"tcp": tcp, "registered_id": -1}
		print("Client connected")


func _poll_clients() -> void:
	for ws in clients.keys():
		ws.poll()
		var state: int = ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var raw: String = ws.get_packet().get_string_from_utf8()
				_handle_message(ws, raw)
		elif state == WebSocketPeer.STATE_CLOSED:
			_remove_client(ws)


func _handle_message(ws: WebSocketPeer, raw: String) -> void:
	var data: Variant = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		return
	var info: Dictionary = clients[ws]
	match String(data.get("type", "")):
		"find":
			_handle_find(ws, data)
		"register":
			info["registered_id"] = _handle_register(ws, data, info)
		"keepalive":
			_handle_keepalive(info)
		"unregister":
			_handle_unregister(info)


func _handle_find(ws: WebSocketPeer, data: Dictionary) -> void:
	var mode: String = String(data.get("mode", "one_on_one"))
	var nowv: float = _now()
	var found_game: Dictionary = {}
	for g in games:
		if String(g["mode"]) == mode and nowv - float(g["last_seen"]) < STALE_TIMEOUT:
			found_game = g
			break
	if found_game.is_empty():
		ws.send_text(JSON.stringify({"type": "none"}))
	else:
		ws.send_text(JSON.stringify({"type": "found", "host": found_game["ip"], "port": found_game["port"]}))


func _handle_register(ws: WebSocketPeer, data: Dictionary, info: Dictionary) -> int:
	if info["registered_id"] >= 0:
		_remove_game(info["registered_id"])
	_next_id += 1
	var id: int = _next_id
	var ip: String = info["tcp"].get_connected_host()
	var port: int = int(data.get("port", 0))
	var mode: String = String(data.get("mode", "one_on_one"))
	games.append({"id": id, "ip": ip, "port": port, "mode": mode, "last_seen": _now()})
	ws.send_text(JSON.stringify({"type": "ok"}))
	print("Registered host %s:%d (%s) id=%d" % [ip, port, mode, id])
	return id


func _handle_keepalive(info: Dictionary) -> void:
	if info["registered_id"] < 0:
		return
	for g in games:
		if int(g["id"]) == info["registered_id"]:
			g["last_seen"] = _now()
			return


func _handle_unregister(info: Dictionary) -> void:
	if info["registered_id"] >= 0:
		_remove_game(info["registered_id"])
		info["registered_id"] = -1


func _remove_game(id: int) -> void:
	for i in range(games.size()):
		if int(games[i]["id"]) == id:
			games.remove_at(i)
			return


func _remove_client(ws: WebSocketPeer) -> void:
	if clients.has(ws):
		var info: Dictionary = clients[ws]
		if info["registered_id"] >= 0:
			_remove_game(info["registered_id"])
		clients.erase(ws)


func _cleanup_stale(nowv: float) -> void:
	var keep: Array = []
	for g in games:
		if nowv - float(g["last_seen"]) < STALE_TIMEOUT:
			keep.append(g)
		else:
			for k in clients:
				if int(clients[k]["registered_id"]) == int(g["id"]):
					clients[k]["registered_id"] = -1
	games = keep
