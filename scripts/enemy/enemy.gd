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

var patrol_origin: Vector2
var patrol_direction: Vector2 = Vector2.DOWN
var patrol_wait_timer: float = 0.0

var patrol_points: Array[Marker2D] = []
var patrol_index: int = 0

@export var patrol_speed: float = 60.0
@export var patrol_distance: float = 64.0
@export var patrol_wait_time: float = 1.0

@export var patrol_route_path: NodePath
@export var patrol_route_name: String = "PatrolRoute1"
@export var waypoint_reach_distance := 8.0
@export var patrol_mode_loop := true #may make enum later

func _ready():
	patrol_origin = global_position

	health_component.died.connect(_on_died)
	health_component.hurt.connect(_on_hurt)
	health_component.invulnerability_started.connect(_on_invulnerability_started)
	health_component.invulnerability_ended.connect(_on_invulnerability_ended)

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
	if patrol_wait_timer > 0.0:
		patrol_wait_timer -= delta
		velocity = Vector2.ZERO
		return
	
	velocity = patrol_direction * patrol_speed
	direction = patrol_direction
	move_and_slide()

	var offset := global_position - patrol_origin
	if offset.length() >= patrol_distance:
		patrol_direction = -patrol_direction
		patrol_wait_timer = patrol_wait_time
		state = State.IDLE

func _update_idle(delta: float) -> void:
	if patrol_wait_timer <= 0.0:
		state = State.PATROL
		return
	
	direction = Vector2.ZERO
	patrol_wait_timer -= delta

func _on_hurt():
	animated_sprite.play("hurt")

func _on_died():
	is_dead = true
	animated_sprite.play("death")

func _on_invulnerability_started():
	print("Enemy invulnerability started")

func _on_invulnerability_ended():
	print("Enemy invulnerability ended")
