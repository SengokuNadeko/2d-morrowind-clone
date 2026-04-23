@tool
extends Node2D

@export var vision_radius: float = 220.0:
	set(value):
		vision_radius = value
		queue_redraw()

@export var fov_degrees: float = 90.0:
	set(value):
		fov_degrees = value
		queue_redraw()

@export var debug_color: Color = Color.YELLOW:
	set(value):
		debug_color = value
		queue_redraw()

func _draw() -> void:
	#Full vision radius ring
	draw_arc(Vector2.ZERO, vision_radius, 0.0, TAU, 64, debug_color, 2.0)

	#Cone rays centered on +X (rotate node to match facing if needed)
	var half := deg_to_rad(fov_degrees * 0.5)
	var left := Vector2.RIGHT.rotated(-half) * vision_radius
	var right := Vector2.RIGHT.rotated(half) * vision_radius

	draw_line(Vector2.ZERO, left, debug_color, 2.0)
	draw_line(Vector2.ZERO, right, debug_color, 2.0)
	draw_arc(Vector2.ZERO, vision_radius, -half, half, 32, debug_color, 2.0)
