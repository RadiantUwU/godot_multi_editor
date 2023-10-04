@tool
extends EditorPlugin

const NetworkAPI := preload("res://addons/live_editing/ExtendedNetworkAPI.gd")
const PasswordRequiredPopUp:= preload("res://addons/live_editing/scenes/password_required.tscn")
const LoadingPopup:=preload("res://addons/live_editing/scenes/connecting.tscn")

var currently_selected_object: Object

var networking := NetworkAPI.new()
var trust_mode := false
var server_trust_mode := false

var menu:Control
var password_required_popup:Window=null
var loading_bar:Window
var asset_size:=0
var asset_current_size:=0

var connections:={}

const CONNECTION_STATE_WAITING_PASSWORD:=0
const CONNECTION_STATE_WAITING_INIT:=1
const CONNECTION_STATE_AWAIT_INSTANCES_TRUSTED:=4
const CONNECTION_STATE_AWAIT_INSTANCES_UNTRUSTED:=5
const CONNECTION_STATE_ESTABLISHED_TRUSTED:=2
const CONNECTION_STATE_ESTABLISHED_UNTRUSTED:=3

var instance_ids:={
	null: -1
}          # Object   -> ObjectID
var instance_ids_reversed:={
	-1: null
}          # ObjectID -> Object
var scenes:={}

var last_connected_ip:=""
var last_connected_port:=8989
var trusted_IPs:=[]
var passw_salt:PackedByteArray
var password:=""
var nickname:=""

var keep_alive_counter:=0.0

var packet_buffer:Array[Dictionary]=[]
var packets_paused:=0
const pausable_packets:Array[StringName]=[
	&"set_property",
	&"new_object",
	&"load_object",
	&"unload_object",
	&"unload_scene",
	&"load_scene"
]

func _cache_packet(peer: PacketPeerUDP,data: PackedByteArray)->void:
	var decoded= bytes_to_var(data)
	if pausable_packets in decoded["__packet__"]:
		packet_buffer.append({"peer":peer,"data":data})
func _pause_packets()->void:
	packets_paused += 1
	if packets_paused == 1:
		networking.incoming_packet.connect(_cache_packet)
func _resume_packets()->void:
	packets_paused -= 1
	if packets_paused == 0:
		networking.incoming_packet.disconnect(_cache_packet)
		for i in packet_buffer:
			networking._on_incoming_packet(i["peer"],i["data"])

func _process(delta):
	if networking.state == networking.STATE_CONNECTED:
		keep_alive_counter+=delta
		while keep_alive_counter > 1.0:
			networking.send_keep_alive()
			keep_alive_counter -= 1.0

static func _has_flag(i:int,f:int)->bool:
	return i&f==f

var conf:=ConfigFile.new()
var _broadcast_recursion:Array[Object]=[]
func _broadcast_object_properties(peer: PacketPeerUDP, obj: Object, oid: int)->void:
	var obj_details:={"oid":oid}
	for property in obj.get_property_list():
		if _has_flag(property["usage"],PROPERTY_USAGE_STORAGE):
			obj_details[property["name"]]=obj.get(property["name"])
	networking.send_packet_type(peer,&"load_object",obj_details)
func _broadcast_object(peer:PacketPeerUDP,obj: Object,force:=false)->int:
	if obj == null:
		return -1
	var oid: int = instance_ids.get(obj,-2)
	if oid != -2 && !force:
		return oid
	elif oid == -2:
		oid = randi()
		instance_ids[obj]=oid
		instance_ids_reversed[obj]=oid
	_broadcast_recursion.append(obj)
	var obj_details:={}
	obj_details["class"]=obj.get_class()
	if obj.get_script() != null and obj.get_script() != "":
		var script = obj.get_script()
		if script is Script:
			if script.resource_path != "":
				obj_details["script"]=script.resource_path
		else:
			obj_details["script"]=script
	obj_details["oid"]=oid
	networking.send_packet_type(peer,&"new_object",obj_details)
	_broadcast_object_properties.call_deferred(peer,obj,oid)
	if obj is Node:
		_broadcast_object(peer,obj,force)
		for i in obj.get_children(true):
			_broadcast_object(peer,i,force)
	for prop in obj.get_property_list():
		if _has_flag(prop["usage"],PROPERTY_USAGE_STORAGE):
			var v:=obj.get(prop["name"])
			if v is Object:
				if v in _broadcast_recursion: continue
				_broadcast_object(peer,v,force)
	_broadcast_recursion.pop_back()
	return oid
