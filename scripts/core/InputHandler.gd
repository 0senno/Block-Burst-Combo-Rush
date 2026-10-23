# ============================================================================
# InputHandler.gd
# ----------------------------------------------------------------------------
# Touch/drag controller for picking pieces from the tray and dropping them on
# the 8x8 board. Attach to a Node2D that also holds (or references) the tray's
# piece visuals.
#
# MOBILE INPUT STRATEGY
#   - Uses `_unhandled_input()` so buttons/UI (which consume input via the
#     GUI layer first) never fight with gameplay dragging.
#   - Tracks ONLY ONE finger (`_active_touch`). Multi-touch is explicitly
#     ignored: hyper-casual block games are single-pointer, and ignoring extra
#     fingers prevents ghost drags when a palm rests on screen.
#   - Drag updates happen per-event (not per-frame) -> zero work while idle,
#     which keeps battery usage down on iOS/Android.
#   - A "lift offset" renders the dragged piece ABOVE the fingertip so the
#     finger doesn't occlude the snap preview (standard mobile UX).
#   - `emulate_touch_from_mouse` (project setting) lets one code path serve
#     both device touches and desktop-editor testing; mouse events below are
#     an extra convenience mapped onto the same handlers.
#
# SNAPPING
#   While dragging we continuously compute a clamped grid origin + validity
#   and emit `piece_dragged` for the renderer's green/red preview. On release
#   we recompute from the last known position, validate, then commit (via
#   GridManager + GameManager) or tween the piece back to its tray slot.
# ============================================================================
extends Node2D

# ---------------------------------------------------------------------------
# DEPENDENCIES (wired in the scene inspector or by the bootstrap script)
# ---------------------------------------------------------------------------
@export var grid_manager: Node = null   # GridManager instance
@export var piece_tray: Node = null     # PieceTray (see contract at file end)
@export var cell_size_px: float = 72.0      # board cell size, world pixels
@export var board_origin: Vector2 = Vector2.ZERO  # top-left of board, world pos
## Vertical gap between finger and held piece (fingertip occlusion fix).
@export var drag_lift_offset_px: float = 120.0
## Travel distance before a press becomes a drag (anti-jitter threshold, px).
@export var drag_threshold_px: float = 16.0

# ---------------------------------------------------------------------------
# SIGNALS — consumed by the PieceTray / BoardRenderer
# ---------------------------------------------------------------------------
signal piece_pick_started(piece_index: int)
signal piece_dragged(piece_index: int, board_preview_origin: Vector2i, is_valid: bool)
signal piece_dropped(piece_index: int, placed: bool)
signal piece_returned_to_tray(piece_index: int)

# ---------------------------------------------------------------------------
# INTERNAL STATE
# ---------------------------------------------------------------------------
enum DragState { IDLE, CANDIDATE, DRAGGING }

var _state: DragState = DragState.IDLE
var _active_touch: int = -1             # finger id we own (-1 == none)
var _held_index: int = -1               # tray slot currently grabbed
var _held_node: Node2D = null           # visual root of the held piece
var _held_cells: Array = []             # Array[Vector2i] offsets (cached ref)
var _piece_bounds: Vector2i = Vector2i.ONE  # bounding box in cells
var _tray_home: Vector2 = Vector2.ZERO  # where the piece returns if invalid
var _down_pos: Vector2 = Vector2.ZERO   # press position, for threshold check
var _last_pos: Vector2 = Vector2.ZERO   # most recent pointer position

func _ready() -> void:
	# _unhandled_input is enabled automatically because we implement it.
	assert(grid_manager != null, "InputHandler: grid_manager not assigned.")
	assert(piece_tray != null, "InputHandler: piece_tray not assigned.")

# ---------------------------------------------------------------------------
# PUBLIC API — called by the tray when it spawns/refreshes pieces
# ---------------------------------------------------------------------------

## Register a draggable piece so hit-testing knows about it. `root` is the
## Node2D whose children are the colored quads; `cells` are Vector2i (row,col)
## offsets; `bounds` is the bounding size in cells (e.g. Vector2i(3,2)).
func register_piece(index: int, root: Node2D, cells: Array, bounds: Vector2i) -> void:
	assert(root != null and not cells.is_empty(), "Invalid piece registration")
	piece_tray.register_piece(index, root, cells, bounds)

# ---------------------------------------------------------------------------
# CORE INPUT ENTRY POINT
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	# Ignore gameplay input unless we are actually playing (menu/game-over safe).
	if GameManager.state != GameManager.GameState.PLAYING:
		return

	# --- Normalize touch & mouse into ONE code path ---------------------------
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_on_pointer_down(st.index, st.position)
		else:
			_on_pointer_up(st.index)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		_on_pointer_move(sd.index, sd.position)
	elif event is InputEventMouseButton:
		# Desktop-editor testing parity: left mouse acts like a single touch.
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_on_pointer_down(-1, mb.position)
			else:
				_on_pointer_up(-1)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		_on_pointer_move(-1, (event as InputEventMouseMotion).position)

# ---------------------------------------------------------------------------
# POINTER HANDLERS
# ---------------------------------------------------------------------------

