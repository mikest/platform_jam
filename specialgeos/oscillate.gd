extends AnimatableBody3D

## The axis along which the platform moves (normalized automatically).
@export var move_axis := Vector3.UP
## Total distance the platform travels from one end to the other (meters).
@export var distance := 4.0
## Time in seconds for one full cycle (out and back).
@export var period := 4.0
## Starting phase of the oscillation (0.0–1.0). Use to offset multiple
## platforms so they don't all move in sync.
@export_range(0.0, 1.0) var phase_offset := 0.0
## If true, the platform uses a smooth ease-in/ease-out motion.
## If false, it moves at a constant speed (triangle wave).
@export var use_smooth_motion := true

var _origin := Vector3.ZERO
var _elapsed := 0.0


func _ready() -> void:
	_origin = global_position
	# Convert the phase offset into elapsed time so the platform
	# starts at the correct point in its cycle.
	_elapsed = phase_offset * period


func _physics_process(delta: float) -> void:
	_elapsed += delta
	# Normalized time within the current cycle (0.0–1.0).
	var t := fmod(_elapsed, period) / period

	var offset_factor: float
	if use_smooth_motion:
		# Sine wave: smooth ease-in / ease-out, range mapped from [-1,1] to [0,1].
		offset_factor = (sin(t * TAU - PI / 2.0) + 1.0) / 2.0
	else:
		# Triangle wave: constant speed, reverses at each end.
		offset_factor = 1.0 - abs(2.0 * t - 1.0)

	global_position = _origin + move_axis.normalized() * distance * offset_factor
