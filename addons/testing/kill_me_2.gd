extends EditorProperty

var deployed:=false
var o

func _init(o_):
	o = o_

func _update_property():
	if deployed:
		print(get_edited_object(),".",get_edited_property()," = ",get_edited_object().get(get_edited_property()))
