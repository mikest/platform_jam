extends Node3D

@onready var sky: Sky3D = $Sky3D
@onready var ocean: OceanArea = $OceanArea

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	_update_sky()


func _update_sky():
	if sky:
		if ocean.wave_sampler.material:
			var sky_color := Color.BLACK
			if sky.sun.light_energy > 0.0:
				sky_color = sky.sun.light_color # * sky.sun.light_energy
			if sky.moon.light_energy > 0.0:
				sky_color += sky.moon.light_color # * sky.moon.light_energy
				
			ocean.wave_sampler.material.set_shader_parameter("SkyColor", sky_color * 0.1)
		
		if ocean.tidal_override < 0.0:
			var altitude := sky.tod._moon_coords.y
			ocean.tide_phase = remapf(altitude, -PI, PI, 0.0, 1.0)
		else:
			ocean.tide_phase = clampf(ocean.tidal_override, 0.0, 1.0)


func remapf(value: float, from_min: float, from_max: float, to_min: float, to_max: float) -> float:
	return (value - from_min) / (from_max - from_min) * (to_max - to_min) + to_min
