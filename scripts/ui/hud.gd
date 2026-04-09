extends Control

#Health Bar
@onready var health_bar: ProgressBar = $HealthBar

#Player's Health Component
@onready var player_health_component: Node = get_tree().get_first_node_in_group("player").get_node("HealthComponent")

func _ready():
	health_bar.max_value = player_health_component.max_health
	health_bar.value = player_health_component.current_health
	player_health_component.health_changed.connect(_on_health_changed)

func _on_health_changed(new_health: int):
	health_bar.value = new_health
