extends Node

const DamageNumber = preload("res://scenes/ui/damage_number.tscn")

@export var max_health: int = 100
@export var current_health: int = 100
@export var invulnerability_duration: float = 1.0
@export var damage_number_color: Color = Color.RED


var is_dead: bool = false
var is_invulnerable: bool = false
var invulnerability_timer: float = 0.0

signal health_changed(new_health: int)
signal hurt
signal died
signal invulnerability_started
signal invulnerability_ended

func _process(delta: float) -> void:
	if not is_invulnerable:
		return
	invulnerability_timer -= delta
	if invulnerability_timer <= 0.0:
		is_invulnerable = false
		invulnerability_timer = 0.0
		invulnerability_ended.emit()

func take_damage(amount: int) -> void:
	if is_dead or is_invulnerable:
		return
	
	current_health = maxi(current_health - amount, 0)
	health_changed.emit(current_health)
	
	_spawn_damage_number(amount)

	if current_health > 0:
		is_invulnerable = true
		invulnerability_timer = invulnerability_duration
		hurt.emit()
		invulnerability_started.emit()
	else:
		die()


func _spawn_damage_number(amount: int) -> void:
	var parent = get_parent()
	if not parent is Node2D:
		return
	var label = DamageNumber.instantiate()
	get_tree().current_scene.add_child(label)
	label.global_position = parent.global_position
	label.setup(amount, damage_number_color)


func heal(amount: int) -> void:
	if is_dead:
		return
	current_health += amount
	if current_health > max_health:
		current_health = max_health
	health_changed.emit(current_health)


func die() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()
