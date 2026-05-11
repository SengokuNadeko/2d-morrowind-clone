extends CharacterBody2D

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var melee_hitbox: Area2D = $MeleeHitbox
@onready var melee_hitbox_shape: CollisionShape2D = $MeleeHitbox/CollisionShape2D

const ATTACK_ACTIVE_FRAMES := {
	"slash_down": Vector2i(2, 3),
	"slash_left": Vector2i(2, 3),
	"slash_right": Vector2i(2, 3),
	"slash_up": Vector2i(2, 3),
}

const _HIT_FLASH_SHADER := preload("res://shaders/hit_flash.gdshader")

var last_direction: Vector2 = Vector2.DOWN
var direction: Vector2 = Vector2.ZERO
var knockback_velocity: Vector2 = Vector2.ZERO
@export var knockback_decay: float = 800.0

var current_attack_anim: String = ""
var attack_hitbox_active: bool = false
var attack_has_connected: bool = false

var _hit_flash_material: ShaderMaterial = null
var _flash_tween: Tween = null


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


func _movement_animation_blocked() -> bool:
	if not animated_sprite.is_playing():
		return false
	var n := String(animated_sprite.animation)
	return n == "hurt" or n.begins_with("slash_")


func update_animation() -> void:
	if _movement_animation_blocked():
		return

	var moving := direction != Vector2.ZERO
	var facing := direction if moving else last_direction
	var anim := ("walk_" if moving else "idle_") + _facing_suffix(facing)
	if animated_sprite.animation != anim or not animated_sprite.is_playing():
		animated_sprite.play(anim)


func _position_hitbox_for_suffix(suffix: String, dist: float) -> void:
	if suffix == "down":
		melee_hitbox_shape.rotation_degrees = 0.0
		melee_hitbox_shape.position = Vector2(0.0, dist)
	elif suffix == "left":
		melee_hitbox_shape.rotation_degrees = 90.0
		melee_hitbox_shape.position = Vector2(-dist, 0.0)
	elif suffix == "right":
		melee_hitbox_shape.rotation_degrees = 90.0
		melee_hitbox_shape.position = Vector2(dist, 0.0)
	elif suffix == "up":
		melee_hitbox_shape.rotation_degrees = 0.0
		melee_hitbox_shape.position = Vector2(0.0, -dist)


func _on_attack_frame_changed() -> void:
	var anim := String(animated_sprite.animation)
	if not anim.begins_with("slash_"):
		return

	var window: Vector2i = ATTACK_ACTIVE_FRAMES.get(anim, Vector2i(-1, -1))
	var frame := animated_sprite.frame
	var should_be_active := frame >= window.x and frame <= window.y

	if should_be_active != attack_hitbox_active:
		attack_hitbox_active = should_be_active
		melee_hitbox.monitoring = attack_hitbox_active
		if attack_hitbox_active:
			_on_hitbox_activated()


# Override in subclass to apply damage when the hitbox first becomes active.
func _on_hitbox_activated() -> void:
	pass


func _clear_attack_state() -> void:
	attack_hitbox_active = false
	melee_hitbox.monitoring = false
	current_attack_anim = ""


func _flash_on_hit() -> void:
	if _hit_flash_material == null:
		_hit_flash_material = ShaderMaterial.new()
		_hit_flash_material.shader = _HIT_FLASH_SHADER

	if _flash_tween and _flash_tween.is_valid():
		_flash_tween.kill()

	animated_sprite.material = _hit_flash_material
	_flash_tween = create_tween()
	for i in 3:
		_flash_tween.tween_method(
			func(v: float): _hit_flash_material.set_shader_parameter("flash_intensity", v),
			0.0, 1.0, 0.05
		)
		_flash_tween.tween_method(
			func(v: float): _hit_flash_material.set_shader_parameter("flash_intensity", v),
			1.0, 0.0, 0.05
		)
	_flash_tween.tween_callback(func(): animated_sprite.material = null)


func apply_knockback(impulse: Vector2) -> void:
	knockback_velocity = impulse
