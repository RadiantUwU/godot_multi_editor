@tool
extends EditorPlugin

var currently_selected_objects:Array[Object]
var resource_sel:=false
const OBJKILLME := preload("res://addons/testing/kill_me.gd")
var killme:Object=null

func _edited_object_changed():
	if resource_sel:
		resource_sel = false
	else:
		print("SELECT NODE")
		currently_selected_objects.clear()
		currently_selected_objects.append_array(get_editor_interface().get_selection().get_selected_nodes())
	print(currently_selected_objects)
func _object_id_selected(id: int):
	var obj:Object=instance_from_id(id)
	print(obj," SELECT_ID")
	currently_selected_objects.clear()
	currently_selected_objects.append(obj)
	resource_sel = true
func _select_resource(resource: Resource):
	print(resource," SELECT_RES")
	currently_selected_objects.clear()
	currently_selected_objects.append(resource)
	resource_sel = true
func _select_keyed(prop: String,value):
	if typeof(value) == TYPE_OBJECT:
		print(value," SELECT_KEY")
		currently_selected_objects.clear()
		currently_selected_objects.append(value)
		resource_sel = true
func _sel_prop(property):
	print(get_editor_interface().get_inspector().get_selected_path())
func _property_edited(property):
	print(currently_selected_objects,get_editor_interface().get_inspector().get_selected_path(),currently_selected_objects[0].get_indexed(get_editor_interface().get_inspector().get_selected_path()))

func _enter_tree():
	# Initialization of the plugin goes here.
	killme=OBJKILLME.new()
	add_inspector_plugin(killme)
	

func _exit_tree():
	# Clean-up of the plugin goes here.
	remove_inspector_plugin(killme)
	killme = null
