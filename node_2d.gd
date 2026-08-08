extends Node2D

enum GameMode {
	TITLE,
	LOBBY,
	ONE_ON_ONE,
	FREE_FOR_ALL,
}

const SIDE_RED := 0  # left
const SIDE_BLUE := 1  # right

const PULL_STEP := 0.03       # rope movement per press
const COOP_DRIFT := 0.05      # rope slide toward the AI side per second (co-op)
const ROPE_RANGE_PX := 220.0  # pixels the rope rig moves at rope = +-1
const BOT_PULL_STEP := 0.012  # smaller tugs...
const BOT_MIN_DELAY := 0.08   # ...but quicker, like mashing keys
const BOT_MAX_DELAY := 0.16

@export var server_port: int = 8080
@export var max_players: int = 32
@export var server_url: String = "ws://141.148.32.59:8080"

@onready var main_page = $UI/MainPage
@onready var loading_page = $UI/LoadingPage
@onready var battle_one_on_one_page = $UI/BattleOneOnOnePage
@onready var battle_coop_page = $UI/BattleCoopPage
@onready var lobby = $NetworkManager/Lobby
@onready var one_on_one = $UI/BattleOneOnOnePage/OneOnOneMatch
@onready var free_for_all = $UI/BattleCoopPage/FreeForAllMatch
@onready var loading_bar: ProgressBar = $UI/LoadingPage/LoadingBar
@onready var players_label: Label = $UI/LoadingPage/Label
@onready var connection_failed_dialog: AcceptDialog = $UI/ConnectionFailedDialog

var game_mode: GameMode = GameMode.TITLE
var _pending_mode: GameMode = GameMode.TITLE
var _is_server := "--server" in OS.get_cmdline_user_args()

# ---- server-only state ----
var _server_queue: Dictionary = {}  # mode (int) -> Array[peer_id]
var _matches: Dictionary = {}       # peer_id -> match Dictionary
var _match_list: Array = []         # the unique match Dictionaries

