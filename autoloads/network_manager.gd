extends Node

## High-level multiplayer (built-in ENetMultiplayerPeer). Peer id 1 is
## always the host/server and is authoritative for match state (see
## match_manager.gd and heat_status.gd).
##
## Joining uses a 4-digit lobby code instead of a typed IP: the host listens
## for a UDP broadcast on DISCOVERY_PORT and replies to whoever asks for its
## code with its own address, which the client then uses to open the real
## ENet connection. This only works on the same LAN/Wi-Fi (broadcasts don't
## cross routers) - there's no internet relay/matchmaking server behind this.
##
## Discovery is best-effort: some routers and phone hotspots drop broadcast
## packets or isolate clients from one another. The host's LAN IP is always
## shown in the lobby, and the join field accepts an IP address as a fallback
## for those networks.

const GAME_PORT: int = 7777
const DISCOVERY_PORT: int = 7778
const DISCOVERY_TIMEOUT: float = 5.0
const DISCOVERY_POLL_INTERVAL: float = 0.1
const DISCOVERY_RESEND_INTERVAL: float = 0.4
## A match is 4 Tubig against 1 Sili. The clock, the Sili's speed ramp and the
## rescue economy are all tuned against four runners, so this is a rule and not
## a suggestion - the lobby refuses to start a competitive series at any other
## size. The ENet cap below stops a sixth player from even connecting and
## sitting there watching.
const MATCH_SIZE: int = 5
## ENet counts CLIENTS, not total players - the host is peer 1 and is not a
## client of itself, so this is one less than MATCH_SIZE.
const MAX_CLIENTS: int = MATCH_SIZE - 1
## Practice matches are allowed to be short-handed so the team can test with
## two machines. They never open a series, so they cannot pollute the standings.
const MIN_PRACTICE_PLAYERS: int = 2
const ARENA_SCENE: String = "res://game/arena/arena.tscn"
## Which level the next round loads. Set by the host and pushed to every peer
## with the load command, never chosen locally - two peers on different maps
## would each be playing a game the other cannot see.
var current_map_id: String = MapRegistry.DEFAULT_MAP

signal player_list_changed
signal roles_assigned
signal connection_failed
signal server_disconnected
signal match_starting
signal lobby_code_ready(code: String)
signal code_lookup_failed
signal discovery_unavailable  # host couldn't open the discovery port
signal arena_peer_ready(peer_id: int)  # a peer finished building the arena scene
## Someone dropped out. Carries the name because by the time listeners run, the
## peer is already out of `players` and there is nothing left to look it up by.
signal player_left(peer_id: int, display_name: String)

var players: Dictionary = {}  # peer_id (int) -> display name (String)
var roles: Dictionary = {}    # peer_id (int) -> "sili" or "tubig"
var my_name: String = "Player"
var lobby_code: String = ""
var discovery_active: bool = false  # false => clients must join by IP

var _discovery_socket: PacketPeerUDP = null
var _is_discovery_host: bool = false

## peer_id -> true, for peers whose arena scene has finished loading. Host-side
## only; see report_arena_ready() for why this lives on the autoload.
var arena_ready_peers: Dictionary = {}


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _process(_delta: float) -> void:
	if _is_discovery_host and _discovery_socket:
		_poll_discovery_requests()


func host_game(player_name: String) -> Error:
	my_name = player_name
	var peer := ENetMultiplayerPeer.new()
	# Binds on every interface, so phones on the same Wi-Fi/hotspot can reach us.
	var err := peer.create_server(GAME_PORT, MAX_CLIENTS)
	if err != OK:
		return err

	multiplayer.multiplayer_peer = peer
	players.clear()
	roles.clear()
	players[1] = my_name  # the host is always peer id 1
	player_list_changed.emit()

	_start_discovery_host()
	return OK


## Broadcasts a "who has this code" request on the LAN and connects to
## whoever replies. Emits code_lookup_failed if nobody answers in time.
func join_by_code(code: String, player_name: String) -> void:
	my_name = player_name
	var expected_reply := "SSMTTM_HOST:%s" % code
	var found_ip: String = await _discover_host(
		("SSMTTM_DISCOVER:%s" % code).to_utf8_buffer(),
		func(reply: String) -> bool: return reply == expected_reply)

	if found_ip == "":
		code_lookup_failed.emit()
		return

	var err := _connect_to_ip(found_ip, player_name)
	if err != OK:
		code_lookup_failed.emit()


