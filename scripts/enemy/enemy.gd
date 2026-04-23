extends CharacterBody2D

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var health_component: Node = $HealthComponent
@onready var nav_agent: NavigationAgent2D = $NavigationAgent2D
@onready var debug_vision: Node2D = $DebugVision

enum State {
	IDLE,
	PATROL,
	CHASE,
	ATTACK,
	DEAD,
}

var _player: CharacterBody2D = null

# Spawn position used for leash_radius (return to patrol if dragged too far from “home”).
var _leash_origin: Vector2 = Vector2.ZERO

# While chasing: counts down only when the player is outside lose_radius (with optional LOS).
# When it hits zero, we give up and resume the patrol route.
var _chase_interest_timer: float = 0.0

var state: State = State.PATROL
var is_dead: bool = false
var last_direction: Vector2 = Vector2.DOWN
var direction: Vector2 = Vector2.ZERO

# Seconds left standing at a waypoint before moving to the next.
var patrol_wait_timer: float = 0.0

# Marker2D children of the map’s patrol route node, in visit order.
var patrol_points: Array[Marker2D] = []
var patrol_index: int = 0
## +1 forward through waypoints, -1 backward (used when patrol_mode_loop is false).
var _patrol_ping_step: int = 1

@export var debug_mode: bool = false

@export var patrol_speed: float = 60.0
@export var patrol_wait_time: float = 1.0

@export var detection_radius: float = 100.0
@export var lose_radius: float = 200.0
@export var chase_memory_seconds: float = 2.0
@export var chase_speed: float = 100.0
## 0 = no leash. When > 0, chase ends if the enemy moves farther than this from _leash_origin (set once at spawn).
## If this is small and the patrol route walks the enemy away from spawn, chase will instantly cancel every frame.
@export var leash_radius: float = 0.0
@export var use_line_of_sight: bool = false
## Max distance used by LOS cone checks (separate from detection/lose radii).
@export var line_of_sight_radius: float = 220.0
## Total cone angle in degrees (e.g. 90 means 45 degrees left and right of facing).
@export var line_of_sight_fov_degrees: float = 90.0

## Assign in the editor to the map’s route node (e.g. PatrolRoute1). If empty, falls back to patrol_route_name under the parent.
@export var patrol_route_path: NodePath
@export var patrol_route_name: String = "PatrolRoute1"
@export var waypoint_reach_distance := 8.0
## true: A→B→C→D→A…  false: A→B→C→D→C→B→A…
@export var patrol_mode_loop := true

func _ready() -> void:
	if debug_mode:
		debug_vision.visible = true
	else:
		debug_vision.visible = false

	# Capture after the node is in the tree so global_position matches the placed enemy.
	_leash_origin = global_position

	if _player == null or not is_instance_valid(_player):
		_resolve_player()

	# Always wire health first so enemies with no route still react to damage/death.
	health_component.died.connect(_on_died)
	health_component.hurt.connect(_on_hurt)
	health_component.invulnerability_started.connect(_on_invulnerability_started)
	health_component.invulnerability_ended.connect(_on_invulnerability_ended)

	var route := _resolve_patrol_route()
	patrol_points.clear()
	if route:
		for child in route.get_children():
			if child is Marker2D:
				patrol_points.append(child)
		# Scene tree order is preserved; sort by node name so A,B,C,D is stable if reordered in editor.
		patrol_points.sort_custom(func(a: Marker2D, b: Marker2D) -> bool:
			return String(a.name) < String(b.name)
		)

	if patrol_points.is_empty():
		state = State.IDLE
		return

	_patrol_ping_step = 1
	patrol_index = clampi(patrol_index, 0, patrol_points.size() - 1)
	# Navigation mesh may not be ready on the same frame as _ready; defer avoids a bad first path.
	call_deferred("_refresh_nav_target_to_current_waypoint")


# Editor path wins; otherwise look for patrol_route_name on the same parent as this enemy (typical map layout).
func _resolve_patrol_route() -> Node2D:
	if patrol_route_path != NodePath():
		var n := get_node_or_null(patrol_route_path)
		if n is Node2D:
			return n
	var parent_n := get_parent()
	if parent_n:
		var by_name := parent_n.get_node_or_null(patrol_route_name)
		if by_name is Node2D:
			return by_name
	return null


# NavigationAgent2D expects a global point on the baked nav region.
func _refresh_nav_target_to_current_waypoint() -> void:
	if patrol_points.is_empty():
		return
	patrol_index = clampi(patrol_index, 0, patrol_points.size() - 1)
	nav_agent.target_position = patrol_points[patrol_index].global_position


# Called after finishing the wait at a waypoint (see _update_idle). Updates patrol_index only; target is set separately.
func _advance_patrol_index() -> void:
	if patrol_points.is_empty():
		return
	var n := patrol_points.size()
	if n == 1:
		return
	if patrol_mode_loop:
		patrol_index = (patrol_index + 1) % n
		return
	# Ping-pong: … C → D → C → B → A …
	var next_i := patrol_index + _patrol_ping_step
	if next_i >= n:
		_patrol_ping_step = -1
		patrol_index = maxi(0, n - 2)
	elif next_i < 0:
		_patrol_ping_step = 1
		patrol_index = mini(n - 1, 1)
	else:
		patrol_index = next_i