# ---- client-only state ----
var _singleplayer := false
var _my_side: int = SIDE_RED
var _rope: float = 0.0  # -1 = red wins, +1 = blue wins
var _score_red: int = 0
var _score_blue: int = 0
var _phase: String = "idle"  # idle | countdown | go | play | round_end
var _phase_t: float = 0.0
var _bot_t: float = 0.0
var _connecting_cancelled := false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_network_peer_connected)
	multiplayer.peer_disconnected.connect(_on_network_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	if _is_server:
		_server_setup()
		return

	_style_main_buttons()
	$UI/MainPage/BtnOneOnOne.pressed.connect(_on_one_on_one_pressed)
	$UI/MainPage/BtnCoop.pressed.connect(_on_coop_pressed)
	$UI/MainPage/BtnSingleplayer.pressed.connect(_on_singleplayer_pressed)
	$UI/LoadingPage/Button.pressed.connect(_on_exit_pressed)
	show_main_page()


func _style_main_buttons() -> void:
	var normal_style: StyleBoxFlat = StyleBoxFlat.new()
	normal_style.bg_color = Color.WHITE
	normal_style.draw_center = true
	var hover_style: StyleBoxFlat = StyleBoxFlat.new()
	hover_style.bg_color = Color.LIGHT_GRAY
	hover_style.draw_center = true
	var pressed_style: StyleBoxFlat = StyleBoxFlat.new()
	pressed_style.bg_color = Color.GRAY
	pressed_style.draw_center = true
	for button in [$UI/MainPage/BtnOneOnOne, $UI/MainPage/BtnCoop, $UI/MainPage/BtnInstructions, $UI/MainPage/BtnSingleplayer]:
		button.add_theme_stylebox_override("normal", normal_style)
		button.add_theme_stylebox_override("hover", hover_style)
		button.add_theme_stylebox_override("pressed", pressed_style)
		button.add_theme_color_override("font_color", Color.BLACK)
		button.add_theme_color_override("font_hover_color", Color.BLACK)
		button.add_theme_color_override("font_pressed_color", Color.BLACK)


# ---------------------------------------------------------------------------
#  Server (dedicated host) — run with:  godot --headless -- --server
# ---------------------------------------------------------------------------

func _server_setup() -> void:
	var peer := WebSocketMultiplayerPeer.new()
	var err: int = peer.create_server(server_port)
	if err != OK:
		push_error("Game server failed to listen on %d: %s" % [server_port, error_string(err)])
		return
	multiplayer.multiplayer_peer = peer
	print("Game server listening on ws://*:%d (headless)" % server_port)


@rpc("any_peer", "call_remote", "reliable")
func _request_join(mode: int) -> void:
	if not _is_server:
		return
	var id: int = multiplayer.get_remote_sender_id()
	_queue_add(id, mode)
	print("Player %d queued for mode %d" % [id, mode])
	_try_start_match(mode)


func _queue_add(id: int, mode: int) -> void:
	if not _server_queue.has(mode):
		_server_queue[mode] = []
	var q: Array = _server_queue[mode]
	if not q.has(id):
		q.append(id)


func _try_start_match(mode: int) -> void:
	var q: Array = _server_queue.get(mode, [])
	if q.size() < 2:
		return
	var a: int = q.pop_front()
	var b: int = q.pop_front()
	var side_a: int = randi() % 2
	# 1v1: opponent gets the opposite side. Co-op: teammates share a side.
	var side_b: int = side_a if mode == GameMode.FREE_FOR_ALL else 1 - side_a
	var sides := {}
	sides[a] = side_a
	sides[b] = side_b
	var m := {
		"ids": [a, b],
		"sides": sides,
		"rope": 0.0,
		"red": 0,
		"blue": 0,
		"mode": mode,
		"sync_t": 0.0,
	}
	_matches[a] = m
	_matches[b] = m
	_match_list.append(m)
	print("Starting match (mode %d): peer %d side %d, peer %d side %d" % [mode, a, side_a, b, side_b])
	_start_match.rpc_id(a, side_a, mode)
	_start_match.rpc_id(b, side_b, mode)


func _queue_remove(id: int) -> void:
	for mode in _server_queue:
		var q: Array = _server_queue[mode]
		if q.has(id):
			q.erase(id)


@rpc("any_peer", "call_remote", "reliable")
func _pull() -> void:
	if not _is_server:
		return
	var id: int = multiplayer.get_remote_sender_id()
	var m: Dictionary = _matches.get(id, {})
	if m.is_empty():
		return
	var dir := 1.0 if m.sides[id] == SIDE_BLUE else -1.0
	m.rope = clampf(m.rope + dir * PULL_STEP, -1.0, 1.0)
	_server_sync_rope(m)
	_server_check_end(m)


func _server_sync_rope(m: Dictionary) -> void:
	for pid in m.ids:
		_rope_sync.rpc_id(pid, m.rope)


func _server_check_end(m: Dictionary) -> void:
	if m.rope >= 1.0:
		_server_round_end(m, SIDE_BLUE)
	elif m.rope <= -1.0:
		_server_round_end(m, SIDE_RED)


func _server_round_end(m: Dictionary, winner: int) -> void:
	if winner == SIDE_RED:
		m.red += 1
	else:
		m.blue += 1
	m.rope = 0.0
	print("Round end: winner side %d (red %d - blue %d)" % [winner, m.red, m.blue])
	for pid in m.ids:
		_round_end.rpc_id(pid, winner, m.red, m.blue)


func _server_drop_match(id: int) -> void:
	if not _matches.has(id):
		return
	var m: Dictionary = _matches[id]
	for pid in m.ids:
		_matches.erase(pid)
		if pid != id:
			_opponent_left.rpc_id(pid)
	_match_list.erase(m)


# ---------------------------------------------------------------------------
#  Client
# ---------------------------------------------------------------------------

func _on_one_on_one_pressed() -> void:
	_pending_mode = GameMode.ONE_ON_ONE
	_connect_to_server()


func _on_coop_pressed() -> void:
	_pending_mode = GameMode.FREE_FOR_ALL
	_connect_to_server()


func _on_singleplayer_pressed() -> void:
	_singleplayer = true
	_begin_match(randi() % 2, GameMode.ONE_ON_ONE)


func _on_exit_pressed() -> void:
	_pending_mode = GameMode.TITLE
	_connecting_cancelled = true
	multiplayer.multiplayer_peer = null  # drops the connecting/connected socket
	show_main_page()


func _connect_to_server() -> void:
	_connecting_cancelled = false
	show_loading_page()
	var peer := WebSocketMultiplayerPeer.new()
	var err: int = peer.create_client(server_url)
	if err != OK:
		print("Failed to start client: ", error_string(err))
		_on_connection_failed()
		return
	multiplayer.multiplayer_peer = peer


@rpc("authority", "call_remote", "reliable")
func _start_match(side: int, mode: int) -> void:
	print("Match started — side ", side, " mode ", mode)
	loading_bar.value = 100.0
	players_label.text = "Players found 2/2"
	_singleplayer = false
	_begin_match(side, mode)


@rpc("authority", "call_remote", "reliable")
func _rope_sync(rope: float) -> void:
	_rope = rope
	_update_rope_visual()


@rpc("authority", "call_remote", "reliable")
func _round_end(winner: int, red: int, blue: int) -> void:
	_score_red = red
	_score_blue = blue
	_show_round_end(winner)


@rpc("authority", "call_remote", "reliable")
func _opponent_left() -> void:
	print("Opponent left the match")
	show_main_page()


func _begin_match(side: int, mode: int) -> void:
	_my_side = side
	_rope = 0.0
	_score_red = 0
	_score_blue = 0
	if mode == GameMode.ONE_ON_ONE:
		start_one_on_one()
	else:
		start_coop()
	_update_score_labels()
	_update_rope_visual()
	_begin_countdown()


# NOTE: uses _input, not _unhandled_input — the full-screen page Controls
# have mouse_filter=STOP and would swallow mouse clicks before they reach us.
func _input(event: InputEvent) -> void:
	if _phase != "play":
		return
	var pressed := false
	if event is InputEventKey:
		pressed = event.pressed and not event.is_echo()
	elif event is InputEventMouseButton:
		pressed = event.pressed
	if not pressed:
		return
	if _singleplayer:
		_local_pull(_my_side)
	else:
		_pull.rpc()


func _local_pull(side: int, step: float = PULL_STEP) -> void:
	var dir := 1.0 if side == SIDE_BLUE else -1.0
	_rope = clampf(_rope + dir * step, -1.0, 1.0)
	_update_rope_visual()
	if _rope >= 1.0:
		_local_round_end(SIDE_BLUE)
	elif _rope <= -1.0:
		_local_round_end(SIDE_RED)


func _local_round_end(winner: int) -> void:
	if winner == SIDE_RED:
		_score_red += 1
	else:
		_score_blue += 1
	_show_round_end(winner)


# ---------------------------------------------------------------------------
#  Round flow (countdown -> play -> round end -> countdown ...)
# ---------------------------------------------------------------------------

func _begin_countdown() -> void:
	_phase = "countdown"
	_phase_t = 3.0
	var label := _countdown_label()
	if label:
		label.visible = true
		label.text = "3"


func _show_round_end(winner: int) -> void:
	_update_score_labels()
	_phase = "round_end"
	_phase_t = 1.5
	var label := _countdown_label()
	if label:
		label.visible = true
		label.text = "Red wins!" if winner == SIDE_RED else "Blue wins!"


func _process(delta: float) -> void:
	if _is_server:
		_server_process(delta)
		return
	if game_mode != GameMode.ONE_ON_ONE and game_mode != GameMode.FREE_FOR_ALL:
		return
	# singleplayer bot
	if _singleplayer and _phase == "play" and game_mode == GameMode.ONE_ON_ONE:
		_bot_t -= delta
		if _bot_t <= 0.0:
			_bot_t = randf_range(BOT_MIN_DELAY, BOT_MAX_DELAY)
			_local_pull(1 - _my_side, BOT_PULL_STEP)
	# round phase machine
	match _phase:
		"countdown":
			_phase_t -= delta
			var label := _countdown_label()
			if label:
				label.text = str(maxi(1, ceili(_phase_t)))
			if _phase_t <= 0.0:
				_phase = "go"
				_phase_t = 0.5
				if label:
					label.text = "GO!"
		"go":
			_phase_t -= delta
			if _phase_t <= 0.0:
				_phase = "play"
				var label := _countdown_label()
				if label:
					label.visible = false
				_bot_t = randf_range(BOT_MIN_DELAY, BOT_MAX_DELAY)
		"round_end":
			_phase_t -= delta
			if _phase_t <= 0.0:
				_rope = 0.0
				_update_rope_visual()
				_begin_countdown()


func _server_process(delta: float) -> void:
	for m in _match_list:
		if m.mode != GameMode.FREE_FOR_ALL:
			continue
		var team_dir := 1.0 if m.sides[m.ids[0]] == SIDE_BLUE else -1.0
		m.rope = clampf(m.rope - team_dir * COOP_DRIFT * delta, -1.0, 1.0)
		m.sync_t += delta
		if m.sync_t >= 0.1:
			m.sync_t = 0.0
			_server_sync_rope(m)
		_server_check_end(m)


# ---------------------------------------------------------------------------
#  Page transitions
# ---------------------------------------------------------------------------

func show_main_page() -> void:
	game_mode = GameMode.TITLE
	_pending_mode = GameMode.TITLE
	_phase = "idle"
	main_page.visible = true
	loading_page.visible = false
	battle_one_on_one_page.visible = false
	battle_coop_page.visible = false
	lobby.visible = false
	one_on_one.visible = false
	free_for_all.visible = false


func show_loading_page() -> void:
	game_mode = GameMode.LOBBY
	loading_bar.value = 40.0  # jump: connecting stage
	players_label.text = "Connecting..."
	main_page.visible = false
	loading_page.visible = true
	battle_one_on_one_page.visible = false
	battle_coop_page.visible = false


func start_one_on_one() -> void:
	game_mode = GameMode.ONE_ON_ONE
	main_page.visible = false
	loading_page.visible = false
	battle_one_on_one_page.visible = true
	battle_coop_page.visible = false
	lobby.visible = false
	one_on_one.visible = true
	free_for_all.visible = false


func start_coop() -> void:
	game_mode = GameMode.FREE_FOR_ALL
	main_page.visible = false
	loading_page.visible = false
	battle_one_on_one_page.visible = false
	battle_coop_page.visible = true
	lobby.visible = false
	one_on_one.visible = false
	free_for_all.visible = true


# ---------------------------------------------------------------------------
#  Battle page helpers
# ---------------------------------------------------------------------------

func _countdown_label() -> Label:
	if game_mode == GameMode.FREE_FOR_ALL:
		return $UI/BattleCoopPage/CoopCountdown
	return $UI/BattleOneOnOnePage/Countdown


func _rope_rig() -> Node2D:
	if game_mode == GameMode.FREE_FOR_ALL:
		return $UI/BattleCoopPage/CoopRopes
	return $UI/BattleOneOnOnePage/OneOnOneRopes


func _update_rope_visual() -> void:
	_rope_rig().position.x = _rope * ROPE_RANGE_PX


func _update_score_labels() -> void:
	var left: Label
	var right: Label
	if game_mode == GameMode.FREE_FOR_ALL:
		left = $UI/BattleCoopPage/CoopRedScore
		right = $UI/BattleCoopPage/CoopBlueScore
	else:
		left = $UI/BattleOneOnOnePage/OneOnOnePlayer1Score
		right = $UI/BattleOneOnOnePage/OneOnOnePlayer2Score
	left.text = "Red: %d" % _score_red
	right.text = "Blue: %d" % _score_blue


# ---------------------------------------------------------------------------
#  Network events
# ---------------------------------------------------------------------------

func _on_network_peer_connected(id: int) -> void:
	print("Peer connected:", id)


func _on_network_peer_disconnected(id: int) -> void:
	print("Peer disconnected:", id)
	if _is_server:
		_queue_remove(id)
		_server_drop_match(id)


func _on_connected_to_server() -> void:
	print("Connected to server")
	loading_bar.value = 90.0  # jump: queued, waiting for an opponent
	players_label.text = "Players found 1/2"
	_request_join.rpc(_pending_mode)


func _on_connection_failed() -> void:
	print("Connection failed")
	var cancelled := _connecting_cancelled
	_connecting_cancelled = false
	show_main_page()
	if not cancelled:
		connection_failed_dialog.popup_centered()


func _on_server_disconnected() -> void:
	print("Server disconnected")
	multiplayer.multiplayer_peer = null
	show_main_page()
