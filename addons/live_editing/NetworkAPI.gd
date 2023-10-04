extends RefCounted

# PACKET HEADERS - size 8
#
# byte 0: send_mode
# byte 1-4: sequence_no
# byte 5: control
# byte 6-7: reserved


const STATE_DISCONNECTED=0
const STATE_CONNECTING=1
const STATE_CONNECTED=2

const _CONTROL_DATA=0b0
const _CONTROL_DISCONNECT=0b1
const _CONTROL_ACKNOWLEDGE=0b10
const _CONTROL_DC_ACK=0b11
const _CONTROL_REQUEST_AGAIN=0b100
const _CONTROL_KEEP_ALIVE=0b1000

var TIMEOUT_PERIOD:=5000
var RESEND_PERIOD:=1000

static func _has_flag(i: int,f: int)->bool:
	return i & f == f

var state:=0:
	get:
		if state == 1:
			return 1
		if is_server:
			return 2 if udp_server.is_listening() else 0
		else:
			return 2 if udp_client.is_socket_connected() else 0
var is_server:=false

var upnp:=UPNP.new()
var udp_server:=UDPServer.new()
var connections:={}
var disconnecting:=-1
var last_h: int

var udp_client:=PacketPeerUDP.new()
var client_data:={
	"sequence_no_reliable": 0,
	"sequence_no_unreliable_ordered": 0,
	"sequence_no_reliable_recv": 0,
	"sequence_no_unreliable_ordered_recv": 0,
	"pending_packets_reliable_timeout": {},
	"pending_packets_reliable_timeout2": {},
	"pending_packets_reliable": {},
	"pending_packets_reliable_recv": {},
}

signal discovery_complete(err: int)

signal new_connection(udp:PacketPeerUDP)
signal error_connection_removed(udp: PacketPeerUDP, reason: String)
signal connection_removed(udp:PacketPeerUDP, msg: String)
signal server_opened
signal server_closed

signal connected_to_server
signal error_disconnnected_from_server(err: String)
signal disconnected_from_server(msg: String)

signal incoming_packet(peer, packet: PackedByteArray)

func _discover():
	emit_signal.call_deferred(&"discovery_complete",upnp.discover())

func _notification(what):
	if self == null: return
	if what == NOTIFICATION_PREDELETE:
		if state == 2:
			print("Shutting down udp server...")
			disconnect_network()
			Engine.get_main_loop().process_frame.disconnect(_process)
			print("done.")

func _init():
	Engine.get_main_loop().process_frame.connect(_process)

func _send_control_packet(peer: PacketPeerUDP,control: int,data:=PackedByteArray())->void:
	var connection_data:Dictionary=connections[peer]
	var header := PackedByteArray()
	var sequence_no: int = connection_data["sequence_no_reliable"]
	header.resize(8)
	header[0]=MultiplayerPeer.TRANSFER_MODE_RELIABLE
	header.encode_u32(1,sequence_no)
	header[5]=control
	connection_data["pending_packets_reliable"][sequence_no] = header
	connection_data["pending_packets_reliable_timeout"][sequence_no] = Time.get_ticks_msec()
	connection_data["sequence_no_reliable"] = sequence_no+1
	header.append_array(data)
	peer.put_packet(header)

func _send_ack_packet(peer: PacketPeerUDP,sequence_no: int)->void:
	var connection_data:Dictionary=connections[peer]
	var header := PackedByteArray()
	header.resize(8)
	header[0]=MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	header.encode_u32(1,sequence_no)
	header[5]=_CONTROL_ACKNOWLEDGE
	peer.put_packet(header)

func send_keep_alive(peer: PacketPeerUDP = null)->void:
	if state != 2:
		push_error("NetworkAPI not connected")
		return
	if is_server:
		if peer == null:
			for peer_ in connections.keys():
				send_keep_alive(peer_)
			return
	else:
		peer = udp_client
	var header :=PackedByteArray()
	header.resize(8)
	header[0] = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	header[5] = _CONTROL_KEEP_ALIVE
	peer.put_packet(header)

