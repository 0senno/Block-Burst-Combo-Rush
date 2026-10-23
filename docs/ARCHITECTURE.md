# ============================================================================
# ARCHITECTURE.md — Block Puzzle (working title) — Godot 4.x mobile project
# ============================================================================

## 1. Folder Structure

```
res://
├── project.godot              # Autoloads + mobile render settings live here
├── scenes/
│   ├── Main.tscn              # Root: swaps Menu/Game sub-scenes
│   ├── MenuScene.tscn         # Title, Play button, best score label
│   ├── GameScene.tscn         # BoardRenderer + PieceTray + InputHandler + HUD
│   └── ui/
│       ├── HUD.tscn           # Score / combo labels (CanvasLayer)
│       └── GameOverPanel.tscn # Final score, "Watch ad -> 2x", Restart
├── scripts/
│   ├── autoload/
│   │   ├── GameManager.gd     # STATE: "GameManager"  (state machine + score)
│   │   └── AdManager.gd       # STATE: "AdManager"    (ad facade + freq caps)
│   ├── core/
│   │   ├── GridManager.gd     # Pure 8x8 logic, signals only, no rendering
│   │   ├── InputHandler.gd    # Touch/drag -> snap -> commit via GridManager
│   │   ├── PieceTray.gd       # Object-pooled 3-slot tray (implements the
│   │   │                      #   contract documented at bottom of InputHandler.gd)
│   │   └── BoardRenderer.gd   # ONE MultiMeshInstance2D for all 64 cells
│   ├── adapters/
│   │   ├── AdAdapter.gd       # Abstract base (signals + load/show API)
│   │   ├── MockAdAdapter.gd   # Editor-time simulation (used today)
│   │   └── AppLovinAdapter.gd # (later) thin wrapper over the MAX SDK plugin
│   └── ui/
│       ├── HUD.gd
│       └── GameOverPanel.gd
├── resources/
│   └── shapes/                # ShapeDefinition .tres files (generic placeholders)
└── addons/                    # Drop third-party SDK plugins here later
```

### Dependency direction (strictly one-way — no upward references)
```
UI/HUD  ──listens──▶  GameManager (autoload)  ──requests──▶  AdManager (autoload)
                                                          │
GameScene ──owns──▶ GridManager ◀──calls── InputHandler   ▼
                        │  signals                    AdAdapter (swappable)
                        ▼
                   BoardRenderer (draw-only)
```

## 2. Autoload Setup (Project ▸ Project Settings ▸ Globals)

| Order | Name          | Path                                  | Purpose                                   |
|-------|---------------|---------------------------------------|-------------------------------------------|
| 1     | `GameManager` | `res://scripts/autoload/GameManager.gd` | State machine, score, save/load, ad triggers |
| 2     | `AdManager`   | `res://scripts/autoload/AdManager.gd`   | Ad facade; frequency capping; SDK adapter holder |

Order matters: GameManager's `_ready()` never touches AdManager, but
`on_game_over()` does — both exist by the time any scene runs.

## 3. Mobile Optimization Checklist

- **Renderer**: Forward+ is overkill; set `rendering/renderer/rendering_method="mobile"` in project.godot. For a pure-2D game consider even the GL Compatibility renderer for max device coverage.
- **Draw calls**: The board is drawn with a single `MultiMeshInstance2D` (64 quads → 1 draw call). Tray pieces reuse pooled nodes; nothing is instantiated during play.
- **Textures**: One shared block atlas (all colors in a single texture) so every quad batches together. Compress ETC2/ASTC for Android, BC/ASTC for iOS builds.
- **Input**: Event-driven (`_unhandled_input`), zero `_process` work while idle → lower battery drain.
- **Threading**: Keep main-thread only; avoid `await` chains inside drop commits to prevent frame hitching on low-end SoCs.
- **Resolution scaling**: `canvas_items` stretch mode, aspect `keep` — design at 720×1280 portrait.
- **Ads**: Interstitials are frequency-capped in AdManager (≥90 s AND ≥2 games apart) to protect D1 retention. Rewarded ads are preloaded after each show so they're always ready at game-over.

## 4. Hooking a Real Ad SDK Later (AppLovin MAX example)

1. Install the MAX Godot plugin into `addons/com.applovin.max/`, enable it.
2. Create `scripts/adapters/AppLovinAdapter.gd`:
   ```gdscript
   extends "res://scripts/adapters/AdAdapter.gd"
   func initialize(app_id: String) -> void:
       AppLovin.initialize(app_id)
   func show_rewarded(placement: String) -> void:
       AppLovin.show_rewarded_ad(placement)   # emits callbacks you forward to
   ```
3. Change **one line** in `AdManager._build_adapter()` to return the new class.
   No gameplay file changes. GameManager keeps calling `AdManager.show_rewarded(...)`.

## 5. Legal Note

All art/name placeholders must be original or CC0. Do not ship the words
"Block Blast" or imitate competitor iconography — this doc uses "block puzzle"
generically throughout.
