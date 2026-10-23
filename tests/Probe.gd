extends Node
func _ready() -> void:
var G := load("res://scripts/core/GridManager.gd")
var gm = G.new()
add_child(gm)
gm.place_shape([Vector2i(0,1), Vector2i(0,2)], 0, 0, 1)
print("PROBE grid[0][1]=", gm.grid[0][1], " grid[1][0]=", gm.grid[1][0], " grid[2][0]=", gm.grid[2][0])
get_tree().quit()