func send_packet(peer: PacketPeer,data: PackedByteArray,transfer_mode:int=MultiplayerPeer.TRANSFER_MODE_RELIABLE)->void:
	if state != 2:
		push_error("NetworkAPI not connected")
		return
	var sequence_no: int
	var connection_data: Dictionary
	if is_server:
		if peer == null:
			for peer_ in connections.keys():
				send_packet(peer_,data,transfer_mode)
			return
		connection_data = connections[peer]
	else:
		peer = udp_client
		connection_data = client_data
	var packet := PackedByteArray()
	packet.resize(8)
	packet.append_array(data)
	packet[0] = transfer_mode
	packet[5] = 0
	match transfer_mode:
		MultiplayerPeer.TRANSFER_MODE_RELIABLE:
			sequence_no = connection_data["sequence_no_reliable"]
			packet.encode_u32(1,sequence_no)
			connection_data["pending_packets_reliable"][sequence_no] = packet
			connection_data["pending_packets_reliable_timeout"][sequence_no] = Time.get_ticks_msec()
			connection_data["pending_packets_reliable_timeout2"][sequence_no] = 0
			connection_data["sequence_no_reliable"] = sequence_no+1
			peer.put_packet(packet)
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED:
			sequence_no = connection_data["sequence_no_unreliable_ordered"]
			packet.encode_u32(1,sequence_no)
			connection_data["sequence_no_unreliable_ordered"] = sequence_no+1
			peer.put_packet(packet)
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE:
			peer.put_packet(packet)

func _resend_packet(peer: PacketPeer, sequence_no: int)->void:
	var packet_buf:Dictionary = connections[peer]["pending_packets_reliable"]
	if sequence_no in packet_buf:
		peer.put_packet(packet_buf[sequence_no])
	else:
		push_error("Peer %s desynced." % last_h)
		_send_control_packet(peer,_CONTROL_DISCONNECT | _CONTROL_REQUEST_AGAIN)

func _emit_incoming_packet(peer: PacketPeerUDP, data: PackedByteArray)->void:
	if peer == udp_client:
		peer = null
	incoming_packet.emit(peer,data)

