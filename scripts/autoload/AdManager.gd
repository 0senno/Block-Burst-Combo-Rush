# ============================================================================
# AdManager.gd  (Autoload Singleton -> "AdManager")
# ----------------------------------------------------------------------------
# The ONLY node gameplay code talks to for monetization. It:
#   1. Holds a swappable `AdAdapter` (mock now, AppLovin/AdMob plugin later).
#   2. Enforces frequency capping so interstitials never annoy players
#      (retention > short-term eCPM in hyper-casual).
#   3. Re-exposes adapter signals as game-level events.
#
# TO INTEGRATE A REAL SDK LATER:
#   - Drop the Godot plugin (e.g. com.applovin.max or an AdMob GDExtension)
#     into addons/.
#   - Write scripts/adapters/AppLovinAdapter.gd extending AdAdapter and call
#     the plugin's native methods inside it.
#   - Change `_build_adapter()` below to return that class. NOTHING ELSE changes.
# ============================================================================
extends Node

# ---------------------------------------------------------------------------
# CONFIG — tune these from analytics after launch; defaults are conservative.
# ---------------------------------------------------------------------------
const MIN_INTERSTITIAL_SECONDS := 90.0   # wall-clock gap between interstitials
const MIN_GAMES_BETWEEN_INTERSTITIALS := 2
const APP_ID := ""                       # filled per-build via export vars

# ---------------------------------------------------------------------------
# SIGNALS (UI listens: e.g. show a "reward received!" toast)
# ---------------------------------------------------------------------------
signal reward_earned(placement: String)
signal ad_shown(kind: String, placement: String)
signal ad_closed(kind: String, earned: bool)

# ---------------------------------------------------------------------------
# STATE
# ---------------------------------------------------------------------------
var _adapter: Node = null               # AdAdapter-derived instance (a Node)
var _last_interstitial_ms: int = 0
var _games_since_interstitial: int = 0
var _reward_pending_placement: String = ""

func _ready() -> void:
	_adapter = _build_adapter()
	add_child(_adapter)                   # adapter needs the SceneTree for timers
	_adapter.rewarded_ready.connect(_on_rewarded_ready)
	_adapter.rewarded_closed.connect(_on_rewarded_closed)
	_adapter.initialize(APP_ID)
	# Preload the first rewarded slot immediately; video networks need warm-up.
	_adapter.load_rewarded("double_score")


## Swap this line when integrating the real SDK — see header comment.
func _build_adapter() -> Node:
	return load("res://scripts/adapters/MockAdAdapter.gd").new()

# ---------------------------------------------------------------------------
# PUBLIC API (used by GameManager)
# ---------------------------------------------------------------------------

func has_rewarded_available() -> bool:
	return _adapter != null and _adapter.has_rewarded_available()


func show_rewarded(placement: String) -> void:
	if not has_rewarded_available():
		return
	_reward_pending_placement = placement
	ad_shown.emit("rewarded", placement)
	_adapter.show_rewarded(placement)


## GameManager calls this on every game over; AdManager decides whether the
## frequency cap allows showing one right now.
func request_interstitial(placement: String) -> void:
	_games_since_interstitial += 1
	var now_ms := Time.get_ticks_msec()
	var time_ok := (now_ms - _last_interstitial_ms) >= \
		int(MIN_INTERSTITIAL_SECONDS * 1000.0)
	var count_ok := _games_since_interstitial >= MIN_GAMES_BETWEEN_INTERSTITIALS
	if not (time_ok and count_ok):
		return
	if not _adapter.has_interstitial_available():
		return  # Never block the game-over screen waiting on a slow load.
	_last_interstitial_ms = now_ms
	_games_since_interstitial = 0
	ad_shown.emit("interstitial", placement)
	_adapter.show_interstitial(placement)

# ---------------------------------------------------------------------------
# ADAPTER CALLBACKS
# ---------------------------------------------------------------------------

func _on_rewarded_ready() -> void:
	pass  # UI can enable the "Watch ad for 2x score" button here.


func _on_rewarded_closed(earned: bool) -> void:
	ad_closed.emit("rewarded", earned)
	if earned:
		reward_earned.emit(_reward_pending_placement)
	# Immediately pre-fetch the next video while the player keeps playing.
	_adapter.load_rewarded(_reward_pending_placement)
