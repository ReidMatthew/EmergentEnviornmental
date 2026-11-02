extends "demo_tool.gd"
## Click an object with a [WaterSimTransmuter] (the rocks) to turn it into its substance.


func press(hit: Object) -> void:
	super.press(hit)
	var node := hit as Node
	while node != null:
		for child in node.get_children():
			if child is WaterSimTransmuter:
				child.transmute()
				return
		node = node.get_parent()
