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
const OPPONENT_CURSOR_ALPHA := 0.45  # faded so you can tell your side
const BOT_PULL_STEP := 0.012  # smaller tugs...
const BOT_MIN_DELAY := 0.02   # ...but quicker, like mashing keys (4x)
const BOT_MAX_DELAY := 0.04
const BOT_RATE_MIN := 0.6     # slow spells pull at 60% pace...
const BOT_RATE_MAX := 1.4     # ...bursts at 140% (±40% variation)
const BOT_RATE_MIN_T := 0.4   # a pace lasts ~0.5s before re-rolling
const BOT_RATE_MAX_T := 0.6

const AUTH_ENABLED := false  # TODO: flip to true to re-enable login + stat saving

@export var server_port: int = 8080
@export var max_players: int = 32
# In the browser these are derived from the page's own origin (see _derive_origin_urls),
# so no domain is hardcoded. Set them explicitly only for desktop builds.
@export var server_url: String = ""
@export var auth_url: String = ""

@onready var main_page = $UI/MainPage
@onready var login_page = $UI/LoginPage
@onready var loading_page = $UI/LoadingPage
@onready var battle_one_on_one_page = $UI/BattleOneOnOnePage
@onready var battle_coop_page = $UI/BattleCoopPage
@onready var lobby = $NetworkManager/Lobby
@onready var one_on_one = $UI/BattleOneOnOnePage/OneOnOneMatch
@onready var free_for_all = $UI/BattleCoopPage/FreeForAllMatch
@onready var loading_bar: ProgressBar = $UI/LoadingPage/LoadingBar
@onready var players_label: Label = $UI/LoadingPage/Label
@onready var connection_failed_dialog: AcceptDialog = $UI/ConnectionFailedDialog
@onready var login_error: Label = $UI/LoginPage/LoginError
@onready var login_username: LineEdit = $UI/LoginPage/Username
@onready var login_password: LineEdit = $UI/LoginPage/Password
@onready var auth_http: HTTPRequest = $UI/AuthHTTP

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
var _bot_rate: float = 1.0    # current pace multiplier (wanders 0.7-1.3)
var _bot_rate_t: float = 0.0  # time left on the current pace
var _connecting_cancelled := false
# ---- auth state ----
var _token: String = ""
var _account_id: int = 0
var _username: String = ""
var _auth_pending: String = ""  # "" | "login" | "register" | "validate" | "record"
# ---- guest stats (local, used when not logged in) ----
var _guest_wins: int = 0
var _guest_losses: int = 0


