extends CharacterBody2D

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var health_component: Node = $HealthComponent

var is_dead: bool = false
var last_direction: Vector2 = Vector2.DOWN
var direction: Vector2 = Vector2.ZERO

func _ready():
	health_component.died.connect(_on_died)
	health_component.hurt.connect(_on_hurt)
	health_component.invulnerability_started.connect(_on_invulnerability_started)
	health_component.invulnerability_ended.connect(_on_invulnerability_ended)

func _physics_process(_delta: float) -> void:
	if is_dead:
		return

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

func _on_hurt():
	animated_sprite.play("hurt")


func _on_died():
	is_dead = true
	animated_sprite.play("death")

func _on_invulnerability_started():
	print("Enemy invulnerability started")

func _on_invulnerability_ended():
	print("Enemy invulnerability ended")
