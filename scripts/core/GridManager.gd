# ============================================================================
# GridManager.gd
# ----------------------------------------------------------------------------
# Pure-logic manager for the 8x8 block-puzzle board.
#
# DESIGN PRINCIPLES
#   - NO Node2D / drawing work here. This script is deliberately rendering-free
#     so it can be unit-tested and reused. The view layer (a separate scene)
#     subscribes to its signals and renders via ONE MultiMeshInstance2D or a
#     single CanvasItem `_draw()` pass -> minimal draw calls on mobile GPUs.
#   - Board state lives in a clean 2D array: `Array[Array[int]]` where each
#     cell is either EMPTY (0) or an opaque color id (>0). Using ints instead
#     of objects keeps allocations near zero during gameplay.
#   - All public queries (`can_place_shape`, `has_any_valid_move`) are O(cells
#     in shape) / O(board * shapes) — trivially fast for 64 cells.
#
# COORDINATE CONVENTION
#   - Column-major NOT used; we use `grid[row][col]` consistently.
#   - Shapes are described by a list of Vector2i offsets relative to their
#     top-left bounding cell, e.g. an L-shape = [(0,0),(1,0),(2,0),(2,1)].
# ============================================================================
extends Node

# ---------------------------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------------------------
const GRID_SIZE := 8                 # 8x8 board
const EMPTY := 0                     # cell value meaning "no block"

# ---------------------------------------------------------------------------
# SIGNALS — the renderer/UI listens; logic never reaches back into nodes
# ---------------------------------------------------------------------------
signal cell_changed(row: int, col: int, value: int)          # single update
signal shape_placed(origin_row: int, origin_col: int, color_id: int)
signal lines_cleared(rows: Array[int], cols: Array[int], cleared_cell_count: int)
signal board_changed()                                        # bulk refresh hint
signal no_moves_remaining()                                   # -> GameManager.on_game_over()

# ---------------------------------------------------------------------------
# STATE
# ---------------------------------------------------------------------------
## 2D array of ints: grid[row][col]. Built once in _ready(); mutated in place.
var grid: Array = []

func _ready() -> void:
	reset_board()

# ---------------------------------------------------------------------------
# BOARD LIFECYCLE
# ---------------------------------------------------------------------------

## Rebuilds an all-empty 8x8 grid. Allocates exactly GRID_SIZE rows once.
func reset_board() -> void:
	grid.clear()
	for r in GRID_SIZE:
		var row: Array = []
		row.resize(GRID_SIZE)
		row.fill(EMPTY)
		grid.append(row)
	board_changed.emit()

# ---------------------------------------------------------------------------
# QUERIES
# ---------------------------------------------------------------------------

## Bounds + occupancy check for one cell.
func is_cell_empty(row: int, col: int) -> bool:
	if row < 0 or row >= GRID_SIZE or col < 0 or col >= GRID_SIZE:
		return false
	return grid[row][col] == EMPTY


## Core placement test.
## `shape_cells`: Array[Vector2i] offsets where offset.x = COLUMN delta and
## offset.y = ROW delta (Godot's native x→right / y→down convention; do NOT
## confuse this with the (row,col) tuple used by every function signature).
## Returns true if EVERY offset lands inside the board AND on an empty cell.
## Cost: O(n) with n = cells in shape (max ~5), allocation-free.
func can_place_shape(shape_cells: Array, origin_row: int, origin_col: int) -> bool:
	for offset in shape_cells:
		var r: int = origin_row + offset.y
		var c: int = origin_col + offset.x
		# Inline bounds test (faster than calling is_cell_empty twice).
		if r < 0 or r >= GRID_SIZE or c < 0 or c >= GRID_SIZE:
			return false
		if grid[r][c] != EMPTY:
			return false
	return true


