# ============================================================================
# MockAdAdapter.gd
# ----------------------------------------------------------------------------
# Editor/desktop stand-in for a real ad SDK. Simulates network latency with
# Timers so the full rewarded/interstitial flow (including frequency caps)
# can be tested without building to a device.
# ============================================================================
extends AdAdapterBase
# Godot 4.x caveat: `extends "res://path.gd"` is fragile in headless/exported
# builds (the resource class may not be registered yet when this script is
# parsed, producing "Could not resolve class"). Extending via the parent's
# global `class_name` resolves through the ScriptServer directly and is the
# officially supported pattern for SDK adapter layers.

var _rewarded_loaded := false
var _interstitial_loaded := false

func get_name() -> String:
    return "Mock"

## Simulate an async SDK load callback firing after ~1.5s.
func load_rewarded(_placement: String) -> void:
    _rewarded_loaded = false
    get_tree().create_timer(1.5).timeout.connect(func() -> void:
        _rewarded_loaded = true
        rewarded_ready.emit())


func has_rewarded_available() -> bool:
    return _rewarded_loaded


func show_rewarded(_placement: String) -> void:
    _rewarded_loaded = false  # consumed; must reload before next show
    # Fake 2s video, then grant reward deterministically (test-friendly).
    get_tree().create_timer(2.0).timeout.connect(func() -> void:
        rewarded_closed.emit(true))


func load_interstitial(_placement: String) -> void:
    _interstitial_loaded = false
    get_tree().create_timer(1.0).timeout.connect(func() -> void:
        _interstitial_loaded = true
        interstitial_ready.emit())


func has_interstitial_available() -> bool:
    return _interstitial_loaded


func show_interstitial(_placement: String) -> void:
    _interstitial_loaded = false
    get_tree().create_timer(1.5).timeout.connect(interstitial_closed.emit)
