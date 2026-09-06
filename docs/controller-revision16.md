# Revision 16 — native mouse & keyboard (virtual controller) integration

## Investigation findings

- **Pointer Lock works in this app's WebKit.** Verified on this machine with a
  live WKWebView test: `requestPointerLock({unadjustedMovement: true})` locks
  and delivers `movementX/Y` deltas. Pointer lock is not the blocker.
- **"The requested value is not supported here" is the app's own save toast**,
  shown when Better xCloud normalizes a setting on save (`setSetting`
  validates values against each setting's options/min/max and silently stores
  the default for anything invalid). It now names the exact setting id and both
  values so any mismatch can be reported against a specific row.
- Better xCloud's mouse-and-keyboard feature has two modes: the
  **virtual controller** (keyboard/mouse emulated into an Xbox controller —
  works anywhere) and **native MKB** (`nativeMkb.mode = On`, real mouse/keyboard
  support — requires the game to advertise MKB support and, on Electron hosts, a
  local pointer server we do not run). Both are activated by pressing **F8** or
  the popup's Activate button, which requests pointer lock and then listens for
  keyboard and mouse input.
- The "activate the virtual controller by pressing F8" prompt is Better
  xCloud's own CSS popup (`.bx-mkb-pointer-lock-msg`).

## Changes

- **The CSS activation prompt is replaced by native UI.** The page popup is
  suppressed with injected CSS; its state (enabled / awaiting activation /
  pointer-locked) is mirrored to the app through the existing message channel.
- **Native MKB state in the HUD**: the stats capsule shows a KBM badge — yellow
  "F8" when mouse & keyboard is enabled but not activated, green "on" while the
  pointer is locked.
- **Native toggle**: a new "Toggle Mouse & Keyboard" item in the Settings menu
  (⇧⌘K) dispatches the same F8 event Better xCloud binds, so activation works
  from the menu without hunting for the web popup.
- `BxCBridge.mkbStatus()` / `BxCBridge.toggleMkb()` expose the state and toggle
  to diagnostics and future native surfaces.

## Why keyboard input may still have felt dead

The virtual controller only sends input **while activated** (F8, pointer locked).
If it was enabled but never activated — or activated in a previous session
without re-activating after the stream restarted — keys do nothing. With this
build: enable **Emulate controller with Mouse & Keyboard** in Settings → Mouse
& Keyboard, join a game, then press ⇧⌘K (or F8) — the HUD KBM badge turns green
when active. Map keys in Settings → Mouse & Keyboard → Virtual controller
profiles (the native editor writes Better xCloud's preset storage).

Native MKB mode ("real" keyboard/mouse) additionally requires the game to
advertise MKB support; the emulated-controller mode works in any game.

## Validation and limits

Release build succeeded. All contract suites pass, including new coverage:
MKB status readback, synthetic F8 toggle dispatching keydown+keyup, CSS prompt
suppression, and native state mirroring (bridge contracts); the pre-existing
steering, gyro, touch-servo, and preset suites are unchanged. Pointer Lock was
verified live in WKWebView on this macOS. Not yet verified: a live in-game MKB
session with mapped keys, which needs a running stream; the native MKB mode
remains limited to games that advertise support, and pointer-lock edge cases in
fullscreen are a known WebKit bug family if activation ever silently fails.