func _erase_object(peer:PacketPeerUDP, obj)->void:
	if typeof(obj) == TYPE_INT:
		networking.send_packet_type(peer,&"unload_object",obj)
		var o: Object = instance_ids_reversed.get(obj,null)
		if is_instance_valid(o):
			if o is Node:
				for i in o.get_children():
					_erase_object(peer,i)
				o.queue_free()
			instance_ids.erase(o)
			instance_ids_reversed.erase(obj)
	else:
		var o: int = instance_ids.get(obj,-2)
		if is_instance_valid(obj):
			networking.send_packet_type(peer,&"unload_object",o)
			if obj is Node:
				for i in obj.get_children():
					_erase_object(peer,i)
				obj.queue_free()
			instance_ids.erase(obj)
			instance_ids_reversed.erase(o)

func _get_plugin_name():
	return "Godot Co-Op"
func _has_main_screen()->bool:
	return true
func _make_visible(visible):
	menu.visible = visible

func _save_config()->void:
	conf.set_value("Connections","last_connected_ip",last_connected_ip)
	conf.set_value("Connections","last_connected_port",last_connected_port)
	conf.set_value("Trusted Data","trusted_ips",trusted_IPs)
	conf.set_value("Trusted Data","password",password)
	conf.set_value("Trusted Data","server_trust_mode",server_trust_mode)
	conf.set_value("Connections","connected",networking.state == networking.STATE_CONNECTED)
	conf.set_value("Connections","hosting",networking.is_server)
	conf.set_value("Preferences","nickname",nickname)
	var err := conf.save("res://addons/live_editing/config.ini")

func _load_config()->void:
	var err := conf.load("res://addons/live_editing/config.ini")
	if err != OK:
		printerr("Error occured while loading res://addons/live_editing/config.ini ",error_string(err))
	else:
		last_connected_ip = conf.get_value("Connections","last_connected_ip","")
		last_connected_port = conf.get_value("Connections","last_connected_port",8989)
		trusted_IPs = conf.get_value("Trusted Data","trusted_ips",[])
		server_trust_mode = conf.get_value("Trusted Data","server_trust_mode",false)
		nickname = conf.get_value("Preferences","nickname","User")
		if conf.get_value("Connections","connected",false):
			if conf.get_value("Connections","hosting",false):
				err = await networking.create_server(8989)
			else:
				err = networking.connect_to_server(last_connected_ip,last_connected_port)
			if err != OK:
				trust_mode = false
				printerr("Error occured while trying to connect: ",error_string(err))

func _init_networking()->void:
	networking.connected_to_server.connect(_connected_to_server)
	networking.new_connection.connect(_client_joined)
	networking.connection_removed.connect(_client_left)
	networking.server_opened.connect(_server_init)
	networking.server_closed.connect(_server_init)
	
	networking.create_packet_type(&"initialize",TYPE_DICTIONARY)
	networking.create_packet_type(&"request_password",TYPE_PACKED_BYTE_ARRAY)
	networking.create_packet_type(&"handshake_complete",TYPE_DICTIONARY)
	networking.create_packet_type(&"load_files",TYPE_PACKED_BYTE_ARRAY)
	networking.create_packet_type(&"load_main_assets",TYPE_PACKED_BYTE_ARRAY)
	
	networking.create_packet_type(&"load_scene",TYPE_DICTIONARY)
	networking.create_packet_type(&"unload_scene",TYPE_DICTIONARY)
	networking.create_packet_type(&"new_object",TYPE_DICTIONARY)
	networking.create_packet_type(&"load_object",TYPE_DICTIONARY)
	networking.create_packet_type(&"set_property",TYPE_DICTIONARY)
	networking.create_packet_type(&"unload_object",TYPE_INT)
	
	networking.register_packet_handler(&"initialize",_init_packet)
	networking.register_packet_handler(&"request_password",_request_password)
	networking.register_packet_handler(&"handshake_complete",_handshake_complete)
	networking.register_packet_handler(&"load_main_assets",_recv_main_file)
	networking.register_packet_handler(&"load_scene",_load_scene)

