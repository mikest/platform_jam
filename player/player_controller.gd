extends CharacterBody3D

@export_group("Movement")
## Character maximum run speed on the ground in meters per second.
@export var move_speed := 8.0
## Ground movement acceleration in meters per second squared.
@export var acceleration := 20.0
## When the player is on the ground and presses the jump button, the vertical
## velocity is set to this value.
@export var jump_impulse := 12.0
## Minimum upward velocity preserved when the jump button is released early.
## Controls the shortest possible jump height.
@export var min_jump_velocity := 6.0
## Player model rotation speed in arbitrary units. Controls how fast the
## character skin orients to the movement or camera direction.
@export var rotation_speed := 12.0
## Minimum horizontal speed on the ground. This controls when the character skin's
## animation tree changes between the idle and running states.
@export var stopping_speed := 1.0
## Amount of squash animation to apply upon landing on the ground.
@export var landing_animation_scale := 1.0

@export_group("Camera")
@export_range(0.0, 1.0) var mouse_sensitivity := 0.25
## Controller right stick sensitivity (degrees per second, roughldy).
@export var controller_camera_sensitivity := 3.0

## Camera tilt bounds
@export var cam_tilt_upper_limit := PI / 3.0
@export var cam_tilt_lower_limit := -PI / 8.0
## How quickly the camera rotation catches up to the target. Higher = snappier.
@export var camera_rotation_smoothing := 20.0
## How quickly the camera position follows the player. Higher = tighter.
@export var camera_position_smoothing := 10.0

@export_group("Footsteps")
## How much the pitch is randomly varied each step (e.g. 0.1 = +/- 10%).
@export var pitch_variation := 0.1

@export_group("Edge Grab")
## How far forward the wall-detection ray reaches (meters).
@export var edge_grab_ray_length := 0.6
## How far above the capsule top the ledge-check ray starts (meters).
@export var edge_grab_head_offset := -0.2
## Upward impulse when jumping from an edge grab (meters/second).
@export var edge_grab_jump_impulse := 12.0
## How far forward (toward the wall) the character is shifted when grabbing a
## ledge. Increase to close the gap between the model and the wall surface.
@export var edge_grab_forward_offset := 0.3
## How far below the ledge surface the character's origin sits when hanging.
## Adjust so the grab animation lines up with the ledge visually.
@export var edge_grab_vertical_offset := 1.3

@export_group("Wall Slide")
## Multiplier on gravity during a wall slide (0.0 = no gravity, 1.0 = full).
@export var wall_slide_gravity_scale := 0.1
## Upward impulse when wall-jumping (meters/second).
@export var wall_jump_impulse := 10.0
## Horizontal push-off speed perpendicular to the wall on a wall-jump (meters/second).
@export var wall_jump_push_off := 6.0
## Maximum approach angle (degrees from head-on) to trigger a wall slide.
## 0° = perfectly head-on, 90° = perfectly parallel to the wall.
## The player must be within this many degrees of head-on. Higher = more lenient.
@export_range(0.0, 90.0) var wall_slide_max_angle := 55.0

## Player state enum —- governs which branch of _physics_process runs.
enum PlayerState { DEFAULT, EDGE_GRAB, WALL_SLIDE }
enum AnimState { IDLE, MOVE, JUMP, FALL, EDGE_GRAB, WALL_SLIDE }

## Each frame, we find the height of the ground below the player and store it here.
## The camera uses this to keep a fixed height while the player jumps, for example.
var ground_height := 0.0

var _gravity := -30.0
var _was_on_floor_last_frame := true
var _camera_input_direction := Vector2.ZERO
var _target_cam_yaw := 0.0
var _target_cam_pitch := 0.0
var _previous_skin_rotation_y := 0.0
var _smoothed_tilt := 0.0
var _is_jumping := false
var _anim_state: AnimState = AnimState.IDLE

var _state: PlayerState = PlayerState.DEFAULT
var _wall_normal := Vector3.ZERO

## The last movement or aim direction input by the player. We use this to orient
## the character model.
@onready var _last_input_direction := global_basis.z
# We store the initial position of the player to reset to it when the player falls off the map.
@onready var _start_position := global_position