func _physics_process(_delta: float) -> void:
	if is_dead:
		return

	# State machine: patrol/idle can switch into CHASE when perception fires; CHASE/ATTACK run their own tick.
	match state:
		State.PATROL:
			# Spot the player even while walking the route (not only when standing at a waypoint).
			_try_enter_chase_from_patrol()
			if state == State.PATROL:
				_update_patrol(_delta)
		State.IDLE:
			# Same as patrol: standing at a waypoint should not make the enemy “blind”.
			_try_enter_chase_from_patrol()
			if state == State.IDLE:
				_update_idle(_delta)
		State.CHASE:
			_update_chase(_delta)
		State.ATTACK:
			_update_attack(_delta)

	if direction:
		last_direction = direction

	# Keep debug cone aligned in every state, not only while patrolling.
	if debug_vision != null:
		var facing := direction if direction != Vector2.ZERO else last_direction
		debug_vision.rotation = facing.angle()

	update_animation()


func _movement_animation_blocked() -> bool:
	if not animated_sprite.is_playing():
		return false
	var n := String(animated_sprite.animation)
	return n == "hurt" or n.begins_with("slash_")


func update_animation() -> void:
	if _movement_animation_blocked():
		return
	if is_dead:
		return

	var moving := direction != Vector2.ZERO
	var facing := direction if moving else last_direction
	var anim := ("walk_" if moving else "idle_") + _facing_suffix(facing)
	if animated_sprite.animation != anim or not animated_sprite.is_playing():
		animated_sprite.play(anim)


func _facing_suffix(dir: Vector2) -> String:
	if dir.length_squared() == 0.0:
		return "down"
	var ax := absf(dir.x)
	var ay := absf(dir.y)
	if ax >= ay:
		if dir.x > 0.0:
			return "right"
		if dir.x < 0.0:
			return "left"
		return "down" if dir.y > 0.0 else "up"
	return "down" if dir.y > 0.0 else "up"


# Follow NavigationAgent2D’s path toward the current waypoint; pause at waypoints via IDLE + patrol_wait_timer.
func _update_patrol(delta: float) -> void:
	if patrol_points.is_empty():
		velocity = Vector2.ZERO
		direction = Vector2.ZERO
		return

	# Still counting down the stand-still at this waypoint (timer was set when we entered IDLE from patrol).
	if patrol_wait_timer > 0.0:
		patrol_wait_timer -= delta
		velocity = Vector2.ZERO
		direction = Vector2.ZERO
		return

	# Steer toward the next baked path corner; avoids static obstacles per NavigationRegion2D.
	var next_pos := nav_agent.get_next_path_position()
	var to_next := next_pos - global_position
	var dir := Vector2.ZERO
	if to_next.length_squared() > 0.0001:
		dir = to_next.normalized()
	else:
		# Agent can report “next” == self when path is empty or not updated yet; nudge toward the marker.
		var to_wp := patrol_points[patrol_index].global_position - global_position
		if to_wp.length_squared() > 0.0001:
			dir = to_wp.normalized()

	direction = dir
	velocity = dir * patrol_speed
	move_and_slide()

	# Close enough to this waypoint: stop moving and hand off to IDLE (actual index bump happens after the wait).
	if global_position.distance_to(patrol_points[patrol_index].global_position) <= waypoint_reach_distance:
		patrol_wait_timer = patrol_wait_time
		state = State.IDLE


func _update_idle(delta: float) -> void:
	direction = Vector2.ZERO
	velocity = Vector2.ZERO

	if patrol_wait_timer > 0.0:
		patrol_wait_timer -= delta
		return

	# Wait finished: pick next waypoint, tell the nav agent, resume walking.
	_advance_patrol_index()
	_refresh_nav_target_to_current_waypoint()
	state = State.PATROL


# If the player is close enough (and optional LOS passes), interrupt patrol/idle and start chasing.
func _try_enter_chase_from_patrol() -> void:
	if _player == null or not is_instance_valid(_player):
		_resolve_player()
	if _player == null or not is_instance_valid(_player):
		return

	# Patrol entry perception:
	# - LOS off: keep the original radial detection behavior.
	# - LOS on: require cone + LOS raycast using line_of_sight_* exports.
	if use_line_of_sight:
		if not _can_see_player_in_cone(line_of_sight_radius):
			return
	else:
		var dist_sq := global_position.distance_squared_to(_player.global_position)
		if dist_sq > detection_radius * detection_radius:
			return

	state = State.CHASE
	# Full “interest” when we first commit to chase; _update_chase will refresh while the player stays in range.
	_chase_interest_timer = chase_memory_seconds if chase_memory_seconds > 0.0 else INF