## The "Auto Join" button: same broadcast/retry/timeout shape as join_by_code,
## but asks for ANY hostable game on the LAN instead of one specific code, for
## a player who doesn't have a code to type (or can't be bothered to ask).
## Whichever host answers first is the one it connects to - on a home network
## that's normally the only one there is.
func join_auto(player_name: String) -> void:
	my_name = player_name
	var found_ip: String = await _discover_host(
		"SSMTTM_DISCOVER_ANY".to_utf8_buffer(),
		func(reply: String) -> bool: return reply.begins_with("SSMTTM_HOST:"))

	if found_ip == "":
		code_lookup_failed.emit()
		return

	var err := _connect_to_ip(found_ip, player_name)
	if err != OK:
		code_lookup_failed.emit()


## Shared retry loop behind join_by_code and join_auto. Returns the responding
## host's IP, or "" if nobody whose reply satisfies `reply_matches` answered
## within DISCOVERY_TIMEOUT (including if the socket couldn't even be bound).
##
## Re-sent on a short interval because a single UDP broadcast is routinely
## dropped on Wi-Fi, and it goes to each interface's subnet broadcast address
## as well as 255.255.255.255 - Android hotspots and some routers silently
## discard the limited broadcast address.
func _discover_host(request: PackedByteArray, reply_matches: Callable) -> String:
	var udp := PacketPeerUDP.new()
	# Binding explicitly (ephemeral port, all interfaces) guarantees the socket
	# is open and listening before any reply can arrive. Relying on the implicit
	# bind that put_packet() performs is unreliable across platforms.
	var bind_err := udp.bind(0, "*")
	if bind_err != OK:
		push_warning("NetworkManager: could not bind discovery socket (%s)" % bind_err)
		return ""
	udp.set_broadcast_enabled(true)

	var targets := _broadcast_targets()
	var elapsed := 0.0
	var since_send := DISCOVERY_RESEND_INTERVAL  # send immediately on first pass
	var found_ip := ""

	while elapsed < DISCOVERY_TIMEOUT:
		if since_send >= DISCOVERY_RESEND_INTERVAL:
			for target in targets:
				udp.set_dest_address(target, DISCOVERY_PORT)
				udp.put_packet(request)
			since_send = 0.0

		while udp.get_available_packet_count() > 0:
			var raw := udp.get_packet()
			var sender_ip := udp.get_packet_ip()
			if sender_ip != "" and reply_matches.call(raw.get_string_from_utf8()):
				found_ip = sender_ip
				break
		if found_ip != "":
			break

		await get_tree().create_timer(DISCOVERY_POLL_INTERVAL).timeout
		elapsed += DISCOVERY_POLL_INTERVAL
		since_send += DISCOVERY_POLL_INTERVAL

	udp.close()
	return found_ip


## Fallback for networks that block UDP broadcast (many phone hotspots, and
## guest / AP-isolated Wi-Fi). The host reads its IP off the lobby screen.
func join_by_ip(ip_address: String, player_name: String) -> void:
	var err := _connect_to_ip(ip_address.strip_edges(), player_name)
	if err != OK:
		connection_failed.emit()


func leave_game() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	players.clear()
	roles.clear()
	lobby_code = ""
	_stop_discovery_host()


func is_host() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


## Best guess at the address other devices should type in. Prefers a private
## LAN address and skips loopback, link-local and IPv6.
func get_local_ip() -> String:
	var fallback := ""
	for address in IP.get_local_addresses():
		if not _is_usable_ipv4(address):
			continue
		if address.begins_with("192.168.") or address.begins_with("10.") or address.begins_with("172."):
			return address
		if fallback == "":
			fallback = address
	return fallback


## Host-only. Opens a fresh series (one round per player, everyone takes a turn
## as Sili) and starts round 1. Refuses at any size other than MATCH_SIZE -
## use start_practice_match() for short-handed testing.
func start_series() -> void:
	if not is_host() or players.size() != MATCH_SIZE:
		return
	SeriesManager.begin_series(players)
	_launch_round(SeriesManager.current_sili())


## Host-only. Loads the next round of the series with the next player in the
## rotation as Sili. Called by the end-of-match overlay's "Next Round" button.
func start_next_round() -> void:
	if not is_host() or not SeriesManager.is_active:
		return
	if SeriesManager.series_complete():
		return
	_launch_round(SeriesManager.current_sili())


