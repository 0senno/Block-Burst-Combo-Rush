extends Node
func _ready() -> void:
	var G := load("res://scripts/core/GridManager.gd")
	print("HAS PLACE: ", G.has_method("place_shape"))
	print("HAS CANPLACE: ", G.has_method("can_place_shape"))
	var gm = G.new()
	add_child(gm)
	gm.place_shape([Vector2i(0,0), Vector2i(0,1)], 5, 2, 7)
	print("grid[5][2]=", gm.grid[5][2], " grid[5][3]=", gm.grid[5][3], " grid[6][2]=", gm.grid[6][2])
	get_tree().quit()
