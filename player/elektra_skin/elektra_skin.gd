class_name SophiaSkin extends Node3D

signal footstep_landed

@onready var animation_tree = %AnimationTree
@onready var state_machine : AnimationNodeStateMachinePlayback = animation_tree.get("parameters/StateMachine/playback")

## Amount of tilt to apply to the character while turning.
@export var tilt_scalar := 1.3

func idle():
	print("idling")
	state_machine.travel("Idle")

func move():
	state_machine.travel("Move")
	print("moving")

func fall():
	state_machine.travel("Fall")
	print("falling")

func jump():
	state_machine.travel("Jump")
	print("jumping")

func edge_grab():
	state_machine.travel("EdgeGrab")

func wall_slide():
	state_machine.travel("WallSlide")

func _on_footstep() -> void:
	footstep_landed.emit()