# Drive NavigationAgent2D toward the player each tick; same steering pattern as patrol but at chase_speed.
func _update_chase(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_resolve_player()
	if _player == null or not is_instance_valid(_player):
		_return_to_patrol()
		return

	# Leash: stop pursuing if kited too far from where the enemy started (prevents map-wide chases).
	# leash_radius <= 0 disables this check — a small positive radius while patrolling far from spawn causes
	# chase to end on the first physics tick (flip-flop PATROL/CHASE) because _leash_origin never moves.
	if leash_radius > 0.0 and global_position.distance_squared_to(_leash_origin) > leash_radius * leash_radius:
		_return_to_patrol()
		return

	# Keep the baked path updated toward the moving player.
	nav_agent.target_position = _player.global_position

	var next_pos := nav_agent.get_next_path_position()
	var to_next := next_pos - global_position
	var dir := Vector2.ZERO
	if to_next.length_squared() > 0.0001:
		dir = to_next.normalized()
	else:
		var to_player := _player.global_position - global_position
		if to_player.length_squared() > 0.0001:
			dir = to_player.normalized()

	direction = dir
	velocity = dir * chase_speed
	move_and_slide()

	# Hysteresis + memory: stay committed while perception still says “valid target”.
	# LOS off: keep the original lose_radius behavior.
	# LOS on: keep LOS requirement and use a cone radius at least as large as lose_radius so retention
	# does not become stricter than your de-aggro radius tuning.
	var in_lose := false
	if use_line_of_sight:
		var los_keep_radius := maxf(lose_radius, line_of_sight_radius)
		in_lose = _can_see_player_in_cone(los_keep_radius)
	else:
		in_lose = global_position.distance_squared_to(_player.global_position) <= lose_radius * lose_radius

	if in_lose:
		# chase_memory_seconds == 0 means “no grace after leaving lose_radius”, not “give up while still in range”.
		_chase_interest_timer = chase_memory_seconds if chase_memory_seconds > 0.0 else INF
	else:
		_chase_interest_timer -= delta

	if _chase_interest_timer <= 0.0:
		_return_to_patrol()


# Placeholder for future melee/ranged: enter from CHASE when in attack range, play swing, then pop back to CHASE or patrol.
func _update_attack(_delta: float) -> void:
	pass


# Resume the patrol route from the current waypoint (or keep waiting if we interrupted a waypoint pause).
func _return_to_patrol() -> void:
	if patrol_points.is_empty():
		state = State.IDLE
		return

	_refresh_nav_target_to_current_waypoint()
	if patrol_wait_timer > 0.0:
		state = State.IDLE
	else:
		state = State.PATROL


func _has_line_of_sight_to_player() -> bool:
	if _player == null or not is_instance_valid(_player):
		return false
	var space := get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(global_position, _player.global_position)
	q.exclude = [get_rid()]
	# Ignore Areas for LOS so player/enemy hitboxes don't falsely block vision.
	q.collide_with_areas = false
	q.collide_with_bodies = true
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return true
	var collider: Object = hit.get("collider", null)
	# Accept direct player body or child colliders that belong to the player.
	if collider == _player:
		return true
	if collider is Node:
		var n := collider as Node
		if n.is_in_group("player"):
			return true
		if n.get_parent() == _player:
			return true
	return false


# Cone + radius + occlusion test used when use_line_of_sight is enabled.
# The enemy's "forward" is the current movement direction; when idle, it falls back to last_direction.
func _can_see_player_in_cone(radius: float) -> bool:
	if _player == null or not is_instance_valid(_player):
		return false
	if radius <= 0.0:
		return false

	var to_player := _player.global_position - global_position
	if to_player.length_squared() > radius * radius:
		return false

	# Use movement direction as the facing vector; fallback keeps a stable cone while standing still.
	var facing := direction if direction.length_squared() > 0.0 else last_direction
	if facing.length_squared() == 0.0:
		facing = Vector2.DOWN
	facing = facing.normalized()

	var dir_to_player := to_player.normalized()
	var half_fov_rad := deg_to_rad(clampf(line_of_sight_fov_degrees, 0.0, 360.0) * 0.5)
	var min_dot := cos(half_fov_rad)
	# Dot product compares angle cheaply: 1.0 = directly ahead, 0.0 = 90 degrees, -1.0 = behind.
	if facing.dot(dir_to_player) < min_dot:
		return false

	# Final check: even inside the cone, a wall should block sight.
	return _has_line_of_sight_to_player()


func _resolve_player() -> void:
	_player = get_tree().get_first_node_in_group("player")
	if _player != null and is_instance_valid(_player):
		print("Player found: ", _player.name)
	else:
		print("Player not found")


func _on_hurt():
	animated_sprite.play("hurt")


func _on_died():
	is_dead = true
	animated_sprite.play("death")


func _on_invulnerability_started():
	print("Enemy invulnerability started")


func _on_invulnerability_ended():
	print("Enemy invulnerability ended")
