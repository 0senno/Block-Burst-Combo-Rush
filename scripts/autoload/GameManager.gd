# ============================================================================
# GameManager.gd  (Autoload Singleton -> "GameManager")
# ----------------------------------------------------------------------------
# Central game-state machine + score tracker for the block puzzle game.
#
# RESPONSIBILITIES
#   - Own the global state: MENU -> PLAYING -> GAME_OVER (and PAUSED).
#   - Track current score / best score (persisted with ConfigFile).
#   - Act as the single "trigger point" for ad events, so gameplay code never
#     talks to an Ad SDK directly. Ads are reached through the `AdManager`
#     autoload, which itself delegates to a swappable adapter (see
#     scripts/adapters/AdAdapter.gd). This keeps AppLovin/AdMob integration
#     isolated to ONE file.
#
# WHY AN AUTOLOAD?
#   Hyper-casual games have exactly one run-session at a time; a singleton
#   avoids passing a "context" object through every scene and makes signals
#   like `score_changed` trivially observable from any UI node.
#
# MOBILE NOTES
#   - No per-frame work happens here (zero idle CPU cost while on menu).
#   - Best-score persistence is deferred (saved on game-over, not per point)
#     to minimize disk I/O on mobile devices.
# ============================================================================
extends Node

# ---------------------------------------------------------------------------
# ENUMS / CONSTANTS
# ---------------------------------------------------------------------------
enum GameState { MENU, PLAYING, PAUSED, GAME_OVER }

const SAVE_PATH := "user://save.cfg"
const SECTION_PROGRESS := "progress"
const KEY_BEST_SCORE := "best_score"

## How many points each placed cell of a shape awards (Block-Blast style:
## you get points just for placing, bonus comes from line clears).
const BASE_POINTS_PER_CELL := 1

## Combo multiplier grows when the player clears lines on consecutive drops.
const COMBO_STEP := 2
const MAX_COMBO_MULTIPLIER := 8

# ---------------------------------------------------------------------------
# SIGNALS  (UI subscribes; nothing polls)
# ---------------------------------------------------------------------------
signal state_changed(new_state: GameState)
signal score_changed(new_score: int)
signal best_score_changed(new_best: int)
signal combo_changed(multiplier: int)
signal game_over(final_score: int)

# ---------------------------------------------------------------------------
# STATE
# ---------------------------------------------------------------------------
var state: GameState = GameState.MENU:
	set(p_new):
		if state == p_new:
			return
		state = p_new
		state_changed.emit(state)

var score: int = 0
var best_score: int = 0
var combo_multiplier: int = 1          # 1 == no active combo streak
var _games_played_this_session: int = 0 # used to throttle interstitials

func _ready() -> void:
	# Process at default priority; this node has no _process() so it is free.
	_load_progress()

# ---------------------------------------------------------------------------
# PUBLIC API — LIFECYCLE
# ---------------------------------------------------------------------------

## Called by the Main Menu's "Play" button.
func start_game() -> void:
	score = 0
	combo_multiplier = 1
	_reset_combo_streak()
	score_changed.emit(score)
	state = GameState.PLAYING


## Called by GridManager/InputHandler when no remaining piece can be placed.
## This is ALSO the Rewarded-Ad hook: we ask AdManager whether a "continue"
## reward offer should be shown before finalizing game over.
func on_game_over() -> void:
	if state != GameState.PLAYING:
		return  # Guard against double-trigger (e.g. two rapid invalid drops).

	state = GameState.GAME_OVER
	# BUGFIX: increment the interstitial pacing counter HERE, not in some
	# hypothetical future caller — this line previously didn't exist at all,
	# leaving `_games_played_this_session` dead code and the documented
	# "throttle interstitials" intent unimplemented.
	_games_played_this_session += 1

	# Persist best score only at session milestones (cheap on mobile storage).
	if score > best_score:
		best_score = score
		best_score_changed.emit(best_score)
	_save_progress()

	game_over.emit(score)

	# --- AD HOOK -------------------------------------------------------------
	# 1) Offer a Rewarded ad ("watch to continue / double score"). The adapter
	#    decides availability; we simply listen for the result.
	# 2) Queue an Interstitial. AdManager throttles frequency internally so we
	#    can unconditionally request it here.
	# NOTE: `show_rewarded()` grants its reward asynchronously (~seconds later,
	# via AdManager.reward_earned). No gameplay code may assume the bonus has
	# been applied when this function returns — UI must subscribe to
	# `AdManager.reward_earned`.
	if AdManager.has_rewarded_available():
		AdManager.show_rewarded("double_score")

	AdManager.request_interstitial("game_over")


## Player chose to revive/continue after a rewarded ad. Re-enter PLAYING
## without wiping the score.
func resume_from_game_over() -> void:
	if state == GameState.GAME_OVER:
		state = GameState.PLAYING


func pause_game() -> void:
	if state == GameState.PLAYING:
		state = GameState.PAUSED


func unpause_game() -> void:
	if state == GameState.PAUSED:
		state = GameState.PLAYING


func return_to_menu() -> void:
	state = GameState.MENU

# ---------------------------------------------------------------------------
# PUBLIC API — SCORING
# ---------------------------------------------------------------------------

## Award points for cells of a successfully placed shape.
## BUGFIX: gated on PLAYING — without this, events queued before the next
## `start_game()` (e.g. an async reward callback landing during MENU/GAME_OVER)
## could inflate the fresh session's score.
func add_placement_score(cell_count: int) -> void:
	if state != GameState.PLAYING or cell_count <= 0:
		return
	_modify_score(cell_count * BASE_POINTS_PER_CELL)


## Award line-clear points. `lines_cleared` rows+cols cleared in one drop.
## Uses a classic escalating formula: 10 * lines^2 * cells_in_lines roughly,
## simplified here to a flat table multiplied by the combo streak.
## Same PLAYING gate as add_placement_score (see BUGFIX note above).
func add_line_clear_score(lines_cleared: int, cells_cleared: int) -> void:
	if state != GameState.PLAYING:
		return
	if lines_cleared <= 0 or cells_cleared <= 0:
		return
	# Base value scales super-linearly to reward multi-line clears.
	var base := cells_cleared * 10 * lines_cleared
	_bump_combo_streak()
	_modify_score(base * combo_multiplier)


## Reset combo when a placement clears zero lines (breaks the streak).
func register_dry_placement() -> void:
	_reset_combo_streak()

# ---------------------------------------------------------------------------
# INTERNALS
# ---------------------------------------------------------------------------

func _modify_score(delta: int) -> void:
	score += delta
	score_changed.emit(score)


func _bump_combo_streak() -> void:
	# Multiplier grows by COMBO_STEP per consecutive clearing drop, capped.
	combo_multiplier = mini(combo_multiplier + COMBO_STEP, MAX_COMBO_MULTIPLIER)
	combo_changed.emit(combo_multiplier)


func _reset_combo_streak() -> void:
	if combo_multiplier != 1:
		combo_multiplier = 1
		combo_changed.emit(combo_multiplier)


func _save_progress() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION_PROGRESS, KEY_BEST_SCORE, best_score)
	# Errors ignored intentionally: read-only storage on some sandboxes must
	# never crash the game loop.
	cfg.save(SAVE_PATH)


func _load_progress() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return  # First launch — defaults are fine.
	best_score = cfg.get_value(SECTION_PROGRESS, KEY_BEST_SCORE, 0)
