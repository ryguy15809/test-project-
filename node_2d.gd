extends Node2D

enum GameMode {
	TITLE,
	LOBBY,
	ONE_ON_ONE,
	FREE_FOR_ALL,
}

@export var server_port: int = 7777
@export var max_players: int = 32

@onready var networks = $NetworkManager
@onready var main_page = $UI/MainPage
@onready var loading_page = $UI/LoadingPage
@onready var battle_one_on_one_page = $UI/BattleOneOnOnePage
@onready var battle_coop_page = $UI/BattleCoopPage
@onready var lobby = $NetworkManager/Lobby
@onready var one_on_one = $NetworkManager/OneOnOneMatch
@onready var free_for_all = $NetworkManager/FreeForAllMatch

var game_mode: GameMode = GameMode.TITLE

func _ready() -> void:
	show_main_page()

func create_server(port: int = server_port, max_clients: int = max_players) -> void:
	var peer = ENetMultiplayerPeer.new()
	peer.create_server(port, max_clients)
	get_tree().multiplayer.multiplayer_peer = peer
	get_tree().connect("network_peer_connected", self, "_on_network_peer_connected")
	get_tree().connect("network_peer_disconnected", self, "_on_network_peer_disconnected")
	get_tree().connect("connected_to_server", self, "_on_connected_to_server")
	get_tree().connect("connection_failed", self, "_on_connection_failed")
	get_tree().connect("server_disconnected", self, "_on_server_disconnected")

func join_server(host: String, port: int = server_port) -> void:
	var peer = ENetMultiplayerPeer.new()
	peer.create_client(host, port)
	get_tree().multiplayer.multiplayer_peer = peer

func show_main_page() -> void:
	game_mode = GameMode.TITLE
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

func _on_network_peer_connected(id: int) -> void:
	print("Peer connected:", id)

func _on_network_peer_disconnected(id: int) -> void:
	print("Peer disconnected:", id)

func _on_connected_to_server() -> void:
	print("Connected to server")

func _on_connection_failed() -> void:
	print("Connection failed")

func _on_server_disconnected() -> void:
	print("Server disconnected")

func _process(delta: float) -> void:
	pass
