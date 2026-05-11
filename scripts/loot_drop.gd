class_name LootDrop
extends Area2D

signal picked_up(item: ItemData)

@export var item_data: ItemData

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _prompt: Label = $Label

var _player_nearby: bool = false

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_prompt.visible = false
	if item_data == null:
		return
	if item_data.icon:
		_sprite.texture = item_data.icon
	_prompt.text = "[E] %s" % item_data.display_name

func _unhandled_input(event: InputEvent) -> void:
	if not _player_nearby:
		return
	if event.is_action_pressed("action"):
		get_viewport().set_input_as_handled()
		picked_up.emit(item_data)
		queue_free()

func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		_player_nearby = true
		_prompt.visible = true

func _on_body_exited(body: Node2D) -> void:
	if body.is_in_group("player"):
		_player_nearby = false
		_prompt.visible = false