func _ready() -> void:
	if OS.has_feature("web"):
		_derive_origin_urls()
	multiplayer.peer_connected.connect(_on_network_peer_connected)
	multiplayer.peer_disconnected.connect(_on_network_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	if _is_server:
		_server_setup()
		return

	_style_main_buttons()
	_style_dark_button($UI/LoadingPage/Button)
	_style_dark_button(connection_failed_dialog.get_ok_button())
	_style_auth_buttons()
	$UI/MainPage/BtnOneOnOne.pressed.connect(_on_one_on_one_pressed)
	$UI/MainPage/BtnCoop.pressed.connect(_on_coop_pressed)
	$UI/MainPage/BtnSingleplayer.pressed.connect(_on_singleplayer_pressed)
	$UI/LoadingPage/Button.pressed.connect(_on_exit_pressed)
	$UI/LoginPage/BtnLogin.pressed.connect(_on_login_pressed)
	$UI/LoginPage/BtnRegister.pressed.connect(_on_register_pressed)
	$UI/LoginPage/BtnBack.pressed.connect(_on_back_pressed)
	$UI/MainPage/BtnAccount.pressed.connect(_on_account_pressed)
	auth_http.request_completed.connect(_on_auth_response)

	if AUTH_ENABLED:
		$UI/MainPage/BtnAccount.visible = true
		_load_guest_stats()
		_try_auto_login()
	else:
		$UI/MainPage/BtnAccount.visible = false

	show_main_page()


# Derive the server/auth URLs from the browser's own origin, so the game works
# from any domain without hardcoding one. No-op outside the browser (desktop
# keeps the @export defaults) or if detection fails.
func _derive_origin_urls() -> void:
	var protocol := str(JavaScriptBridge.eval("window.location.protocol"))  # "https:" or "http:"
	var host := str(JavaScriptBridge.eval("window.location.host"))          # "example.com" (or with :port)
	if host.is_empty():
		return
	var is_https := protocol == "https:"
	server_url = ("wss://" if is_https else "ws://") + host + "/ws"
	auth_url = ("https://" if is_https else "http://") + host + "/api"


func _make_button_style(bg: Color, bordered: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.draw_center = true
	if bordered:
		style.set_border_width_all(7)
		style.border_color = bg.darkened(0.25)  # one shade darker than the fill
		# outer radius = inner radius + border width, so the border's
		# inner edge stays rounded too (no square corners inside)
		style.set_corner_radius_all(13)
	else:
		style.set_corner_radius_all(8)
	return style


func _apply_button_style(button: Button, normal_c: Color, hover_c: Color, pressed_c: Color, bordered: bool) -> void:
	button.add_theme_stylebox_override("normal", _make_button_style(normal_c, bordered))
	button.add_theme_stylebox_override("hover", _make_button_style(hover_c, bordered))
	button.add_theme_stylebox_override("pressed", _make_button_style(pressed_c, bordered))


func _style_main_buttons() -> void:
	for button in [$UI/MainPage/BtnOneOnOne, $UI/MainPage/BtnCoop, $UI/MainPage/BtnInstructions, $UI/MainPage/BtnSingleplayer]:
		_apply_button_style(button, Color.WHITE, Color.LIGHT_GRAY, Color.GRAY, true)
		button.add_theme_color_override("font_color", Color.BLACK)
		button.add_theme_color_override("font_hover_color", Color.BLACK)
		button.add_theme_color_override("font_pressed_color", Color.BLACK)


func _style_dark_button(button: Button) -> void:
	_apply_button_style(button, Color(0.23, 0.23, 0.26), Color(0.3, 0.3, 0.34), Color(0.17, 0.17, 0.2), false)


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
	_update_cursor_sides()
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
	_record_result(winner == _my_side)


func _process(delta: float) -> void:
	if _is_server:
		_server_process(delta)
		return
	if game_mode != GameMode.ONE_ON_ONE and game_mode != GameMode.FREE_FOR_ALL:
		return
	# singleplayer bot
	if _singleplayer and _phase == "play" and game_mode == GameMode.ONE_ON_ONE:
		_bot_rate_t -= delta
		if _bot_rate_t <= 0.0:
			_bot_rate_t = randf_range(BOT_RATE_MIN_T, BOT_RATE_MAX_T)
			_bot_rate = randf_range(BOT_RATE_MIN, BOT_RATE_MAX)
		_bot_t -= delta
		if _bot_t <= 0.0:
			_bot_t = randf_range(BOT_MIN_DELAY, BOT_MAX_DELAY) / _bot_rate
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


func _update_cursor_sides() -> void:
	var rig := _rope_rig()
	# Cursor1 sits at the blue (right) end, Cursor2 at the red (left) end.
	var blue_end: Sprite2D = rig.get_node("Cursor1")
	var red_end: Sprite2D = rig.get_node("Cursor2")
	blue_end.modulate.a = 1.0
	red_end.modulate.a = 1.0
	var opponent: Sprite2D = red_end if _my_side == SIDE_BLUE else blue_end
	opponent.modulate.a = OPPONENT_CURSOR_ALPHA


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


# ---------------------------------------------------------------------------
#  Auth — login, register, token persistence
# ---------------------------------------------------------------------------

const AUTH_TOKEN_PATH := "user://auth.cfg"
const GUEST_STATS_PATH := "user://guest_stats.cfg"


func _style_auth_buttons() -> void:
	for button in [$UI/LoginPage/BtnLogin, $UI/LoginPage/BtnRegister, $UI/LoginPage/BtnBack, $UI/MainPage/BtnAccount]:
		_apply_button_style(button, Color.WHITE, Color.LIGHT_GRAY, Color.GRAY, true)
		button.add_theme_color_override("font_color", Color.BLACK)
		button.add_theme_color_override("font_hover_color", Color.BLACK)
		button.add_theme_color_override("font_pressed_color", Color.BLACK)


func _try_auto_login() -> void:
	"""Silently validate a saved token.  Stay a guest if none/invalid."""
	if not AUTH_ENABLED:
		return
	var token := _load_token()
	if token.is_empty():
		return  # guest — stay on the main page

	_auth_pending = "validate"
	_http_post("/validate", {}, {"Authorization": "Bearer " + token})


func _update_account_button() -> void:
	var btn: Button = $UI/MainPage/BtnAccount
	if _username.is_empty():
		btn.text = "Login"
	else:
		btn.text = "Logout (%s)" % _username


# ----- HTTP helpers ----------------------------------------------------

func _http_post(path: String, body: Dictionary, headers: Dictionary = {}) -> void:
	var url := auth_url + path
	var json_body := JSON.stringify(body)
	var hdr := PackedStringArray(["Content-Type: application/json"])
	for key in headers:
		hdr.append(key + ": " + headers[key])
	var err := auth_http.request(url, hdr, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		printerr("Auth HTTP request failed: ", error_string(err))
		_on_auth_response(-1, 0, PackedStringArray(), PackedByteArray())


func _on_auth_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var text := body.get_string_from_utf8()
	print("Auth response [%d] %d: %s" % [result, response_code, text.left(200)])

	var pending := _auth_pending
	_auth_pending = ""

	if result != HTTPRequest.RESULT_SUCCESS:
		if pending in ["login", "register"]:
			login_error.text = "Cannot reach auth server"
		# validate/record failures are silent — stay guest, data stays local
		return

	var json := JSON.new()
	if json.parse(text) != OK:
		if pending in ["login", "register"]:
			login_error.text = "Invalid server response"
		return

	var data: Dictionary = json.data

	match pending:
		"validate":
			if data.get("valid", false):
				_token = _load_token()
				_account_id = data.get("account_id", 0)
				_username = data.get("username", "")
				_update_account_button()
			else:
				_clear_saved_token()

		"login", "register":
			if response_code in [200, 201] and not data.get("token", "").is_empty():
				_token = data["token"]
				_account_id = data.get("account_id", 0)
				_username = data.get("username", "")
				_save_token(_token)
				login_username.text = ""
				login_password.text = ""
				login_error.text = ""
				_update_account_button()
				show_main_page()
			else:
				login_error.text = data.get("error", "Login failed")

		"record":
			pass  # fire-and-forget stats update — nothing to show the user


# ----- button callbacks ----------------------------------------------------

func _on_login_pressed() -> void:
	var u := login_username.text.strip_edges()
	var p := login_password.text
	if u.is_empty() or p.is_empty():
		login_error.text = "Fill in both fields"
		return
	login_error.text = ""
	_auth_pending = "login"
	_http_post("/login", {"username": u, "password": p})


func _on_register_pressed() -> void:
	var u := login_username.text.strip_edges()
	var p := login_password.text
	if u.is_empty() or p.is_empty():
		login_error.text = "Fill in both fields"
		return
	if p.length() < 4:
		login_error.text = "Password must be at least 4 characters"
		return
	login_error.text = ""
	_auth_pending = "register"
	_http_post("/register", {"username": u, "password": p})


func _on_account_pressed() -> void:
	# top-left button: guest → open login; logged in → log out
	if _username.is_empty():
		_show_login_page()
	else:
		_on_logout_pressed()


func _on_back_pressed() -> void:
	login_error.text = ""
	show_main_page()


func _on_logout_pressed() -> void:
	var token := _load_token()
	if not token.is_empty():
		_http_post("/logout", {}, {"Authorization": "Bearer " + token})
	_clear_saved_token()
	_token = ""
	_account_id = 0
	_username = ""
	_update_account_button()
	show_main_page()


# ----- token file ----------------------------------------------------

func _save_token(t: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("auth", "token", t)
	cfg.save(AUTH_TOKEN_PATH)


func _load_token() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(AUTH_TOKEN_PATH) == OK:
		return cfg.get_value("auth", "token", "")
	return ""


func _clear_saved_token() -> void:
	var cfg := ConfigFile.new()
	cfg.save(AUTH_TOKEN_PATH)  # overwrite with empty


# ----- guest stats (local-only persistence) --------------------------------

func _load_guest_stats() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(GUEST_STATS_PATH) == OK:
		_guest_wins = int(cfg.get_value("guest", "wins", 0))
		_guest_losses = int(cfg.get_value("guest", "losses", 0))


func _save_guest_stats() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("guest", "wins", _guest_wins)
	cfg.set_value("guest", "losses", _guest_losses)
	cfg.save(GUEST_STATS_PATH)


func _record_result(won: bool) -> void:
	"""Record a round win/loss.  Logged in → server; guest → local file."""
	if not AUTH_ENABLED:
		return
	if _token.is_empty():
		if won:
			_guest_wins += 1
		else:
			_guest_losses += 1
		_save_guest_stats()
	else:
		_auth_pending = "record"
		_http_post("/stats/record", {"won": won}, {"Authorization": "Bearer " + _token})


# ----- page transitions ----------------------------------------------------

func _show_login_page() -> void:
	game_mode = GameMode.TITLE
	_phase = "idle"
	login_page.visible = true
	main_page.visible = false
	loading_page.visible = false
	battle_one_on_one_page.visible = false
	battle_coop_page.visible = false
	lobby.visible = false
	one_on_one.visible = false
	free_for_all.visible = false


func show_main_page() -> void:
	game_mode = GameMode.TITLE
	_pending_mode = GameMode.TITLE
	_phase = "idle"
	login_page.visible = false
	main_page.visible = true
	loading_page.visible = false
	battle_one_on_one_page.visible = false
	battle_coop_page.visible = false
	lobby.visible = false
	one_on_one.visible = false
	free_for_all.visible = false
	_update_account_button()
