extends Node
# ============================================================================
# TestRunner.gd — headless smoke test for GridManager + GameManager wiring.
# Run: godot --headless --path . res://tests/TestRunner.tscn
# (assert() is stripped in release templates; this scene is dev-only.)
# ============================================================================

const GridScript := preload("res://scripts/core/GridManager.gd")

var _failures: int = 0

func _ready() -> void:
	var gm: Node = GridScript.new()
	add_child(gm)
	GameManager.start_game()

	# --- Placement / overlap ---------------------------------------------------
	var line3 := [Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2)]
	_check(gm.can_place_shape(line3, 0, 0), "empty board accepts piece")
	gm.place_shape(line3, 0, 0, 1)
	_check(not gm.can_place_shape(line3, 0, 0), "overlap rejected")
	_check(gm.grid[0][1] == 1, "cell written to grid")
	_check(not gm.can_place_shape(line3, 7, 6), "out-of-bounds rejected")

	# --- Single row clear --------------------------------------------------------
	for c in range(3, 8):
		gm.place_shape([Vector2i(0, c)], 0, c, 1)
	var sig := {"count": -1, "rows": [], "cols": []}
	gm.lines_cleared.connect(func(rows, cols, count):
		sig["count"] = count
		sig["rows"] = rows
		sig["cols"] = cols)
	gm.check_and_clear_lines()
	_check(sig["count"] == 8, "row clear counted 8 cells")
	_check(sig["rows"] == [0], "detected full row 0")
	_check(sig["cols"].is_empty(), "no spurious column clear")
	_check(gm.grid[0][0] == gm.EMPTY, "row emptied after clear")

	# --- Intersecting row+col (double-count guard) -------------------------------
	for c in 8:
		gm.place_shape([Vector2i(3, c)], 3, c, 2)
	for r in 8:
		if gm.grid[r][3] == gm.EMPTY:
			gm.place_shape([Vector2i(r, 3)], r, 3, 2)
	sig = {"count": -1, "rows": [], "cols": []}
	gm.check_and_clear_lines()
	# Row 3 (8 cells) + Col 3 (7 remaining cells, intersection already gone).
	_check(sig["rows"] == [3] and sig["cols"] == [3], "row+col detected together")
	_check(sig["count"] == 15, "intersection not double-counted (got %d)" % sig["count"])
	_check(gm.grid[3][3] == gm.EMPTY, "intersection cell empty")

	# --- Scoring through GameManager --------------------------------------------
	GameManager.add_placement_score(4)
	_check(GameManager.score == 4, "placement score applied")
	GameManager.add_line_clear_score(1, 8)
	_check(GameManager.score > 4, "line-clear score applied")

	# --- Game-over detection ------------------------------------------------------
	var big: Array = []
	for r in 4:
		for c in 4:
			big.append(Vector2i(r, c))
	for r in 8:
		for c in 8:
			gm.grid[r][c] = 1
	# Wire the game-over signal like the real Game scene bootstrap would.
	gm.no_moves_remaining.connect(GameManager.on_game_over)
	_check(not gm.has_any_valid_move([big]), "full board => no valid moves")
	_check(GameManager.state == GameManager.GameState.GAME_OVER,
		"GameManager transitioned via on_game_over path")

	if _failures == 0:
		print("ALL GRID/STATE TESTS PASSED")
	else:
		printerr("%d TEST(S) FAILED" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> void:
	if not cond:
		_failures += 1
		printerr("FAIL: " + label)
	else:
		print("ok: " + label)
