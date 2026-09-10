extends Node

## Covers LAN discovery - the machinery behind Auto Join and the 4-digit code.
##
## This had no coverage at all, which is uncomfortable for the one feature whose
## whole job is to work on somebody else's Wi-Fi at a competition. What can be
## tested here is the PROTOCOL: that a host answers a wildcard request, answers
## its own code, and stays silent for anybody else's. What cannot be tested here
## is whether a given router actually forwards a broadcast - so _discover_host's
## real send path is deliberately not exercised, and packets are aimed straight
## at 127.0.0.1 instead. The host socket binds "*", so loopback reaches it.
##
## Worth knowing while reading this: _broadcast_targets() filters loopback OUT
## (see _is_usable_ipv4), so the real client never sends to 127.0.0.1 - which is
## exactly why this test talks to the socket directly rather than calling
## join_auto() and hoping the LAN cooperates.
##
## Run as a SCENE, for the autoloads:
##
##     godot --headless --path . res://tools/test_discovery.tscn

## Deliberately not NetworkManager.DISCOVERY_PORT + something clever: this is
## the real port, because binding the real one is part of what is being tested.
const HOST := "127.0.0.1"

var _f := 0
var _frame := 0
var _phase := 0
var _settle := 0
var _client: PacketPeerUDP = null
var _skipped := false


func _c(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		print("  PASS  %s" % label)
	else:
		_f += 1
		print("  FAIL  %s  (got %s, expected %s)" % [label, actual, expected])


func _ready() -> void:
	print("LAN discovery / Auto Join tests")

	NetworkManager._start_discovery_host()

	if not NetworkManager.discovery_active:
		# Another copy of the game (or a previous run that has not let go of the
		# port yet) already owns 7778. That is a legitimate runtime state with
		# its own handled path - the lobby still works, join-by-IP still works -
		# so it is reported rather than failed, and the code assertion below
		# still holds because _start_discovery_host sets it either way.
		print("  SKIP  discovery port %d is busy - protocol assertions skipped"
			% NetworkManager.DISCOVERY_PORT)
		_c("a busy port still yields a lobby code", NetworkManager.lobby_code.length(), 4)
		_c("and reports itself unavailable rather than pretending",
			NetworkManager.discovery_active, false)
		_skipped = true
		return

	_c("host is advertising", NetworkManager.discovery_active, true)
	_c("lobby code is four digits", NetworkManager.lobby_code.length(), 4)
	_c("lobby code is numeric", NetworkManager.lobby_code.is_valid_int(), true)

	_client = PacketPeerUDP.new()
	var err := _client.bind(0, "*")
	if err != OK:
		print("  FAIL  could not bind a client socket (error %d)" % err)
		_finish()
		return
	_client.set_dest_address(HOST, NetworkManager.DISCOVERY_PORT)


func _send(text: String) -> void:
	_client.put_packet(text.to_utf8_buffer())
	_settle = 6  # a few frames for NetworkManager._process to poll and answer


## Whatever the host said back, or "" if it said nothing.
func _reply() -> String:
	var last := ""
	while _client.get_available_packet_count() > 0:
		last = _client.get_packet().get_string_from_utf8()
	return last


func _process(_delta: float) -> void:
	if _skipped:
		_finish()
		return
	if _client == null:
		return
	_frame += 1
	if _frame < 3:
		return
	if _settle > 0:
		_settle -= 1
		return

	match _phase:
		0:
			# --- Auto Join ---
			# The wildcard request. This is the whole Auto Join feature: a player
			# with no code asks whether anyone at all is hosting.
			_send("SSMTTM_DISCOVER_ANY")
			_phase = 1

		1:
			_c("Auto Join gets an answer",
				_reply(), "SSMTTM_HOST:%s" % NetworkManager.lobby_code)
			# --- Join by code ---
			_send("SSMTTM_DISCOVER:%s" % NetworkManager.lobby_code)
			_phase = 2

		2:
			_c("the right code gets an answer",
				_reply(), "SSMTTM_HOST:%s" % NetworkManager.lobby_code)
			# --- Somebody else's code ---
			# Two lobbies on one network is the case this protects: answering a
			# code that is not yours drops a player into the wrong game.
			var wrong := "%04d" % ((NetworkManager.lobby_code.to_int() + 1) % 10000)
			_send("SSMTTM_DISCOVER:%s" % wrong)
			_phase = 3

		3:
			_c("a different lobby's code is ignored", _reply(), "")
			# Whitespace is what a hand-typed code arrives with; the host strips
			# it before comparing, and a regression there would break exactly the
			# people who typed carefully.
			_send("SSMTTM_DISCOVER:  %s  " % NetworkManager.lobby_code)
			_phase = 4

		4:
			_c("a padded code still matches",
				_reply(), "SSMTTM_HOST:%s" % NetworkManager.lobby_code)
			_send("GARBAGE_FROM_SOMETHING_ELSE")
			_phase = 5

		5:
			_c("unrelated traffic on the port is ignored", _reply(), "")
			# --- Teardown ---
			NetworkManager._stop_discovery_host()
			_c("stopping clears the advertising flag",
				NetworkManager.discovery_active, false)
			_finish()


func _finish() -> void:
	if _client:
		_client.close()
	if NetworkManager.discovery_active:
		NetworkManager._stop_discovery_host()
	print("")
	print("ALL TESTS PASSED" if _f == 0 else "%d TEST(S) FAILED" % _f)
	get_tree().quit(1 if _f > 0 else 0)