func _incoming_packet(peer: PacketPeerUDP, packet: PackedByteArray)->void:
	var header := packet.slice(0,7)
	var data := packet.slice(8)
	var send_mode:=header.decode_u8(0)
	var sequence_no:=header.decode_u32(1)
	var control:=header.decode_u8(5)
	var connection_data: Dictionary
	if is_server:
		connection_data = connections[peer]
	else:
		connection_data = client_data
	if control == _CONTROL_KEEP_ALIVE:
		return
	elif control == _CONTROL_DATA:
		match send_mode:
			MultiplayerPeer.TRANSFER_MODE_RELIABLE:
				var curr_sequence_no: int = connection_data["sequence_no_reliable_recv"]
				var pending_recv: Dictionary = connection_data["pending_packets_reliable_recv"]
				# Send an ACK packet immediately.
				_send_ack_packet(peer,curr_sequence_no)
				if len(pending_recv) == 0: # no pending
					if curr_sequence_no == sequence_no:
						connection_data["sequence_no_reliable_recv"] = sequence_no+1
						_emit_incoming_packet(peer,data)
					elif curr_sequence_no > sequence_no:
						# huh?
						push_warning("Possible failed ack packet? Received packet #%s, but it was already received, currently waiting #%s" % [sequence_no,curr_sequence_no])
					else:
						pending_recv[sequence_no] = data
				else:
					pending_recv[sequence_no] = data
					#attempt resync
					if curr_sequence_no == sequence_no:
						while true:
							_emit_incoming_packet(peer,data)
							curr_sequence_no += 1
							connection_data["sequence_no_reliable_recv"] = curr_sequence_no
							if pending_recv.has(curr_sequence_no):
								data = pending_recv[curr_sequence_no]
							else:
								return
			MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED:
				var curr_sequence_no: int = connection_data["sequence_no_unreliable_ordered_recv"]
				if curr_sequence_no <= sequence_no:
					connection_data["sequence_no_unreliable_ordered_recv"] = sequence_no+1
					_emit_incoming_packet(peer,data)
			MultiplayerPeer.TRANSFER_MODE_UNRELIABLE:
				_emit_incoming_packet(peer,data)
	elif _has_flag(control,_CONTROL_DC_ACK):
		# purge it from the connections table
		if is_server:
			peer.close()
			connections.erase(peer)
			connection_removed.emit(peer)
		else:
			udp_client.close()
			disconnected_from_server.emit(data.get_string_from_utf8())
	elif _has_flag(control,_CONTROL_DISCONNECT | _CONTROL_REQUEST_AGAIN):
		if is_server:
			_send_control_packet(peer,_CONTROL_DC_ACK)
			peer.close()
			connections.erase(peer)
			push_error("Peer %s desynced." % last_h)
			error_connection_removed.emit(peer,"desync")
			connection_removed.emit(peer,"desync")
		else:
			_send_control_packet(udp_client,_CONTROL_DC_ACK)
			udp_client.close()
			push_error("Server desynced.")
			error_disconnnected_from_server.emit("desync")
			disconnected_from_server.emit("desync")
	else:
		if _has_flag(control,_CONTROL_DISCONNECT):
			if is_server:
				_send_control_packet(peer,_CONTROL_DC_ACK)
				peer.close()
				connections.erase(peer)
				connection_removed.emit(peer)
			else:
				_send_control_packet(udp_client,_CONTROL_DC_ACK)
				udp_client.close()
				disconnected_from_server.emit()
		if _has_flag(control,_CONTROL_ACKNOWLEDGE):
			if is_server:
				connections[peer]["pending_packets_reliable"].erase(sequence_no)
				connections[peer]["pending_packets_reliable_timeout"].erase(sequence_no)
			else:
				client_data["pending_packets_reliable"].erase(sequence_no)
				client_data["pending_packets_reliable_timeout"].erase(sequence_no)
		if _has_flag(control,_CONTROL_REQUEST_AGAIN):
			if is_server:
				_resend_packet(peer,sequence_no)
			else:
				_resend_packet(udp_client,sequence_no)

func _process():
	#handle packets incoming and connections
	if is_server:
		if udp_server.is_connection_available():
			var packet_peer:=udp_server.take_connection()
			if packet_peer:
				connections[packet_peer]={
					"sequence_no_reliable": 0,
					"sequence_no_unreliable_ordered": 0,
					"sequence_no_reliable_recv": 0,
					"sequence_no_unreliable_ordered_recv": 0,
					"pending_packets_reliable_timeout": {},
					"last_received_packet": -1,
					"pending_packets_reliable": {},
					"pending_packets_reliable_recv": {},
				}
				new_connection.emit(packet_peer)
		for peer in connections.keys():
			var h := 0
			while peer.get_available_packet_count() > 0:
				if h == 0:
					h = hash([peer.get_packet_ip(),peer.get_packet_port()])
					last_h = h
				_incoming_packet(peer,peer.get_packet())
	else:
		if udp_client.get_available_packet_count() > 0:
			_incoming_packet(udp_client,udp_client.get_packet())
	#handle timeouts
	if is_server:
		for peer in connections.keys():
			var connection_data:Dictionary=connections[peer]
			var packets:Dictionary=connection_data["pending_packets_reliable"]
			var pending:Dictionary=connection_data["pending_packets_reliable_timeout"]
			var resends:Dictionary=connection_data["pending_packets_reliable_timeout2"]
			for sequence_no in pending.keys():
				var time:int=Time.get_ticks_msec()-pending[sequence_no]
				var resend_attempts:int=resends[sequence_no]
				if time >= TIMEOUT_PERIOD && !connection_data.get("is_disconnecting",false):
					disconnect_peer(peer,"timed out")
					connection_data["is_disconnecting"] = true
				elif time >= 2*TIMEOUT_PERIOD && connection_data["is_disconnecting"]:
					disconnect_peer(peer,"timed out",true)
				elif time >= RESEND_PERIOD*(1+(resend_attempts)):
					peer.put_packet(packets[sequence_no])
					resends[sequence_no] = resend_attempts + 1
	else:
		if udp_client.get_available_packet_count() > 0:
			_incoming_packet(udp_client,udp_client.get_packet())

