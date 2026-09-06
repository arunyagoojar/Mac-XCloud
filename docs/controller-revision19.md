# Revision 19 — the missing User-Agent setting and the virtual controller's polling gate

## User-Agent profile setting (was genuinely missing)

The app's settings pane had no User-Agent row — only its save handling existed.
Added **Settings → Mouse & Keyboard → User-Agent profile** (Default / Edge +
Windows / Safari + macOS). The Xbox site gates its own MKB UI (the keyboard
icons on game cards) on the browser it recognizes; "Edge + Windows" makes the
site show that UI. Reload to apply (the pane shows the reload button).

## Virtual controller: the polling gate that silently ate all input

Traced in Better xCloud 6.7.12: the emulated handler's keyboard/mouse path
returns early unless **`BX_STREAM_SETTINGS.xCloudPollingMode === "none"`**.
That mode is the *site's* gamepad-polling state. In Chrome the site's own MKB
pipeline handles keys when polling is active; **WebKit has no such site-side
pipeline, so with polling in any non-"none" mode nothing mapped keys at all** —
exactly the reported dead input even after activation.

While the virtual controller is active, the injected bridge now forces the
site's gamepad polling off (`BX_EXPOSED.disableGamepadPolling = true`) and the
polling mode to "none", so Better xCloud's own keyboard/mouse handler is the
single input sender. On deactivation both are restored, so physical controllers
work as before. The force re-asserts every second, healing conflicts with the
Settings-focus pause.

Because the host shim is present, the emulated handler's mouse data comes from
the app's native pointer server; the mirror now also requests pointer capture
(cursor pinned centre-screen, hidden) on activation and releases it after.

## Test

1. Settings → Mouse & Keyboard → enable Emulate controller; pick a game.
2. Press F8 or ⇧⌘K — HUD KBM badge green. WASD moves, mouse aims, Space → A
   (Standard mapping). Escape (hold 1 s) releases.
3. User-Agent profile → Edge + Windows → Reload to Apply: game cards should
   show the site's keyboard icons.

## Validation

Release build succeeded (universal `x86_64 arm64`). All suites pass: 163
controller/model checks, bridge contracts (MKB preset assignment, status,
toggle, prompt suppression), polling contracts, 17 preset-store checks. Live
in-game MKB verification is still pending on a real stream — if input remains
dead with the KBM badge green, export diagnostics (they now include the
polling mode, preset assignment and capture state) and report the game.
