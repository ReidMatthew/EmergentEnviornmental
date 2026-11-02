extends "demo_tool.gd"
## The older demos' pour, tornado and blast: a [WaterSimTool] whose [member toggle] picks between holding and toggling (kept so
## their scenes load as they were).

## A click switches it on or off, and holding drags it (the tornado: it stays where it's left).
@export var toggle := false:
	set(value):
		toggle = value
		use = Use.TOGGLE if value else Use.HOLD
