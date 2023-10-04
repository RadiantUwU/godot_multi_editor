extends "res://addons/live_editing/NetworkAPI.gd"

var allow_decoding_objects:=false
var _pck_info:={}
func create_packet_type(packet_name: StringName,type:int = TYPE_NIL)->void:
	if packet_name in _pck_info:
		return
	_pck_info[packet_name]=type
	var _data = {"name":"data"}
	if type != TYPE_NIL:
		_data["type"]=type
	add_user_signal("packet_"+str(packet_name),[
		{"name":"peer","type":TYPE_OBJECT},
		_data
	])
	
func unregister_packet_type(packet_name: StringName)->void:
	_pck_info.erase(packet_name)

func register_packet_handler(packet_name: StringName, handle: Callable)->void:
	connect("packet_"+str(packet_name),handle)

func unregister_packet_handler(packet_name: StringName, handle: Callable)->void:
	disconnect("packet_"+str(packet_name),handle)

func send_packet_type(peer: PacketPeerUDP, packet_name: StringName, data, transfer_mode:=MultiplayerPeer.TRANSFER_MODE_RELIABLE)->void:
	var packet := PackedByteArray()
	if typeof(data) == TYPE_DICTIONARY:
		data = data.duplicate()
		data["__packet__"]=packet_name
	else:
		var d := {}
		d["data"]=data
		data = d
	if allow_decoding_objects:
		packet = var_to_bytes_with_objects(data)
	else:
		packet = var_to_bytes(data)
	send_packet(peer,data,transfer_mode)

func _init():
	super._init()
	incoming_packet.connect(_on_incoming_packet)

func _on_incoming_packet(peer: PacketPeerUDP,data: PackedByteArray):
	var dict:Dictionary = data.decode_var(0,allow_decoding_objects)
	if "__packet__" in dict:
		var packet_name:String = dict["__packet__"]
		if packet_name in _pck_info:
			if _pck_info[packet_name] == TYPE_DICTIONARY:
				dict.erase("__packet__")
				emit_signal("packet_"+str(packet_name),dict)
			else:
				emit_signal("packet_"+str(packet_name),dict["data"])