## Host-only. An unranked one-off at any size from 2 up, for testing and for
## letting spectators try the game between sets. Picks the Sili at random
## because there is no rotation to honour outside a series.
func start_practice_match() -> void:
	if not is_host() or players.size() < MIN_PRACTICE_PLAYERS:
		return
	SeriesManager.end_series()
	var peer_ids := players.keys()
	peer_ids.shuffle()
	_launch_round(peer_ids[0])


func _launch_round(sili_id: int) -> void:
	roles.clear()
	for id in players.keys():
		roles[id] = "sili" if id == sili_id else "tubig"

	_stop_discovery_host()  # match is starting, stop advertising the lobby
	# Cleared BEFORE the load command goes out, so a report from the round that
	# just finished cannot be mistaken for a report about the round starting now.
	arena_ready_peers.clear()
	_rpc_assign_roles.rpc(roles)
	_rpc_load_arena.rpc(current_map_id)


## --- Arena load handshake -------------------------------------------------
##
## Called by every peer from arena.gd once its own arena scene is fully built.
## The host holds the round until it has heard from everyone.
##
## This lives on the autoload rather than on the arena for one specific reason:
## change_scene_to_file() is deferred to the end of the frame, so for a frame or
## two after the load command the HOST has no arena node either. An RPC
## addressed to a node that does not exist yet is discarded by Godot with no
## retry - so a client that loaded unusually fast could report in, be silently
## dropped, and then be waited on until the timeout expired. Autoloads exist on
## every peer for the whole session, so there is no window where the report has
## nowhere to land, and a report that arrives before the host's arena is built
## is simply waiting in this dictionary when the arena asks.
func report_arena_ready() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if multiplayer.is_server():
		_record_arena_ready(1)
	else:
		_rpc_arena_ready.rpc_id(1)


@rpc("any_peer", "reliable")
func _rpc_arena_ready() -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	_record_arena_ready(1 if sender == 0 else sender)


func _record_arena_ready(peer_id: int) -> void:
	if arena_ready_peers.has(peer_id):
		return
	arena_ready_peers[peer_id] = true
	arena_peer_ready.emit(peer_id)


## True once every player the host thinks is in the match has checked in.
func all_peers_arena_ready() -> bool:
	for peer_id in players.keys():
		if not arena_ready_peers.has(peer_id):
			return false
	return true


# --- Direct connection (used internally once a code resolves to an IP) ---

func _connect_to_ip(ip_address: String, player_name: String) -> Error:
	my_name = player_name
	if ip_address.is_empty():
		return ERR_INVALID_PARAMETER
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip_address, GAME_PORT)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	return OK


# --- Lobby-code discovery (host side) ---

func _start_discovery_host() -> void:
	lobby_code = "%04d" % (randi() % 10000)
	_discovery_socket = PacketPeerUDP.new()
	var err := _discovery_socket.bind(DISCOVERY_PORT, "*")
	if err != OK:
		# Usually another instance on this machine already owns the port. The
		# lobby is still hostable - clients just have to join by IP instead.
		push_warning("NetworkManager: discovery port %d unavailable (%s)" % [DISCOVERY_PORT, err])
		_discovery_socket = null
		discovery_active = false
		lobby_code_ready.emit(lobby_code)
		discovery_unavailable.emit()
		return
	_is_discovery_host = true
	discovery_active = true
	lobby_code_ready.emit(lobby_code)


func _stop_discovery_host() -> void:
	if _discovery_socket:
		_discovery_socket.close()
		_discovery_socket = null
	_is_discovery_host = false
	discovery_active = false


func _poll_discovery_requests() -> void:
	while _discovery_socket.get_available_packet_count() > 0:
		var raw := _discovery_socket.get_packet()
		var sender_ip := _discovery_socket.get_packet_ip()
		var sender_port := _discovery_socket.get_packet_port()
		var text := raw.get_string_from_utf8()

		# Two request shapes: a specific code (join_by_code) or a wildcard
		# (join_auto's "just find me a game" button) - either way the host
		# answers with the same "SSMTTM_HOST:<code>" reply.
		var matches := false
		if text.begins_with("SSMTTM_DISCOVER:"):
			matches = text.substr("SSMTTM_DISCOVER:".length()).strip_edges() == lobby_code
		elif text == "SSMTTM_DISCOVER_ANY":
			matches = true

		if not matches:
			continue
		if sender_ip == "" or sender_port <= 0:
			continue

		_discovery_socket.set_dest_address(sender_ip, sender_port)
		_discovery_socket.put_packet(("SSMTTM_HOST:%s" % lobby_code).to_utf8_buffer())


