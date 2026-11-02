@tool
class_name WaterSimSubstance
extends Resource
## What a liquid is made of: water, slime. Substances in one [WaterSim] all push on each
## other, and a particle can turn from one into another at any time: it restarts at rest.
##
## Ready-made ones are in [code]substances/[/code]. Units are SI (kg, m, s, Pa s). How stiff the liquid is comes from the box's
## bounded pressure ([member WaterSim.bounded_gain]), not from the substance.

enum Settle {
	## Stays as particles (the box sleeps with them in it).
	STAY,
	## Goes into the [WaterSimStillWater] under it (one holding this substance).
	STILL_WATER,
}

## kg/m^3.
@export var density := 1000.0:
	set(value):
		density = value
		emit_changed()
## Thickness (Pa s). Water is close to 0; slime a few hundred. Thick
## liquids also cling to surfaces, whatever their [member friction].
@export var viscosity := 0.0:
	set(value):
		viscosity = value
		emit_changed()

## How much it drags when sliding along colliders and the box's walls (Coulomb friction):
## 0 slips freely, 1 grips; 0.7 by default. The surface's own friction
## ([member WaterSimCollider.friction]) multiplies it.
@export_range(0.0, 2.0) var friction := 0.7:
	set(value):
		friction = value
		emit_changed()

## The chance a step (0 to 1) that a particle of it sheds spray when it is fast, flying free or jolted in a thin place: what a
## [WaterSimSprayView] draws (the simulation never sees it). 0: none (slime).
@export_range(0.0, 1.0, 0.01) var spray := 0.3:
	set(value):
		spray = value
		emit_changed()

## What it becomes when its box settles and sleeps (see [WaterSim]).
@export var settles_as := Settle.STAY

@export_group("Look")
## Colour in a [WaterSimParticleView], and where the water is deep in a [WaterSimFluidView].
@export var color := Color(0.25, 0.55, 0.95):
	set(value):
		color = value
		emit_changed()
## The colour in a [WaterSimFluidView] where the water is thin (a splash, the edge of a pool): it blends to [member color] as the
## water gets thicker.
@export var shallow_color := Color(0.45, 0.75, 0.95):
	set(value):
		shallow_color = value
		emit_changed()


## The settings [method WaterSimSolver.set_substance] takes.
func to_settings() -> Dictionary:
	return {
		"density": density,
		"viscosity": viscosity,
		"friction": friction,
		"spray": spray,
	}
