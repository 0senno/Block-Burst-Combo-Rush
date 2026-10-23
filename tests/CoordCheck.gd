extends Node
func _ready() -> void:
var gm = load("res://scripts/core/GridManager.gd").new()
add_child(gm)
# Horizontal 1x3 piece at row 5, cols 2..4 using (row,col) offsets.
var cells := [Vector2i(0,0), Vector2i(0,1), Vector2i(0,2)]
gm.place_shape(cells, 5, 2, 7)
print("grid[5][2]=", gm.grid[5][2], " grid[5][3]=", gm.grid[5][3], " grid[5][4]=", gm.grid[5][4])
print("grid[6][2]=", gm.grid[6][2], " grid[7][4]=", gm.grid[7][4])
get_tree().quit()