func create_server(port:=8484)->Error:
	if state == STATE_CONNECTED:
		push_error("Cannot start a new server: not disconnected")
		return FAILED
	udp_server = UDPServer.new()
	is_server = true
	state = 1
	print("Starting server on port %s! " % port)
	var err := udp_server.listen(port)
	if err != OK:
		state = 0
		return err
	WorkerThreadPool.add_task(_discover,true,"UPNP discover")
	err = await discovery_complete
	if err != UPNP.UPNP_RESULT_SUCCESS:
		state = 0
		return err
	err = upnp.add_port_mapping(port,0,"Godot Live-Edit session","UDP",86400)
	if err != UPNP.UPNP_RESULT_SUCCESS:
		state = 0
		return err
	print("Started!")
	state = 2
	server_opened.emit()
	return OK

func connect_to_server(address:String,port:=8484)->Error:
	if state != STATE_DISCONNECTED:
		push_error("Cannot start a new client: not disconnected")
		return FAILED
	udp_client = PacketPeerUDP.new()
	is_server = false
	state = 1
	print("Connecting!")
	var err := udp_client.connect_to_host(address,port)
	if err != OK:
		state = 0
		return err
	state = 2
	print("Connected!")
	client_data = {
		"sequence_no_reliable": 0,
		"sequence_no_unreliable_ordered": 0,
		"sequence_no_reliable_recv": 0,
		"sequence_no_unreliable_ordered_recv": 0,
		"pending_packets_reliable_timeout": {},
		"pending_packets_reliable": {},
		"pending_packets_reliable_recv": {},
	}
	connected_to_server.emit()
	return OK

func disconnect_network(force:=false)->Error:
	if state != STATE_CONNECTED:
		push_error("Failed disconnect: state is not connected")
		return FAILED
	if force:
		if is_server:
			for peer in connections:
				_send_control_packet(peer,_CONTROL_DISCONNECT, "Server closed connection (forcefully)".to_utf8_buffer())
				peer.close()
			udp_server.stop()
			connections.clear()
			server_closed.emit()
		else:
			_send_control_packet(udp_client,_CONTROL_DISCONNECT, "Server closed connection (forcefully)".to_utf8_buffer())
			udp_client.close()
			disconnected_from_server.emit("Disconnected by client")
		return OK
	else:
		if is_server:
			disconnecting = Time.get_ticks_msec()
			for peer in connections:
				_send_control_packet(peer,_CONTROL_DISCONNECT, "Server closed connection".to_utf8_buffer())
			while len(connections) > 0 and Time.get_ticks_msec() - disconnecting < TIMEOUT_PERIOD:
				OS.delay_msec(1/60)
				_process()
			udp_server.stop()
			connections.clear()
			server_closed.emit()
		else:
			_send_control_packet(udp_client,_CONTROL_DISCONNECT, "Server closed connection".to_utf8_buffer())
			while state == 2 and Time.get_ticks_msec() - disconnecting < TIMEOUT_PERIOD:
				OS.delay_msec(1/60)
				_process()
		return OK

func disconnect_peer(peer: PacketPeerUDP, message: String="",force:=false)->Error:
	if state != STATE_CONNECTED:
		push_error("Failed disconnect: state is not connected")
		return FAILED
	if is_server:
		if peer == null:
			for peer_ in connections.keys():
				disconnect_peer(peer_,message,force)
			return OK
	else:
		peer = udp_client
	if force:
		_send_control_packet(peer,_CONTROL_DISCONNECT,message.to_utf8_buffer())
		peer.close()
	else:
		_send_control_packet(peer,_CONTROL_DISCONNECT,message.to_utf8_buffer())
	return OK
