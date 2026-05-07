extends "res://scripts/character_base.gd"

@onready var attack_cooldown_timer: Timer = $AttackCooldownTimer
@onready var health_component: Node = $HealthComponent

@export var attack_damage: int = 10

var speed := 200.0
var hitbox_distance := 32.0

var is_sprinting: bool = false
var is_dead: bool = false


func _ready():
	add_to_group("player")

	health_component.died.connect(_on_died)
	health_component.hurt.connect(_on_hurt)
	animated_sprite.animation_finished.connect(_on_animation_finished)
	animated_sprite.frame_changed.connect(_on_attack_frame_changed)
	melee_hitbox.area_entered.connect(_on_melee_hitbox_area_entered)

func _physics_process(_delta: float) -> void:
	if is_dead:
		return

	if Input.is_action_just_pressed("test_hurt_and_death"):
		health_component.take_damage(10)

	player_movement()
	player_attack()

func player_movement():
	if is_dead:
		return
	if Input.is_action_just_pressed("sprint"):
		is_sprinting = !is_sprinting

	if is_sprinting:
		speed = 300.0
		var anim_name := String(animated_sprite.animation)
		animated_sprite.speed_scale = 1.0 if anim_name.begins_with("slash_") else 2.0
	else:
		speed = 200.0
		animated_sprite.speed_scale = 1.0

	direction = Input.get_vector("move_left", "move_right", "move_up", "move_down").normalized()

	if direction:
		velocity = direction * speed
		last_direction = direction
	else:
		velocity = Vector2.ZERO
		animated_sprite.speed_scale = 1.0

	move_and_slide()
	update_animation()


func update_animation() -> void:
	if _movement_animation_blocked():
		return
	if is_dead:
		return
	super.update_animation()


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

	current_attack_anim = "slash_" + suffix
	attack_has_connected = false
	attack_hitbox_active = false
	melee_hitbox.monitoring = false

	animated_sprite.play(current_attack_anim)
	_position_hitbox_for_suffix(suffix, hitbox_distance)

	var duration := _get_animation_duration("slash_" + suffix)
	attack_cooldown_timer.wait_time = max(duration, 0.01)
	attack_cooldown_timer.start()


func _on_hitbox_activated() -> void:
	_try_apply_damage_from_current_overlaps()


func _try_apply_damage_from_current_overlaps() -> void:
	if attack_has_connected:
		return
	for area in melee_hitbox.get_overlapping_areas():
		if not (area is Area2D):
			continue
		var enemy = area.get_parent()
		if not enemy or not enemy.is_in_group("enemy"):
			continue
		var health = enemy.get_node_or_null("HealthComponent")
		if health and health.has_method("take_damage"):
			health.take_damage(attack_damage)
			attack_has_connected = true
			return


func _on_melee_hitbox_area_entered(area: Area2D):
	if attack_has_connected:
		return
	var enemy = area.get_parent()
	if not enemy or not enemy.is_in_group("enemy"):
		return

	var health = enemy.get_node_or_null("HealthComponent")
	if health and health.has_method("take_damage"):
		health.take_damage(attack_damage)
		attack_has_connected = true


func _on_animation_finished() -> void:
	var anim_name := String(animated_sprite.animation)

	if anim_name == "death":
		_on_death_animation_finished()
		return

	if anim_name == "hurt":
		update_animation()
		return

	if not anim_name.begins_with("slash_"):
		return
	var suffix := anim_name.substr("slash_".length())

	_clear_attack_state()
	animated_sprite.play("idle_" + suffix)


func _on_death_animation_finished() -> void:
	await get_tree().create_timer(1.5).timeout
	get_tree().reload_current_scene()


func _on_hurt():
	animated_sprite.play("hurt")
	$Camera2D.add_shake(5.0)
	_flash_on_hit()


func _on_died():
	is_dead = true
	animated_sprite.play("death")


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