func _enter_tree():
	# Initialization of the plugin goes here.
	menu = preload("res://addons/live_editing/scenes/menu.tscn").instantiate()
	menu.visible = false
	get_editor_interface().get_editor_main_screen().add_child(menu)
	_init_networking()
	
	if FileAccess.file_exists("res://addons/live_editing/config.ini"):
		_load_config()
	else:
		_save_config()

static func _recursive_get_file_paths(current_path:String,file_paths:Array[String])->void:
	for file in DirAccess.get_files_at(current_path):
		file_paths.append(current_path+file)
	for dir in DirAccess.get_directories_at(current_path):
		_recursive_get_file_paths(current_path+dir,file_paths)

static func _no_addon_folder(e: String)->bool:
	return !e.begins_with("res://addons") and e.begins_with("res://")

func _prepare_data():
	_pause_packets()
	for scene_path in scenes.keys():
		var scene_node:Node=instance_ids[scenes[scene_path]]
		var scene:=PackedScene.new()
		#scene.resource_path = scene_path
		var err := scene.pack(scene_node)
		if err != OK:
			printerr("Error while packing scene: ",error_string(err))
		else:
			err = ResourceSaver.save(scene,scene_path,ResourceSaver.FLAG_CHANGE_PATH)
			if err != OK:
				printerr("Error while saving scene: ",error_string(err))
	var pck:=ZIPPacker.new()
	var err := pck.open("res://addons/live_editing/coop_session.zip")
	if err:
		push_error(error_string(err))
		printerr("FATAL ERROR [coop]\nError occured during _prepare_data, failed to create a zip packer instance.\nError detail: ",error_string(err))
		networking.disconnect_network(true)
		return
	var file_paths:Array[String]=[]
	_recursive_get_file_paths("res://",file_paths)
	file_paths = file_paths.filter(_no_addon_folder)
	for file in file_paths:
		var fstream:=FileAccess.open(file,FileAccess.READ)
		if fstream:
			pck.start_file(file)
			pck.write_file(fstream.get_buffer(fstream.get_length()))
			pck.close_file()
		else:
			printerr("Error occured while reading from ",file,": ",error_string(FileAccess.get_open_error()))
	pck.close()

func _init_packet(peer: PacketPeerUDP, data: Dictionary)->void:
	if networking.is_server: #server
		if connections[peer]["state"] != CONNECTION_STATE_WAITING_INIT:
			_disconnect(peer,"You confused the server. Congratulations.",true)
			return
		else:
			connections[peer]["nickname"]=data["nickname"]
			connections[peer]["state"] = CONNECTION_STATE_AWAIT_INSTANCES_TRUSTED if data["trusted"] and server_trust_mode else CONNECTION_STATE_AWAIT_INSTANCES_UNTRUSTED
			_prepare_data()
			var fstream := FileAccess.open("res://addons/live_editing/coop_session.zip",FileAccess.READ)
			if fstream:
				networking.send_packet_type(peer,&"handshake_complete",{
					"size":fstream.get_length()
				})
				for i in range(fstream.get_length() / 4096):
					var a :=PackedByteArray()
					a.resize(4)
					a.encode_u32(0,i)
					a.append_array(fstream.get_buffer(4096))
					networking.send_packet_type(peer,&"load_main_assets",a)
					if i % 71 ==70: await get_tree().process_frame
				var a :=PackedByteArray()
				a.resize(4)
				a.encode_u32(0,2**32-1)
				a.append_array(fstream.get_buffer(4096))
				networking.send_packet_type(peer,&"load_main_assets",a)
	else:
		var trusting:bool=data["trusted"]
		networking.allow_decoding_objects = last_connected_ip in trusted_IPs and trusting
		networking.send_packet_type(null,&"initialize",{
			"trusted": networking.allow_decoding_objects,
			"nickname": nickname
		})
