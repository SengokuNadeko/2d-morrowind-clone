extends CharacterBody2D

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var melee_hitbox: Area2D = $MeleeHitbox
@onready var melee_hitbox_shape: CollisionShape2D = $MeleeHitbox/CollisionShape2D
@onready var attack_cooldown_timer: Timer = $AttackCooldownTimer
@onready var health_component: Node = $HealthComponent

var SPEED = 200.0
var HITBOX_DISTANCE = 32.0

var last_direction: Vector2 = Vector2.DOWN
var direction: Vector2 = Vector2.ZERO
var is_sprinting: bool = false
var is_dead: bool = false

func _ready():
	health_component.died.connect(_on_died)
	health_component.hurt.connect(_on_hurt)
	health_component.invulnerability_started.connect(_on_invulnerability_started)
	health_component.invulnerability_ended.connect(_on_invulnerability_ended)
	animated_sprite.animation_finished.connect(_on_animation_finished)
	melee_hitbox.area_entered.connect(_on_melee_hitbox_area_entered)

func _physics_process(_delta: float) -> void:
	if is_dead:
		return

	if Input.is_action_just_pressed("test_hurt_and_death"):
		health_component.take_damage(10)
		print("Health: ", health_component.current_health)

	player_movement()
	player_attack()

	if get_slide_collision_count() > 0:
		var collision := get_slide_collision(0)
		print("Hit: ", collision.get_collider().name)
	
	if not attack_cooldown_timer.is_stopped():
		print("Attack cooldown: ", attack_cooldown_timer.time_left)


#Player movement function
func player_movement():
	if is_dead:
		return
	if Input.is_action_just_pressed("sprint"):
		is_sprinting = !is_sprinting

	if is_sprinting:
		SPEED = 300.0
		var anim_name := String(animated_sprite.animation)
		if anim_name.begins_with("slash_"):
			animated_sprite.speed_scale = 1.0
		else:
			animated_sprite.speed_scale = 2.0
	else:
		SPEED = 200.0
		animated_sprite.speed_scale = 1.0

	direction = Input.get_vector("move_left", "move_right", "move_up", "move_down").normalized()

	if direction:
		velocity = direction * SPEED
		last_direction = direction
	else:
		velocity = Vector2.ZERO
		animated_sprite.speed_scale = 1.0

	move_and_slide()
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


func player_attack():
	if not Input.is_action_just_pressed("attack"):
		return
	if not attack_cooldown_timer.is_stopped():
		return
	var anim_name := String(animated_sprite.animation)
	var suffix := ""
	if anim_name.begins_with("idle_"):
		suffix = anim_name.substr("idle_".length())
	elif anim_name.begins_with("walk_"):
		suffix = anim_name.substr("walk_".length())
	if suffix.is_empty():
		return
	animated_sprite.play("slash_" + suffix)
	if suffix == "down":
		melee_hitbox_shape.rotation_degrees = 0.0
		melee_hitbox_shape.position.x = 0.0
		melee_hitbox_shape.position.y = HITBOX_DISTANCE
		print("Hitbox rotation: ", melee_hitbox_shape.rotation)
	elif suffix == "left":
		melee_hitbox_shape.rotation_degrees = 90.0
		melee_hitbox_shape.position.x = -HITBOX_DISTANCE
		melee_hitbox_shape.position.y = 0.0
		print("Hitbox rotation: ", melee_hitbox_shape.rotation)
	elif suffix == "right":
		melee_hitbox_shape.rotation_degrees = -90.0
		melee_hitbox_shape.position.x = HITBOX_DISTANCE
		melee_hitbox_shape.position.y = 0.0
		print("Hitbox rotation: ", melee_hitbox_shape.rotation)
	elif suffix == "up":
		melee_hitbox_shape.rotation_degrees = 0.0
		melee_hitbox_shape.position.x = 0.0
		melee_hitbox_shape.position.y = -HITBOX_DISTANCE
		print("Hitbox rotation: ", melee_hitbox_shape.rotation)
	melee_hitbox.monitoring = true
	
	var duration := _get_animation_duration("slash_" + suffix)
	attack_cooldown_timer.wait_time = max(duration, 0.01)
	attack_cooldown_timer.start()

func _on_melee_hitbox_area_entered(area: Area2D):
	var enemy = area.get_parent()
	if not enemy or not enemy.is_in_group("enemy"):
		return
	
	var health = enemy.get_node_or_null("HealthComponent")
	if health and health.has_method("take_damage"):
		health.take_damage(10)

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


func _on_animation_finished() -> void:
	var anim_name := String(animated_sprite.animation)
	if not anim_name.begins_with("slash_"):
		return
	var suffix := anim_name.substr("slash_".length())
	melee_hitbox.monitoring = false
	animated_sprite.play("idle_" + suffix)


func _on_hurt():
	animated_sprite.play("hurt")


func _on_died():
	is_dead = true
	animated_sprite.play("death")

func _on_invulnerability_started():
	print("Player invulnerability started")

func _on_invulnerability_ended():
	print("Player invulnerability ended")

func _get_animation_duration(anim_name: String) -> float:
	var frames := animated_sprite.sprite_frames
	if frames == null or not frames.has_animation(anim_name):
		return 0.0
	
	var frame_count := frames.get_frame_count(anim_name)
	if frame_count <= 0:
		return 0.0
	
	var total := 0.0
	for i in frame_count:
		total += frames.get_frame_duration(anim_name, i)
	
	var fps := frames.get_animation_speed(anim_name)
	if fps <= 0.0:
		return 0.0
	
	return total / (fps * max(animated_sprite.speed_scale, 0.001))
