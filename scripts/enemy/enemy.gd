extends "res://scripts/character_base.gd"

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

const SUSPICION_METER_SCENE := preload("res://scenes/ui/suspicion_meter.tscn")
var _suspicion_meter: Node2D

var _player: CharacterBody2D = null

# True spawn position — captured once in _ready, never updated. Used for leash_radius.
var _leash_origin: Vector2 = Vector2.ZERO

# While chasing: counts down only when the player is outside lose_radius (with optional LOS).
# When it hits zero, we give up and resume the patrol route.
var _chase_interest_timer: float = 0.0

var state: State = State.PATROL
var is_dead: bool = false

# Seconds left standing at a waypoint before moving to the next.
var patrol_wait_timer: float = 0.0

# Marker2D children of the map's patrol route node, in visit order.
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
## 0 = no leash. When > 0, chase ends if the enemy moves farther than this from spawn.
@export var leash_radius: float = 0.0
@export var use_line_of_sight: bool = false
## Max distance used by LOS cone checks (separate from detection/lose radii).
@export var line_of_sight_radius: float = 220.0
## Total cone angle in degrees (e.g. 90 means 45 degrees left and right of facing).
@export var line_of_sight_fov_degrees: float = 90.0

## Assign in the editor to the map's route node (e.g. PatrolRoute1). If empty, falls back to patrol_route_name under the parent.
@export var patrol_route_path: NodePath
@export var patrol_route_name: String = "PatrolRoute1"
@export var waypoint_reach_distance := 8.0
## true: A→B→C→D→A…  false: A→B→C→D→C→B→A…
@export var patrol_mode_loop := true

@export var suspicion_max := 100.0
@export var suspicion_decay_per_sec := 8.0
@export var suspicion_gain_far_per_sec := 8.0
@export var suspicion_gain_near_per_sec := 40.0
@export var near_distance := 32.0
@export var damage_suspicion_bonus := 100.0
@export var instant_chase_on_damage := false

@export var attack_range: float = 28.0
@export var attack_damage: int = 10
@export var attack_cooldown: float = 0.8
@export var hitbox_distance: float = 22.0

var attack_cooldown_left: float = 0.0
var _suspicion: float = 0.0

func _ready() -> void:
	debug_vision.visible = debug_mode

	_suspicion_meter = SUSPICION_METER_SCENE.instantiate()
	var root := get_tree().current_scene
	if root != null:
		root.call_deferred("add_child", _suspicion_meter)
	else:
		get_tree().root.call_deferred("add_child", _suspicion_meter)
	_suspicion_meter.target = self

	_leash_origin = global_position

	if _player == null or not is_instance_valid(_player):
		_resolve_player()

	health_component.died.connect(_on_died)
	health_component.hurt.connect(_on_hurt)

	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_attack_frame_changed)
	melee_hitbox.area_entered.connect(_on_melee_hitbox_area_entered)
	melee_hitbox.body_entered.connect(_on_melee_hitbox_body_entered)
	melee_hitbox.monitoring = false

	var route := _resolve_patrol_route()
	patrol_points.clear()
	if route:
		for child in route.get_children():
			if child is Marker2D:
				patrol_points.append(child)
		# Sort by node name so A,B,C,D order is stable regardless of scene-tree order.
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


# Editor path wins; otherwise look for patrol_route_name on the same parent as this enemy.
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

	attack_cooldown_left = maxf(attack_cooldown_left - _delta, 0.0)

	match state:
		State.PATROL:
			_update_patrol_idle_perception(_delta)
			if state == State.PATROL:
				_update_patrol(_delta)
		State.IDLE:
			_update_patrol_idle_perception(_delta)
			if state == State.IDLE:
				_update_idle(_delta)
		State.CHASE:
			_update_chase(_delta)
		State.ATTACK:
			_update_attack(_delta)

	if direction:
		last_direction = direction

	if debug_vision != null:
		var facing := direction if direction != Vector2.ZERO else last_direction
		debug_vision.rotation = facing.angle()

	knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, knockback_decay * _delta)
	velocity += knockback_velocity
	move_and_slide()
	update_animation()


func update_animation() -> void:
	if _movement_animation_blocked():
		return
	if is_dead:
		return
	super.update_animation()


func _update_patrol(delta: float) -> void:
	if patrol_points.is_empty():
		velocity = Vector2.ZERO
		direction = Vector2.ZERO
		return

	if patrol_wait_timer > 0.0:
		patrol_wait_timer -= delta
		velocity = Vector2.ZERO
		direction = Vector2.ZERO
		_refresh_nav_target_to_current_waypoint()
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

