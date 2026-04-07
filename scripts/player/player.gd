extends CharacterBody2D

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D

var SPEED = 200.0

var last_direction: Vector2 = Vector2.DOWN
var direction: Vector2 = Vector2.ZERO
var is_sprinting: bool = false

func _physics_process(_delta: float) -> void:
	player_movement()

	if get_slide_collision_count() > 0:
		var collision := get_slide_collision(0)
		print("Hit: ", collision.get_collider().name)


#Player movement function
func player_movement():
	if Input.is_action_just_pressed("sprint"):
		is_sprinting = !is_sprinting
	
	if(is_sprinting):
		SPEED = 300.0
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


func update_animation() -> void:
	var moving := direction != Vector2.ZERO
	var facing := direction if moving else last_direction
	var anim := ("walk_" if moving else "idle_") + _facing_suffix(facing)
	if animated_sprite.animation != anim:
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