@onready var _camera_pivot: Node3D = %CameraPivot
@onready var _camera: Camera3D = %Camera3D
@onready var _skin: SophiaSkin = %ElektraSkin
@onready var _landing_sound: AudioStreamPlayer3D = %LandingSound
@onready var _jump_sound: AudioStreamPlayer3D = %JumpSound
@onready var _dust_particles: GPUParticles3D = %DustParticles
@onready var _dust_particles_wall: GPUParticles3D = %DustParticlesWall
@onready var _dust_particles_land: GPUParticles3D = %DustParticlesLand
@onready var _step_sounds: Array[AudioStreamPlayer3D] = [%Step1, %Step2, %Step3]

# Raycasts created at runtime for edge/wall detection.
var _wall_ray: RayCast3D
var _ledge_ray: RayCast3D
var _floor_above_ray: RayCast3D


func _ready() -> void:
	Events.kill_plane_touched.connect(func on_kill_plane_touched() -> void:
		global_position = _start_position
		velocity = Vector3.ZERO
		_state = PlayerState.DEFAULT
		_skin.idle()
		set_physics_process(true)
	)
	Events.flag_reached.connect(func on_flag_reached() -> void:
		set_physics_process(false)
		_state = PlayerState.DEFAULT
		_skin.idle()
		_dust_particles.emitting = false
		_dust_particles_wall.emitting = false
	)
	_skin.footstep_landed.connect(_play_footstep)
	_setup_raycasts()
	# Make the camera pivot transform in world space so its position can be
	# smoothly interpolated independently of the CharacterBody3D.
	_camera_pivot.top_level = true
	_camera_pivot.global_position = global_position
	_target_cam_yaw = _camera_pivot.rotation.y
	_target_cam_pitch = _camera_pivot.rotation.x


