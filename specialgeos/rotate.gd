extends AnimatableBody3D

@export var rotation_speed: float = 1.0 # Adjust this in the Inspector
@export var rotation_axis: Vector3 = Vector3.UP # Spins around the Y axis by default

func _physics_process(delta: float) -> void:
	# Rotate the platform smoothly during the physics step
	# We use global_transform.basis to ensure it rotates correctly 
	# even if placed at odd angles in the world.
	rotate_object_local(rotation_axis, rotation_speed * delta)