func _request_password(peer: PacketPeerUDP, data: PackedByteArray)->void:
	if networking.is_server:
		if connections[peer]["state"] != CONNECTION_STATE_WAITING_PASSWORD:
			_disconnect(peer,"You confused the server. Congratulations.",true)
			return
		var password_salt :PackedByteArray= connections["password_salt"]
		var hc := HashingContext.new()
		hc.start(HashingContext.HASH_SHA256)
		hc.update(password.to_utf8_buffer())
		hc.update(password_salt)
		if hc.finish() == data:
			connections[peer]["state"]=CONNECTION_STATE_WAITING_INIT
			networking.send_packet_type(null,&"initialize",{
				"trusted":server_trust_mode
			})
		else:
			var c:=Crypto.new()
			connections[peer]["password_salt"]=c.generate_random_bytes(256)
			networking.send_packet_type(peer,&"request_password",connections[peer]["password_salt"])
	else:
		if password == "":
			if password_required_popup: return
			password_required_popup = PasswordRequiredPopUp.instantiate()
			password_required_popup.canceled.connect(_cancel_password)
			password_required_popup.close_requested.connect(_cancel_password)
			password_required_popup.go_back_requested.connect(_cancel_password)
			password_required_popup.confirmed.connect(_submit_password)
			get_editor_interface().popup_dialog_centered(password_required_popup)
		else:
			var hc:=HashingContext.new()
			hc.start(HashingContext.HASH_SHA256)
			hc.update(password.to_utf8_buffer())
			hc.update(data)
			networking.send_packet_type(null,&"request_password",hc.finish())
func _handshake_complete(peer: PacketPeerUDP, data: Dictionary)->void:
	if networking.is_server:
		if connections[peer]["state"] in [CONNECTION_STATE_AWAIT_INSTANCES_TRUSTED,CONNECTION_STATE_AWAIT_INSTANCES_UNTRUSTED]:
			networking.disconnect_peer(peer,"Nah.",true)
			return
		_resume_packets()
		connections[peer]["state"] = CONNECTION_STATE_ESTABLISHED_TRUSTED if connections[peer]["state"] == CONNECTION_STATE_AWAIT_INSTANCES_TRUSTED else CONNECTION_STATE_ESTABLISHED_UNTRUSTED
	else:
		asset_size=data["size"]
		loading_bar = LoadingPopup.instantiate()
		loading_bar.remove_button(loading_bar.get_ok_button()) # No buttons
		loading_bar.visible = true
		add_child(loading_bar)
		loading_bar.get_node("VBoxContainer/Message").text = "Downloading"
		loading_bar.get_node("VBoxContainer/ProgressBar/Label").text = "%s/%s"%[String.humanize_size(0),String.humanize_size(asset_size)]
		var fstream := FileAccess.open("res://addons/live_editing/download_assets.zip",FileAccess.WRITE)
		if fstream:
			fstream.close()
		else:
			push_error(error_string(FileAccess.get_open_error()))
			networking.disconnect_network(true)
func _recv_main_file(peer: PacketPeerUDP, data: PackedByteArray)->void:
	if networking.is_server:
		networking.disconnect_peer(peer,"Disconnected",true) # Not meant to receive under no circumstances
		return
	else:
		var fstream := FileAccess.open("res://addons/live_editing/download_assets.zip",FileAccess.READ_WRITE)
		fstream.seek_end()
		fstream.store_buffer(data.slice(4))
		fstream.close()
		asset_current_size += 4096
		if data.decode_u32(0) == 2**32-1:
			loading_bar.get_node("VBoxContainer/ProgressBar/Label").text = ""
			loading_bar.get_node("VBoxContainer/Message").text = "Unpacking"
			_unpack_main_asset_file.call_deferred()
		else:
			loading_bar.get_node("VBoxContainer/ProgressBar/Label").text = "%s/%s"%[String.humanize_size(asset_current_size),String.humanize_size(asset_size)]
func _load_scene(peer: PacketPeerUDP, data: Dictionary)->void:
	if networking.is_server:
		var path: String = data["path"]
		if path in scenes:
			scenes[path]["refs"]+=1
			connections[peer]["loaded_scenes"].append(path)
			return
		if path == "": networking.disconnect_peer(peer,"Disconnected.",true)
		if connections[peer]["state"] == CONNECTION_STATE_ESTABLISHED_UNTRUSTED || !server_trust_mode:
			if path.begins_with("res://addons"): 
				networking.disconnect_peer(peer,"Disconnected.",true)
				return
			if !path.begins_with("res://"):
				networking.disconnect_peer(peer,"Disconnected.",true)
				return
		var is_scene:=false
		for ext in ResourceLoader.get_recognized_extensions_for_type("PackedScene"):
			if path.ends_with(ext):
				is_scene = true
				break
		if !is_scene:
			networking.disconnect_peer(peer,"Disconnected.",true)
		connections[peer]["loaded_scenes"].append(path)
		var scene:PackedScene=load(path)
		if not scene:
			push_error("Scene is NULL")
			return
		if not scene.can_instantiate():
			push_error("assert(scene.can_instantiate()) failed")
			return
		var scene_data := {
			"refs":1,
			"root":scene.instantiate()
		}
		scenes[path]=scene_data
		networking.send_packet_type(peer,&"load_scene",{"root":_broadcast_object(null,scene_data["root"])})
	else:
		var node:Node=instance_ids_reversed[data["root"]]
		var scene_root:Node= get_editor_interface().get_edited_scene_root()
		if scene_root == null:
			push_error("assert(scene_root != null) failed")
			return
		scene_root.replace_by(node,false)
