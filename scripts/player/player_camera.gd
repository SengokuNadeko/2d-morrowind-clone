extends Camera2D

func _ready() -> void:
	var ground := _find_ground_layer()
	if ground == null or ground.tile_set == null:
		return
	var used := ground.get_used_rect()
	if used.size.x < 1 or used.size.y < 1:
		return
	var min_cell := used.position
	var max_cell := used.position + used.size - Vector2i(1, 1)
	var tile_size := Vector2(ground.tile_set.tile_size)
	var top_left_global := ground.to_global(ground.map_to_local(min_cell) - tile_size / 2)
	var bottom_right_global := ground.to_global(ground.map_to_local(max_cell) + tile_size / 2)
	limit_left = int(floor(top_left_global.x))
	limit_top = int(floor(top_left_global.y))
	limit_right = int(ceil(bottom_right_global.x))
	limit_bottom = int(ceil(bottom_right_global.y))
	limit_enabled = true


func _find_ground_layer() -> TileMapLayer:
	var root := get_tree().current_scene
	if root == null:
		return null
	var found := root.find_child("Ground", true, false)
	if found is TileMapLayer:
		return found as TileMapLayer
	return null
