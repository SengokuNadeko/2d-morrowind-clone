extends CharacterBody2D

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var health_component: Node = $HealthComponent
@onready var nav_agent: NavigationAgent2D = $NavigationAgent2D

enum State {
	IDLE,
	PATROL,
	CHASE,
	ATTACK,
	DEAD,
}

var state: State = State.PATROL
var is_dead: bool = false
var last_direction: Vector2 = Vector2.DOWN
var direction: Vector2 = Vector2.ZERO

var patrol_wait_timer: float = 0.0

var patrol_points: Array[Marker2D] = []
var patrol_index: int = 0
## +1 forward through waypoints, -1 backward (used when patrol_mode_loop is false).
var _patrol_ping_step: int = 1

@export var patrol_speed: float = 60.0
@export var patrol_wait_time: float = 1.0

## Assign in the editor to the map’s route node (e.g. PatrolRoute1). If empty, falls back to patrol_route_name under the parent.
@export var patrol_route_path: NodePath
@export var patrol_route_name: String = "PatrolRoute1"
@export var waypoint_reach_distance := 8.0
## true: A→B→C→D→A…  false: A→B→C→D→C→B→A…
@export var patrol_mode_loop := true

func _ready() -> void:
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
	call_deferred("_refresh_nav_target_to_current_waypoint")


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


func _refresh_nav_target_to_current_waypoint() -> void:
	if patrol_points.is_empty():
		return
	patrol_index = clampi(patrol_index, 0, patrol_points.size() - 1)
	nav_agent.target_position = patrol_points[patrol_index].global_position


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

	match state:
		State.PATROL:
			_update_patrol(_delta)
		State.IDLE:
			_update_idle(_delta)

	if direction:
		last_direction = direction

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


func _update_patrol(delta: float) -> void:
	if patrol_points.is_empty():
		velocity = Vector2.ZERO
		direction = Vector2.ZERO
		return

	if patrol_wait_timer > 0.0:
		patrol_wait_timer -= delta
		velocity = Vector2.ZERO
		direction = Vector2.ZERO
		return

	var next_pos := nav_agent.get_next_path_position()
	var to_next := next_pos - global_position
	var dir := Vector2.ZERO
	if to_next.length_squared() > 0.0001:
		dir = to_next.normalized()
	else:
		var to_wp := patrol_points[patrol_index].global_position - global_position
		if to_wp.length_squared() > 0.0001:
			dir = to_wp.normalized()

	direction = dir
	velocity = dir * patrol_speed
	move_and_slide()

	if global_position.distance_to(patrol_points[patrol_index].global_position) <= waypoint_reach_distance:
		patrol_wait_timer = patrol_wait_time
		state = State.IDLE


func _update_idle(delta: float) -> void:
	direction = Vector2.ZERO
	velocity = Vector2.ZERO

	if patrol_wait_timer > 0.0:
		patrol_wait_timer -= delta
		return

	_advance_patrol_index()
	_refresh_nav_target_to_current_waypoint()
	state = State.PATROL


func _on_hurt():
	animated_sprite.play("hurt")


func _on_died():
	is_dead = true
	animated_sprite.play("death")


func _on_invulnerability_started():
	print("Enemy invulnerability started")


func _on_invulnerability_ended():
	print("Enemy invulnerability ended")
