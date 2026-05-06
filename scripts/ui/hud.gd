extends Control

@onready var health_bar: ProgressBar = $HealthBar

var player_health_component: Node

func _ready():
	var player := get_tree().get_first_node_in_group("player")
	if player == null:
		push_error("HUD: player not found in 'player' group")
		return
	player_health_component = player.get_node("HealthComponent")
	health_bar.max_value = player_health_component.max_health
	health_bar.value = player_health_component.current_health
	player_health_component.health_changed.connect(_on_health_changed)

func _on_health_changed(new_health: int):
	health_bar.value = new_health
