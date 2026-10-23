# ============================================================================
# AdAdapter.gd  (base class — NOT an autoload)
# ----------------------------------------------------------------------------
# Abstract interface every ad SDK wrapper must implement. By coding against
# THIS interface, AdManager (the autoload) can swap AppLovin <-> AdMob <->
# a no-op mock without any gameplay file changing.
#
# WHY extends Node?  Ad SDK callbacks are asynchronous and adapters need
# SceneTree timers/coroutines to simulate or poll them, so adapters are real
# Nodes owned (and freed) by AdManager. (MockAdAdapter calls get_tree(); on a
# RefCounted that is a hard runtime crash — this MUST stay `extends Node`.)
# ============================================================================
extends Node
class_name AdAdapterBase
# Godot 4.x caveat: `extends "res://path.gd"` requires the target script to
# declare a `class_name` for the resource-path resolution to succeed during
# headless/exported builds. We use a distinct name (`AdAdapterBase`) instead
# of `AdAdapter` to avoid shadowing the file name and any future plugin
# symbol collisions. AdManager still talks to this through duck-typed signals
# and methods, so swapping implementations remains a one-line change.

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