func _update_patrol_idle_perception(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_resolve_player()
	if _player == null or not is_instance_valid(_player):
		return

	var detectable := _is_player_detectable()
	if detectable:
		var dist := global_position.distance_to(_player.global_position)
		var active_radius := line_of_sight_radius if use_line_of_sight else detection_radius
		var gain_rate := _suspicion_gain_rate_for_distance(dist, active_radius)
		_set_suspicion(_suspicion + gain_rate * delta)
	else:
		_set_suspicion(_suspicion - suspicion_decay_per_sec * delta)

	if _suspicion >= suspicion_max:
		state = State.CHASE
		_chase_interest_timer = chase_memory_seconds if chase_memory_seconds > 0.0 else INF


func _update_chase(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_resolve_player()
	if _player == null or not is_instance_valid(_player):
		_return_to_patrol()
		return

	if leash_radius > 0.0 and global_position.distance_squared_to(_leash_origin) > leash_radius * leash_radius:
		_return_to_patrol()
		return

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

	var to_player_now := _player.global_position - global_position
	if _is_player_within_attack_trigger(to_player_now) and attack_cooldown_left <= 0.0:
		_start_attack()
		return

	direction = dir
	velocity = dir * chase_speed

	var in_lose := false
	if use_line_of_sight:
		var los_keep_radius := maxf(lose_radius, line_of_sight_radius)
		in_lose = _can_see_player_in_cone(los_keep_radius)
	else:
		in_lose = global_position.distance_squared_to(_player.global_position) <= lose_radius * lose_radius

	if in_lose:
		_chase_interest_timer = chase_memory_seconds if chase_memory_seconds > 0.0 else INF
	else:
		_chase_interest_timer -= delta

	if _chase_interest_timer <= 0.0:
		_return_to_patrol()

func _start_attack() -> void:
	state = State.ATTACK
	velocity = Vector2.ZERO
	direction = Vector2.ZERO

	var to_player := _player.global_position - global_position
	last_direction = _cardinal_from_vector(to_player)

	var suffix := _facing_suffix(last_direction)
	current_attack_anim = "slash_" + suffix
	attack_has_connected = false
	attack_hitbox_active = false
	melee_hitbox.monitoring = false

	_position_hitbox_for_suffix(suffix, hitbox_distance)
	animated_sprite.play(current_attack_anim)
	attack_cooldown_left = attack_cooldown


func _update_attack(_delta: float) -> void:
	var anim := String(animated_sprite.animation)
	if not anim.begins_with("slash_"):
		if debug_mode:
			print("Enemy attack interrupted by animation '", anim, "' -> CHASE")
		state = State.CHASE
		return

	velocity = Vector2.ZERO
	direction = Vector2.ZERO


func _cardinal_from_vector(v: Vector2) -> Vector2:
	if v.length_squared() == 0.0:
		return last_direction if last_direction.length_squared() > 0.0 else Vector2.DOWN
	if absf(v.x) > absf(v.y):
		return Vector2(signf(v.x), 0.0)
	return Vector2(0.0, signf(v.y))


func _is_player_within_attack_trigger(to_player: Vector2) -> bool:
	# Player and enemy body shapes are taller than wide, so N/S contact distance differs from E/W.
	# attack_range is extra reach beyond body contact.
	var body_half_w := 10.0
	var body_half_h := 16.0
	var trigger_x := body_half_w + body_half_w + attack_range
	var trigger_y := body_half_h + body_half_h + attack_range
	return absf(to_player.x) <= trigger_x and absf(to_player.y) <= trigger_y


func _on_hitbox_activated() -> void:
	_try_apply_damage_from_current_overlaps()


func _on_animation_finished() -> void:
	var anim := String(animated_sprite.animation)
	if anim == "death":
		if is_instance_valid(_suspicion_meter):
			_suspicion_meter.queue_free()
		queue_free()
		return

	if anim == "hurt":
		if _player != null and is_instance_valid(_player):
			if debug_mode:
				print("Enemy hurt finished -> CHASE")
			state = State.CHASE
		else:
			if debug_mode:
				print("Enemy hurt finished -> return to patrol")
			_return_to_patrol()
		return

	if not anim.begins_with("slash_"):
		return

	_clear_attack_state()

	if state == State.ATTACK:
		state = State.CHASE


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
	q.collide_with_areas = false
	q.collide_with_bodies = true
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return true
	var collider: Object = hit.get("collider", null)
	if collider == _player:
		return true
	if collider is Node:
		var n := collider as Node
		if n.is_in_group("player"):
			return true
		if n.get_parent() == _player:
			return true
	return false


func _can_see_player_in_cone(radius: float) -> bool:
	if _player == null or not is_instance_valid(_player):
		return false
	if radius <= 0.0:
		return false

	var to_player := _player.global_position - global_position
	if to_player.length_squared() > radius * radius:
		return false

	var facing := direction if direction.length_squared() > 0.0 else last_direction
	if facing.length_squared() == 0.0:
		facing = Vector2.DOWN
	facing = facing.normalized()

	var dir_to_player := to_player.normalized()
	var half_fov_rad := deg_to_rad(clampf(line_of_sight_fov_degrees, 0.0, 360.0) * 0.5)
	var min_dot := cos(half_fov_rad)
	if facing.dot(dir_to_player) < min_dot:
		return false

	return _has_line_of_sight_to_player()


func _resolve_player() -> void:
	_player = get_tree().get_first_node_in_group("player")


func _suspicion_gain_rate_for_distance(distance: float, radius: float) -> float:
	var t := clampf(1.0 - (distance / radius), 0.0, 1.0)
	return lerpf(suspicion_gain_far_per_sec, suspicion_gain_near_per_sec, t)

func _is_player_detectable() -> bool:
	if _player == null or not is_instance_valid(_player):
		_resolve_player()
	if _player == null or not is_instance_valid(_player):
		return false
	if use_line_of_sight:
		return _can_see_player_in_cone(line_of_sight_radius)
	return global_position.distance_squared_to(_player.global_position) <= detection_radius * detection_radius


func _try_apply_damage_from_current_overlaps() -> void:
	if attack_has_connected:
		return

	for area in melee_hitbox.get_overlapping_areas():
		if not (area is Area2D):
			continue
		var target := _resolve_player_from_area(area as Area2D)
		if target == null:
			continue
		var health := target.get_node_or_null("HealthComponent")
		if health and health.has_method("take_damage"):
			health.take_damage(attack_damage)
			var kb_dir: Vector2 = (target.global_position - global_position).normalized()
			if target.has_method("apply_knockback"):
				target.apply_knockback(kb_dir * 200.0)
			attack_has_connected = true
			return

	for body in melee_hitbox.get_overlapping_bodies():
		if not (body is Node2D):
			continue
		var n := body as Node2D
		if not n.is_in_group("player"):
			continue
		var health := n.get_node_or_null("HealthComponent")
		if health and health.has_method("take_damage"):
			health.take_damage(attack_damage)
			var kb_dir: Vector2 = (n.global_position - global_position).normalized()
			if n.has_method("apply_knockback"):
				n.apply_knockback(kb_dir * 200.0)
			attack_has_connected = true
			return

func _on_melee_hitbox_area_entered(area: Area2D) -> void:
	if attack_has_connected:
		return
	var target := _resolve_player_from_area(area)
	if target == null:
		return

	var health := target.get_node_or_null("HealthComponent")
	if health and health.has_method("take_damage"):
		health.take_damage(attack_damage)
		var kb_dir: Vector2 = (target.global_position - global_position).normalized()
		if target.has_method("apply_knockback"):
			target.apply_knockback(kb_dir * 200.0)
		attack_has_connected = true

func _on_melee_hitbox_body_entered(body: Node2D) -> void:
	if attack_has_connected:
		return
	if not body.is_in_group("player"):
		return

	var health := body.get_node_or_null("HealthComponent")
	if health and health.has_method("take_damage"):
		health.take_damage(attack_damage)
		var kb_dir: Vector2 = (body.global_position - global_position).normalized()
		if body.has_method("apply_knockback"):
			body.apply_knockback(kb_dir * 200.0)
		attack_has_connected = true


func _resolve_player_from_area(area: Area2D) -> Node2D:
	if area == null:
		return null
	if area.is_in_group("player"):
		return area
	var p := area.get_parent()
	if p is Node2D and p.is_in_group("player"):
		return p as Node2D
	return null

func _set_suspicion(value: float) -> void:
	_suspicion = clampf(value, 0.0, suspicion_max)
	if is_instance_valid(_suspicion_meter) and _suspicion_meter.is_inside_tree():
		_suspicion_meter.set_percent(_suspicion / suspicion_max)


func _on_hurt():
	if state == State.ATTACK:
		_clear_attack_state()
		if debug_mode:
			print("Enemy hurt while attacking -> cancel ATTACK, switch to CHASE")
		state = State.CHASE

	animated_sprite.play("hurt")
	_flash_on_hit()
	_set_suspicion(_suspicion + damage_suspicion_bonus)

	if instant_chase_on_damage and state != State.CHASE:
		state = State.CHASE
		_chase_interest_timer = chase_memory_seconds if chase_memory_seconds > 0.0 else INF


func _on_died():
	is_dead = true
	animated_sprite.play("death")
