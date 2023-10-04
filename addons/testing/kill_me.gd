extends EditorInspectorPlugin
# https://github.com/godotengine/godot/pull/82065

const KILLME2:=preload("res://addons/testing/kill_me_2.gd")

func _parse_end(object):
	var prop_names:=PackedStringArray()
	for property in object.get_property_list():
		if property["usage"] & PROPERTY_USAGE_EDITOR == PROPERTY_USAGE_EDITOR:
			var k:=KILLME2.new(self)
			k.set_deferred(&"deployed",true)
			add_property_editor(property["name"],k)
	

func _can_handle(object):
	return true