func _setup_raycasts() -> void:
	# Wall ray — chest height, points forward.
	_wall_ray = RayCast3D.new()
	_wall_ray.position = Vector3(0.0, 0.8, 0.0)
	_wall_ray.target_position = Vector3(0.0, 0.0, -edge_grab_ray_length)
	_wall_ray.enabled = true
	_wall_ray.collision_mask = 1  # Only layer 1 — excludes moving platforms on layer 2
	add_child(_wall_ray)

	# Ledge ray — above the capsule top, points forward. If this ray does NOT hit
	# but the wall ray DOES, we know there's a ledge (open space above the wall).
	_ledge_ray = RayCast3D.new()
	# Capsule is at Y=1.0 with radius 0.4 → top of capsule ≈ 1.5
	_ledge_ray.position = Vector3(0.0, 1.5 + edge_grab_head_offset, 0.0)
	_ledge_ray.target_position = Vector3(0.0, 0.0, -edge_grab_ray_length)
	_ledge_ray.enabled = true
	_ledge_ray.collision_mask = 1  # Only layer 1 — excludes moving platforms on layer 2
	add_child(_ledge_ray)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("left_click"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	var player_is_using_mouse := (
		event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
	)
	if player_is_using_mouse:
		_camera_input_direction.x = -event.relative.x * mouse_sensitivity
		_camera_input_direction.y = event.relative.y * mouse_sensitivity


func _physics_process(delta: float) -> void:
	# ── Camera input (always active) ──────────────────────────────────────
	var stick_input := Input.get_vector("look_left", "look_right", "look_up", "look_down", 0.15)
	_camera_input_direction.x += -stick_input.x * controller_camera_sensitivity
	_camera_input_direction.y += stick_input.y * controller_camera_sensitivity

	# Accumulate input into target angles.
	_target_cam_pitch += _camera_input_direction.y * delta
	_target_cam_pitch = clamp(_target_cam_pitch, cam_tilt_lower_limit, cam_tilt_upper_limit)
	_target_cam_yaw += _camera_input_direction.x * delta
	_camera_input_direction = Vector2.ZERO

	# Smoothly interpolate rotation toward the target.
	_camera_pivot.rotation.x = lerp_angle(_camera_pivot.rotation.x, _target_cam_pitch, camera_rotation_smoothing * delta)
	_camera_pivot.rotation.y = lerp_angle(_camera_pivot.rotation.y, _target_cam_yaw, camera_rotation_smoothing * delta)

	# Smoothly follow the player's position.
	_camera_pivot.global_position = _camera_pivot.global_position.lerp(global_position, camera_position_smoothing * delta)

	# ── Dispatch to current state ─────────────────────────────────────────
	match _state:
		PlayerState.DEFAULT:
			_process_default_state(delta)
		PlayerState.EDGE_GRAB:
			_process_edge_grab_state(delta)
		PlayerState.WALL_SLIDE:
			_process_wall_slide_state(delta)


# ══════════════════════════════════════════════════════════════════════════════
# DEFAULT STATE
# ══════════════════════════════════════════════════════════════════════════════
func _process_default_state(delta: float) -> void:
	# Calculate movement input and align it to the camera's direction.
	var raw_input := Input.get_vector("move_left", "move_right", "move_up", "move_down", 0.4)
	var input_magnitude := clampf(raw_input.length(), 0.0, 1.0)
	var forward := _camera.global_basis.z
	var right := _camera.global_basis.x
	var move_direction := forward * raw_input.y + right * raw_input.x
	move_direction.y = 0.0
	move_direction = move_direction.normalized()

	# Orient the skin toward the movement direction.
	if move_direction.length() > 0.2:
		_last_input_direction = move_direction.normalized()
	var target_angle := Vector3.BACK.signed_angle_to(_last_input_direction, Vector3.UP)
	_skin.global_rotation.y = lerp_angle(_skin.rotation.y, target_angle, rotation_speed * delta)

	# Compute smoothed tilt from the skin's angular velocity.
	var rotation_delta := angle_difference(_previous_skin_rotation_y, _skin.global_rotation.y)
	var tilt_speed := 5.0
	var raw_tilt := clampf(rotation_delta / delta / tilt_speed, -1.0, 1.0)
	var tilt_smoothing := 8.0
	_smoothed_tilt = lerp(_smoothed_tilt, raw_tilt, clampf(tilt_smoothing * delta, 0.0, 1.0))
	var tilt := _smoothed_tilt
	_previous_skin_rotation_y = _skin.global_rotation.y

	# Ground-plane velocity.
	var y_velocity := velocity.y
	velocity.y = 0.0
	velocity = velocity.move_toward(move_direction * move_speed * input_magnitude, acceleration * delta)
	if is_equal_approx(move_direction.length_squared(), 0.0) and velocity.length_squared() < stopping_speed:
		velocity = Vector3.ZERO
	velocity.y = y_velocity + _gravity * delta

	# ── Animations & state transitions ────────────────────────────────────
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y += jump_impulse
		_is_jumping = true
		if _anim_state != AnimState.JUMP:
			_anim_state = AnimState.JUMP
			_skin.jump()
		_jump_sound.play()
	elif _is_jumping and not Input.is_action_pressed("jump") and velocity.y > min_jump_velocity:
		velocity.y = min_jump_velocity
		_is_jumping = false
	elif not is_on_floor() and velocity.y < 0:
		_is_jumping = false
		# ── Check for edge grab before falling animation ──
		if _try_edge_grab():
			return
		# ── Check for wall slide ──
		if _try_wall_slide():
			return
		if _anim_state != AnimState.FALL:
			_anim_state = AnimState.FALL
			_skin.fall()
	elif is_on_floor():
		_is_jumping = false
		if ground_speed > 0.0:
			_skin.animation_tree.set("parameters/StateMachine/Move/runspeed/scale", ground_speed / move_speed)
			_skin.animation_tree.set("parameters/StateMachine/Move/tilt/add_amount", -1 * _skin.tilt_scalar * clamp(tilt, -1.0, 1.0))
			if _anim_state != AnimState.MOVE:
				if _anim_state == AnimState.FALL:
					_skin.animation_tree.set("parameters/StateMachine/Move/land/add_amount", 1.0 * landing_animation_scale)
				else:
					_skin.animation_tree.set("parameters/StateMachine/Move/land/add_amount", 0.0)
				_anim_state = AnimState.MOVE
				_skin.move()
		elif _anim_state != AnimState.IDLE:
			if _anim_state == AnimState.FALL:
				_skin.animation_tree.set("parameters/StateMachine/Idle/land/add_amount", 1.0 * landing_animation_scale)
			else:
				_skin.animation_tree.set("parameters/StateMachine/Idle/land/add_amount", 0.0)
			_anim_state = AnimState.IDLE
			_skin.idle()

	_dust_particles.emitting = is_on_floor() && ground_speed > 0.0
	_dust_particles_wall.emitting = false
	
	if is_on_floor() and not _was_on_floor_last_frame:
		_landing_sound.play()
		_dust_particles_land.restart()

	_was_on_floor_last_frame = is_on_floor()
	move_and_slide()


# ══════════════════════════════════════════════════════════════════════════════
# EDGE GRAB STATE
# ══════════════════════════════════════════════════════════════════════════════
func _process_edge_grab_state(_delta: float) -> void:
	# Freeze the player in place.
	velocity = Vector3.ZERO

	if Input.is_action_just_pressed("jump"):
		# Jump up from the ledge (normal jump).
		velocity.y = edge_grab_jump_impulse
		_is_jumping = true
		_state = PlayerState.DEFAULT
		_skin.jump()
		_jump_sound.play()
		_was_on_floor_last_frame = false
		move_and_slide()
		return
	elif Input.is_action_just_pressed("drop"):
		# Drop into wall slide.
		_state = PlayerState.WALL_SLIDE
		velocity.y = -1.0  # Small initial downward push
		_skin.wall_slide()


# ══════════════════════════════════════════════════════════════════════════════
# WALL SLIDE STATE
# ══════════════════════════════════════════════════════════════════════════════
func _process_wall_slide_state(delta: float) -> void:
	# Apply reduced gravity and clamp downward speed.
	velocity.y += _gravity * wall_slide_gravity_scale * delta

	# Keep the character pressed against the wall (small push toward wall).
	var push := -_wall_normal * 1.0
	velocity.x = push.x
	velocity.z = push.z

	# Orient skin to face away from wall.
	var face_dir := -_wall_normal
	face_dir.y = 0.0
	if face_dir.length_squared() > 0.01:
		var target_angle := Vector3.BACK.signed_angle_to(face_dir.normalized(), Vector3.UP)
		_skin.global_rotation.y = target_angle

	# Wall jump
	if Input.is_action_just_pressed("jump"):
		velocity.y = wall_jump_impulse
		velocity += _wall_normal * wall_jump_push_off

		# Orient character to face away from wall (into the jump direction).
		var away_dir := _wall_normal
		away_dir.y = 0.0
		if away_dir.length_squared() > 0.01:
			_last_input_direction = away_dir.normalized()
			var target_angle := Vector3.BACK.signed_angle_to(-_last_input_direction, Vector3.UP)
			_skin.global_rotation.y = target_angle

		_is_jumping = true
		_state = PlayerState.DEFAULT
		_skin.jump()
		_jump_sound.play()
		_was_on_floor_last_frame = false
		move_and_slide()
		return

	# Exit: landed on floor.
	if is_on_floor():
		_state = PlayerState.DEFAULT
		_was_on_floor_last_frame = true
		_landing_sound.play()
		move_and_slide()
		return

	# Exit: no longer touching a wall (ran out of wall surface).
	_update_wall_ray_direction()
	if not _wall_ray.is_colliding():
		_state = PlayerState.DEFAULT
		_skin.fall()
		_was_on_floor_last_frame = false
		move_and_slide()
		return

	# Update wall normal from the current collision for curved surfaces.
	_wall_normal = _wall_ray.get_collision_normal()

	_dust_particles_wall.emitting = true

	_was_on_floor_last_frame = false
	move_and_slide()





# ══════════════════════════════════════════════════════════════════════════════
# DETECTION HELPERS
# ══════════════════════════════════════════════════════════════════════════════

## Points the wall ray and ledge ray in the direction the skin is facing.
func _update_wall_ray_direction() -> void:
	var skin_forward := _skin.global_basis.z
	skin_forward.y = 0.0
	skin_forward = skin_forward.normalized()
	_wall_ray.target_position = skin_forward * edge_grab_ray_length
	_ledge_ray.target_position = skin_forward * edge_grab_ray_length
	# Force the raycasts to update this physics frame.
	_wall_ray.force_raycast_update()
	_ledge_ray.force_raycast_update()


## Attempts to detect and enter edge grab. Returns true if we grabbed a ledge.
func _try_edge_grab() -> bool:
	_update_wall_ray_direction()
	# Edge grab: wall ray hits (there's a wall) but ledge ray misses (open space above).
	if _wall_ray.is_colliding() and not _ledge_ray.is_colliding():
		_wall_normal = _wall_ray.get_collision_normal()
		velocity = Vector3.ZERO
		_state = PlayerState.EDGE_GRAB
		_skin.edge_grab()
		# Snap the character toward the wall to close the visual gap.
		global_position -= _wall_normal * edge_grab_forward_offset
		# Snap vertical position: cast a ray down from above the ledge to find
		# the exact surface, then position the character at a fixed offset below.
		var wall_hit := _wall_ray.get_collision_point()
		var skin_forward := _skin.global_basis.z
		skin_forward.y = 0.0
		skin_forward = skin_forward.normalized()
		# Start the downward ray above the ledge, slightly past the wall edge.
		var ray_from := Vector3(wall_hit.x, global_position.y + 3.0, wall_hit.z) + skin_forward * 0.3
		var ray_to := ray_from + Vector3.DOWN * 6.0
		var space := get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
		query.exclude = [get_rid()]
		query.collision_mask = 1  # Exclude moving platforms on layer 2
		var result := space.intersect_ray(query)
		if result.size() > 0:
			var ledge_top_y: float = result["position"].y
			global_position.y = ledge_top_y - edge_grab_vertical_offset
		# Orient skin to face away from the wall.
		var face_dir := -_wall_normal
		face_dir.y = 0.0
		if face_dir.length_squared() > 0.01:
			var target_angle := Vector3.BACK.signed_angle_to(face_dir.normalized(), Vector3.UP)
			_skin.global_rotation.y = target_angle
		return true
	return false


## Attempts to detect and enter wall slide. Returns true if a wall slide started.
func _try_wall_slide() -> bool:
	_update_wall_ray_direction()
	if not _wall_ray.is_colliding():
		return false

	var wall_normal := _wall_ray.get_collision_normal()

	# Also make sure the ledge ray hits — if ledge ray misses, it's actually
	# an edge grab situation (handled by _try_edge_grab above).
	if not _ledge_ray.is_colliding():
		return false

	# ── Angle check ──
	# Compute the approach angle: how far from head-on the player is moving
	# relative to the wall. 0° = perfectly head-on, 90° = moving parallel.
	var horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
	if horizontal_velocity.length_squared() < 0.01:
		# No meaningful horizontal velocity — use the skin's facing direction instead.
		horizontal_velocity = _skin.global_basis.z
		horizontal_velocity.y = 0.0

	horizontal_velocity = horizontal_velocity.normalized()
	# Dot product: (-velocity) · wall_normal. Both point "away from wall" when
	# the player is heading into the wall, giving cos(0°) ≈ 1.0 for head-on.
	var dot := (-horizontal_velocity).dot(wall_normal)
	var approach_angle_deg := rad_to_deg(acos(clampf(dot, -1.0, 1.0)))

	if approach_angle_deg > wall_slide_max_angle:
		return false

	_wall_normal = wall_normal
	velocity.y = 0.0  # Kill downward momentum on entry
	_state = PlayerState.WALL_SLIDE
	_skin.wall_slide()

	# Orient skin to face away from wall.
	var face_dir := -_wall_normal
	face_dir.y = 0.0
	if face_dir.length_squared() > 0.01:
		var target_angle := Vector3.BACK.signed_angle_to(face_dir.normalized(), Vector3.UP)
		_skin.global_rotation.y = target_angle
	return true





func _play_footstep() -> void:
	# Guard: don't play if the character is airborne (e.g. animation blending
	# during a jump may still tick through the run cycle briefly).
	if not is_on_floor():
		return

	# Pick randomly from all three variants to avoid a repetitive pattern.
	var sound: AudioStreamPlayer3D = _step_sounds[randi() % _step_sounds.size()]

	# Apply slight random pitch variation to avoid a robotic, repetitive feel.
	sound.pitch_scale = 1.0 + randf_range(-pitch_variation, pitch_variation)
	sound.play()