## Snapshot helper used by InputHandler for live drag previews: returns the
## snapped origin as Vector2i(row, col), clamped so the whole piece bounding
## box stays on the board.
## `piece_bounds` MUST be Vector2i(x = width in cells, y = height in cells) —
## i.e. Godot's natural x→width convention. Callers that store bounds as
## Vector2i(rows, cols) must transpose them before calling (see InputHandler).
## NOTE: `cell_offset_y` is reserved for future per-row visual offsets
## (e.g. perspective tilt); it currently defaults to 0.0.
func world_to_grid_clamped(world_pos: Vector2, cell_px: float,
		cell_offset_y: float, piece_bounds: Vector2i) -> Vector2i:
	assert(cell_px > 0.0, "world_to_grid_clamped: cell_px must be > 0")
	var raw_col := int(floor(world_pos.x / cell_px))
	var raw_row := int(floor((world_pos.y - cell_offset_y) / cell_px))
	# Clamp origins so the piece bounding box fits the board.
	# x (width) constrains columns; y (height) constrains rows.
	raw_col = clampi(raw_col, 0, GRID_SIZE - piece_bounds.x)
	raw_row = clampi(raw_row, 0, GRID_SIZE - piece_bounds.y)
	return Vector2i(raw_row, raw_col)

# ---------------------------------------------------------------------------
# MUTATIONS
# ---------------------------------------------------------------------------

## Writes the shape into the grid. Callers SHOULD have checked
## can_place_shape() first; we re-validate here defensively because an
## unchecked write would throw "Out of bounds" script errors on device
## (and silently corrupt the board if indices happened to land in range).
## Returns false (no mutation, no signals) when the placement is illegal.
## Emits per-cell updates (renderer batches them) + one bulk signal.
func place_shape(shape_cells: Array, origin_row: int, origin_col: int,
		color_id: int) -> bool:
	if not can_place_shape(shape_cells, origin_row, origin_col):
		return false
	# Same axis convention as can_place_shape: x = column delta, y = row delta.
	for offset in shape_cells:
		var r: int = origin_row + offset.y
		var c: int = origin_col + offset.x
		grid[r][c] = color_id
		cell_changed.emit(r, c, color_id)
	shape_placed.emit(origin_row, origin_col, color_id)
	board_changed.emit()
	return true


## Clears full rows/columns (Block-Blast rules: a line clears when ALL 8
## cells are occupied). Rows and columns are detected simultaneously BEFORE
## any clearing happens, so an intersecting row+col both clear in one drop.
## Returns [lines_count, cells_cleared] via signals for scoring.
func check_and_clear_lines() -> void:
	var full_rows: Array[int] = []
	var full_cols: Array[int] = []

	# --- Detect full rows -----------------------------------------------------
	for r in GRID_SIZE:
		var complete := true
		for c in GRID_SIZE:
			if grid[r][c] == EMPTY:
				complete = false
				break
		if complete:
			full_rows.append(r)

	# --- Detect full columns --------------------------------------------------
	for c in GRID_SIZE:
		var complete := true
		for r in GRID_SIZE:
			if grid[r][c] == EMPTY:
				complete = false
				break
		if complete:
			full_cols.append(c)

	var lines := full_rows.size() + full_cols.size()
	if lines == 0:
		return  # Nothing to clear — caller may register a "dry" placement.

	# --- Clear: union of full rows & cols (avoid double-counting intersections)
	var cleared_cells := 0
	for r in full_rows:
		for c in GRID_SIZE:
			if grid[r][c] != EMPTY:
				cleared_cells += 1
			grid[r][c] = EMPTY
			cell_changed.emit(r, c, EMPTY)

	for c in full_cols:
		for r in GRID_SIZE:
			# Row loop already emptied intersection cells; guard prevents
			# counting them twice.
			if grid[r][c] != EMPTY:
				cleared_cells += 1
				grid[r][c] = EMPTY
				cell_changed.emit(r, c, EMPTY)

	lines_cleared.emit(full_rows, full_cols, cleared_cells)
	board_changed.emit()

# ---------------------------------------------------------------------------
# GAME-OVER DETECTION
# ---------------------------------------------------------------------------

## True if at least one of the currently-offered pieces fits somewhere.
## `pieces`: Array of shape_cells arrays (the tray's 3 pieces).
## Worst case 3 * 64 * ~5 ops — still microseconds on mid-range phones.
func has_any_valid_move(pieces: Array) -> bool:
	for shape_cells in pieces:
		if can_place_anywhere(shape_cells):
			return true
	no_moves_remaining.emit()
	return false


## Brute-force scan of every origin for a single piece.
func can_place_anywhere(shape_cells: Array) -> bool:
	for r in GRID_SIZE:
		for c in GRID_SIZE:
			if can_place_shape(shape_cells, r, c):
				return true
	return false
