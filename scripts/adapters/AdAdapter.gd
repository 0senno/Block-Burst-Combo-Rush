# ============================================================================
# AdAdapter.gd  (base class — NOT an autoload)
# ----------------------------------------------------------------------------
# Abstract interface every ad SDK wrapper must implement. By coding against
# THIS interface, AdManager (the autoload) can swap AppLovin <-> AdMob <->
# a no-op mock without any gameplay file changing.
#
# WHY extends Node?  Ad SDK callbacks are asynchronous and adapters need
# SceneTree timers/coroutines to simulate or poll them, so adapters are real
# Nodes owned (and freed) by AdManager.
# ============================================================================
extends RefCounted
# NOTE: deliberately NOT `class_name AdAdapter`. Registering a global class
# name here would create a cyclic-parse hazard with adapters that extend it
# by path (MockAdAdapter, AppLovinAdapter). AdManager resolves the interface
# structurally (duck typing), so a global name is unnecessary.

signal rewarded_ready()                 # a rewarded ad is loadable right now
signal rewarded_closed(earned: bool)    # user finished (or skipped) the video
signal interstitial_ready()
signal interstitial_closed()

## Human-readable name for debug HUDs.
func get_name() -> String:
	return "Mock"

## Called once by AdManager after adapter construction (SDK init goes here).
func initialize(_app_id: String) -> void:
	pass

## ---- Rewarded ------------------------------------------------------------
func load_rewarded(_placement: String) -> void:
	pass

func has_rewarded_available() -> bool:
	return false

func show_rewarded(_placement: String) -> void:
	# Mock contract: immediately "watch" and grant the reward so the game
	# loop can be tested end-to-end without a real SDK build.
	rewarded_closed.emit(true)

## ---- Interstitial ----------------------------------------------------------
func load_interstitial(_placement: String) -> void:
	pass

func has_interstitial_available() -> bool:
	return false

func show_interstitial(_placement: String) -> void:
	interstitial_closed.emit()