func _new_object(peer: PacketPeerUDP, data: Dictionary)->void:
	var oid:=data["oid"]
	if instance_ids_reversed.get(oid) != null:
		return
	if ClassDB.can_instantiate(data["class"]):
		pass

func _unpack_main_asset_file():
	if trust_mode:
		#literally just unpack
		var zip:ZIPReader=ZIPReader.new()
		assert(zip.open("res://addons/live_editing/download_assets")==OK)
		for file in zip.get_files():
			if !file.begins_with("addons"):
				var fstream := FileAccess.open("res://"+file,FileAccess.WRITE)
				fstream.store_buffer(zip.read_file(file))
				fstream.close()
		zip.close()
	else:
		var zip:ZIPReader=ZIPReader.new()
		assert(zip.open("res://addons/live_editing/download_assets")==OK)
		var regex:=RegEx.create_from_string("(?m)^@tool")
		for file in zip.get_files():
			if !file.begins_with("addons"):
				var filecontent:=zip.read_file(file)
				var s:=filecontent.get_string_from_utf8()
				if len(s) != 0:
					if regex.search(s) != null:
						filecontent = PackedByteArray() # clear it
				var fstream := FileAccess.open("res://"+file,FileAccess.WRITE)
				fstream.store_buffer(zip.read_file(file))
				fstream.close()
		zip.close()
	networking.send_packet_type(null,&"handshake_complete",{})
func _cancel_password():
	password_required_popup.queue_free()
	password_required_popup = null
	_disconnect(null,"User disconnected while inputting password")
func _submit_password():
	password = password_required_popup.get_node("Container/LineEdit").text
	password_required_popup.queue_free()
	password_required_popup = null
	var hc:=HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(password.to_utf8_buffer())
	hc.update(passw_salt)
	networking.send_packet_type(null,&"request_password",hc.finish())
func _disconnect(peer: PacketPeerUDP,why: String,force:=false)->void:
	connections.erase(peer)
	networking.disconnect_peer(peer,why,force)

func _client_joined(peer: PacketPeerUDP)->void:
	connections[peer]={
		"state": CONNECTION_STATE_WAITING_INIT if password == "" else CONNECTION_STATE_WAITING_PASSWORD,
		"loaded_scenes":[]
	}
	if password != "":
		var c:=Crypto.new()
		connections[peer]["password_salt"]=c.generate_random_bytes(256)
		networking.send_packet_type(peer,&"request_password",connections[peer]["password_salt"])
	else:
		networking.send_packet_type(peer,&"initialize",{
			"trusted":server_trust_mode
		})
func _client_left(peer: PacketPeerUDP)->void:
	if connections[peer]["state"] in [CONNECTION_STATE_AWAIT_INSTANCES_TRUSTED,CONNECTION_STATE_AWAIT_INSTANCES_UNTRUSTED]:
		_resume_packets.call_deferred()
	for i in connections[peer]["loaded_scenes"]:
		var data = {}
		data["__packet__"]=&"unload_scene"
		data["scene"]=i
		if packets_paused:
			_cache_packet(peer,var_to_bytes(data))
		else:
			networking._on_incoming_packet(peer,var_to_bytes(data))
	connections.erase(peer) # Delete
func _server_init()->void:
	packets_paused = false
	packet_buffer.clear()
	instance_ids.clear()
	scenes.clear()
	connections.clear()
func _connected_to_server()->void:
	trust_mode = last_connected_ip in trusted_IPs
	networking.allow_decoding_objects = false

func _exit_tree():
	# Clean-up of the plugin goes here.
	if networking.state == 2:
		networking.disconnect_network(true)
	menu.queue_free()
