extends Node2D

enum GameMode {
	TITLE,
	LOBBY,
	ONE_ON_ONE,
	FREE_FOR_ALL,
}

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

var game_mode: GameMode = GameMode.TITLE
var _pending_mode: GameMode = GameMode.TITLE
var _is_server := "--server" in OS.get_cmdline_user_args()
var _server_queue: Dictionary = {}  # mode (int) -> Array[peer_id]


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
	print("Starting match (mode %d) with peers %d and %d" % [mode, a, b])
	_start_match.rpc_id(a, 0, mode)
	_start_match.rpc_id(b, 1, mode)


func _queue_remove(id: int) -> void:
	for mode in _server_queue:
		var q: Array = _server_queue[mode]
		if q.has(id):
			q.erase(id)


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
	start_one_on_one()


func _connect_to_server() -> void:
	show_loading_page()
	var peer := WebSocketMultiplayerPeer.new()
	var err: int = peer.create_client(server_url)
	if err != OK:
		print("Failed to start client: ", error_string(err))
		show_main_page()
		return
	multiplayer.multiplayer_peer = peer


@rpc("authority", "call_remote", "reliable")
func _start_match(side: int, mode: int) -> void:
	print("Match started — side ", side, " mode ", mode)
	if mode == GameMode.ONE_ON_ONE:
		start_one_on_one()
	elif mode == GameMode.FREE_FOR_ALL:
		start_coop()


# ---------------------------------------------------------------------------
#  Page transitions
# ---------------------------------------------------------------------------

func show_main_page() -> void:
	game_mode = GameMode.TITLE
	_pending_mode = GameMode.TITLE
	main_page.visible = true
	loading_page.visible = false
	battle_one_on_one_page.visible = false
	battle_coop_page.visible = false
	lobby.visible = false
	one_on_one.visible = false
	free_for_all.visible = false


func show_loading_page() -> void:
	game_mode = GameMode.LOBBY
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
#  Network events
# ---------------------------------------------------------------------------

func _on_network_peer_connected(id: int) -> void:
	print("Peer connected:", id)


func _on_network_peer_disconnected(id: int) -> void:
	print("Peer disconnected:", id)
	if _is_server:
		_queue_remove(id)


func _on_connected_to_server() -> void:
	print("Connected to server")
	_request_join.rpc(_pending_mode)


func _on_connection_failed() -> void:
	print("Connection failed")
	show_main_page()


func _on_server_disconnected() -> void:
	print("Server disconnected")
	multiplayer.multiplayer_peer = null
	show_main_page()


func _process(_delta: float) -> void:
	pass
