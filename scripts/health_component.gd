extends Node

@export var max_health: int = 100
@export var current_health: int = 100

var is_dead: bool = false

signal health_changed(new_health: int)
signal hurt
signal died

func take_damage(amount: int) -> void:
	if is_dead:
		return
	current_health = maxi(current_health - amount, 0)
	health_changed.emit(current_health)
	if current_health <= 0:
		die()
	else:
		hurt.emit()


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