func _on_pointer_down(finger: int, screen_pos: Vector2) -> void:
	if _state != DragState.IDLE:
		return  # Already busy with another finger — ignore (anti-ghost-touch).

	# Which tray slot did we hit? Delegates hit-rect test to the pooled tray.
	var idx: int = piece_tray.find_piece_at(screen_pos)
	if idx < 0:
		return

	_active_touch = finger
	_state = DragState.CANDIDATE
	_down_pos = screen_pos
	_last_pos = screen_pos
	_held_index = idx
	_held_node = piece_tray.get_piece_node(idx)
	_held_cells = piece_tray.get_piece_cells(idx)
	_piece_bounds = piece_tray.get_piece_bounds(idx)
	_tray_home = _held_node.global_position


func _on_pointer_move(finger: int, screen_pos: Vector2) -> void:
	if finger != _active_touch or _held_index < 0:
		return  # Not our finger, or nothing held.

	_last_pos = screen_pos

	# Threshold: don't start dragging on a jittery tap-in-place.
	if _state == DragState.CANDIDATE:
		if screen_pos.distance_to(_down_pos) < drag_threshold_px:
			return
		_state = DragState.DRAGGING
		piece_pick_started.emit(_held_index)

	# Move the visual so its CENTER follows the finger, lifted upward so the
	# fingertip does not cover the piece.
	_held_node.global_position = (
		screen_pos - _piece_center_offset() - Vector2(0.0, drag_lift_offset_px)
	)

	# Live snap preview for the renderer (green = valid, red = blocked).
	var preview: Vector2i = _screen_to_grid_origin(screen_pos)
	var valid: bool = grid_manager.can_place_shape(_held_cells, preview.x, preview.y)
	piece_dragged.emit(_held_index, preview, valid)


func _on_pointer_up(finger: int) -> void:
	if finger != _active_touch:
		return  # A different finger lifted — leave our drag untouched.

	_active_touch = -1

	if _state == DragState.DRAGGING and _held_index >= 0:
		_commit_drop()
	elif _state == DragState.CANDIDATE and _held_index >= 0:
		# Tap without meaningful movement: put the piece back home.
		_return_to_tray()

	_reset_hold()


func _reset_hold() -> void:
	_state = DragState.IDLE
	_held_index = -1
	_held_node = null
	_held_cells = []
	_piece_bounds = Vector2i.ONE

# ---------------------------------------------------------------------------
# DROP RESOLUTION
# ---------------------------------------------------------------------------

func _commit_drop() -> void:
	var origin := _screen_to_grid_origin(_last_pos)
	var fits: bool = grid_manager.can_place_shape(_held_cells, origin.x, origin.y)

	if fits:
		# Commit order matters: place -> placement score -> line clear.
		# Line-clear scoring/combo is handled by whoever listens to
		# GridManager.lines_cleared (the Game scene bootstrap), keeping this
		# script free of economy rules.
		grid_manager.place_shape(_held_cells, origin.x, origin.y,
			piece_tray.get_piece_color(_held_index))
		GameManager.add_placement_score(_held_cells.size())
		grid_manager.check_and_clear_lines()  # emits lines_cleared (or nothing)
		piece_dropped.emit(_held_index, true)
		piece_tray.consume_slot(_held_index)  # recycle + maybe refill + game-over check
	else:
		piece_dropped.emit(_held_index, false)
		_return_to_tray()

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

## Convert the CURRENT SCREEN point into a CLAMPED grid origin (top-left cell)
## for the held piece, accounting for the lift offset so what the player sees
## floating above the finger is exactly what lands on the board.
func _screen_to_grid_origin(screen_pos: Vector2) -> Vector2i:
	# Where the piece's TOP-LEFT CELL actually is on screen right now.
	var piece_top_left := screen_pos - Vector2(0.0, drag_lift_offset_px)
	# Shift into board-local space, then let GridManager do the math+clamping.
	var local := piece_top_left - board_origin
	return grid_manager.world_to_grid_clamped(local, cell_size_px, 0.0, _piece_bounds)


func _piece_center_offset() -> Vector2:
	return Vector2(_piece_bounds) * cell_size_px * 0.5


func _return_to_tray() -> void:
	if _held_node:
		# Tween back instead of teleporting — feels premium, costs one node.
		var tw := _held_node.create_tween()
		tw.tween_property(_held_node, "global_position", _tray_home, 0.12) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	piece_returned_to_tray.emit(_held_index)

# ---------------------------------------------------------------------------
# PIECE TRAY CONTRACT (duck-typed interface expected on `piece_tray`)
# ---------------------------------------------------------------------------
# The tray implementation (object-pooled, 3 slots max) must provide:
#   find_piece_at(screen_pos: Vector2) -> int        # slot index or -1
#   get_piece_node(index: int) -> Node2D
#   get_piece_cells(index: int) -> Array             # Array[Vector2i]
#   get_piece_bounds(index: int) -> Vector2i
#   get_piece_color(index: int) -> int
#   consume_slot(index: int) -> void                 # recycle node, refill set,
#       # then call grid_manager.has_any_valid_move(current_pieces); if false
#       # -> GameManager.on_game_over()
# Keeping InputHandler dependent only on this small surface makes it trivially
# unit-testable with a mock tray.