## 255.255.255.255 plus a /24 broadcast for each local interface, e.g.
## 192.168.43.255 for a typical Android hotspot.
func _broadcast_targets() -> Array[String]:
	var targets: Array[String] = ["255.255.255.255"]
	for address in IP.get_local_addresses():
		if not _is_usable_ipv4(address):
			continue
		var parts := address.split(".")
		if parts.size() != 4:
			continue
		var subnet_broadcast := "%s.%s.%s.255" % [parts[0], parts[1], parts[2]]
		if not targets.has(subnet_broadcast):
			targets.append(subnet_broadcast)
	return targets


func _is_usable_ipv4(address: String) -> bool:
	if address.contains(":"):
		return false  # IPv6
	if address.begins_with("127.") or address.begins_with("169.254."):
		return false  # loopback / link-local
	return address.split(".").size() == 4


# --- Peer lifecycle (host side) ---

func _on_peer_connected(_id: int) -> void:
	pass  # wait for their register_player() RPC so we know their chosen name


## Fires on EVERY peer, not just the host - Godot notifies all of them when
## someone drops - so the feed line is emitted locally rather than broadcast.
## Routing it through MatchManager.broadcast_event would send one copy per peer
## and print the same departure four times on every screen.
func _on_peer_disconnected(id: int) -> void:
	# Erased first: a peer that dropped mid-load will never report in, and
	# leaving it here would make the others sit out the full load timeout.
	arena_ready_peers.erase(id)

	if not players.has(id):
		return

	var who: String = players[id]
	players.erase(id)
	roles.erase(id)

	if is_host():
		_rpc_update_player_list.rpc(players)
	player_list_changed.emit()

	MatchManager.event_logged.emit("%s left the game" % who, "warning")
	player_left.emit(id, who)


## Whether the host could start another round right now.
##
## The lobby, the end-of-match overlay and start_practice_match() were each
## deciding this for themselves, and the overlay's copy was simply missing -
## it offered "Play Again" no matter how many people had left, then called a
## function that refused and returned silently. The button appeared to do
## nothing, which reads as the game having frozen.
func can_start_another_round() -> bool:
	if not is_host():
		return false
	if SeriesManager.is_active and not SeriesManager.series_complete():
		# A series is balanced for a full lobby; losing anyone ends it rather
		# than quietly playing the remaining rounds at the wrong size.
		return players.size() == MATCH_SIZE
	return players.size() >= MIN_PRACTICE_PLAYERS


## Why can_start_another_round() said no, phrased for a player. Empty when it
## said yes.
func round_blocked_reason() -> String:
	if not is_host():
		return ""
	if SeriesManager.is_active and not SeriesManager.series_complete():
		if players.size() != MATCH_SIZE:
			return "Series needs %d players - %d left." % [MATCH_SIZE, players.size()]
		return ""
	if players.size() < MIN_PRACTICE_PLAYERS:
		return "Not enough players to start another round."
	return ""


# --- Peer lifecycle (client side) ---

func _on_connected_to_server() -> void:
	var my_id := multiplayer.get_unique_id()
	_rpc_register_player.rpc_id(1, my_id, my_name)


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	connection_failed.emit()


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	players.clear()
	roles.clear()
	server_disconnected.emit()


# --- RPCs ---

@rpc("any_peer", "reliable")
func _rpc_register_player(id: int, player_name: String) -> void:
	if not is_host():
		return
	players[id] = player_name
	_rpc_update_player_list.rpc(players)


@rpc("authority", "call_local", "reliable")
func _rpc_update_player_list(new_players: Dictionary) -> void:
	players = new_players
	player_list_changed.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_assign_roles(new_roles: Dictionary) -> void:
	roles = new_roles
	roles_assigned.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_load_arena(map_id: String) -> void:
	current_map_id = map_id
	match_starting.emit()
	# Behind the curtain rather than a bare change_scene_to_file: the arena
	# plus its map is a second or more of blocking work, and doing it raw left
	# the lobby frozen on screen looking like a crash. The map is named as a
	# preload so it comes off the worker thread here instead of blocking inside
	# arena.gd's _load_map(), which runs during _ready() where nothing can
	# yield. Deliberately not awaited - change_scene drives itself.
	LoadingScreen.change_scene(ARENA_SCENE, [MapRegistry.scene_path(map_id)])
