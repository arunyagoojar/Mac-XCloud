# Revision 17 — why mouse & keyboard was dead, and the native host implementation

## Root causes found (from Better xCloud's source, verified in this repo's bundle)

1. **Emulated controller: no MKB preset was ever assigned.** The emulated
   handler drops every keyboard and mouse event unless a preset is resolved
   (`refreshPresetData(): this.PRESET = BX_STREAM_SETTINGS.mkbPreset`, and the
   keyboard path returns early on `!this.PRESET`). The preset comes from the
   stream setting `mkb.p1.preset.mappingId`, whose default is `null` — and
   nothing in the app (or the page, outside Better xCloud's CSS settings
   dialog) ever assigned it. Enabled + activated + no preset = exactly the
   reported "cannot press any button, mouse does nothing".
2. **Native MKB: "On" cannot be selected without a host.** The setting's
   `ready` handler deletes the "on" option unless the host provides
   `AppInterface` (Better xCloud's Electron contract); saving "on" then
   validates against the remaining options and falls back to "default" — the
   exact "Saved as 'default' — requested 'on'" toast in the screenshot.

Both gates are environmental, not missing functionality: the same code paths
that work in Chrome/Electron were never completed on our host.

## Changes

- **Default preset auto-assignment**: when Mouse & Keyboard is enabled and no
  preset is assigned to player 1, the bridge assigns the built-in Standard
  layout (id −1: WASD movement, mouse aim, Space/E → A, R → X, F → Y, Tab →
  View…). Better xCloud's own setting-changed event then feeds the preset to
  the emulated controller. Idempotent; never overrides an existing choice.
- **Preset surface for native UI**: `BxCBridge.mkbPresets()` lists built-in and
  stored layouts; `BxCBridge.assignMkbPreset(id)` assigns one to player 1.
- **Native MKB host implemented.** The app now provides the Electron host
  contract: an `AppInterface` shim (pointer capture requests routed to native),
  and a localhost WebSocket pointer server on port 9269 speaking Better
  xCloud's pointer protocol v2 (handshake 127/version 2; move [1|int16 dx|dy];
  press/release [2|3|uint8 button]; scroll [4|int16 v|h]; capture state
  [5|int8]). With it, `nativeMkb.mode = On` becomes selectable and functional:
  the app captures the pointer natively (cursor hidden and pinned to the screen
  centre; drift from centre is the movement delta — no accessibility
  permission), forwards clicks, wheel and deltas as binary frames, and releases
  cleanly. Info.plist gained `NSAllowsLocalNetworking` for the localhost
  socket. The server is verified listening on this machine.
- Sensor status/HUD/state mirroring from revision 16 unchanged; the emulated
  path (F8 / ⇧⌘K activation, KBM badge) still works exactly as shipped there.

## Quick test

1. Settings → Mouse & Keyboard → enable **Emulate controller with Mouse &
   Keyboard**. Join any game, press **F8** (or ⇧⌘K, or the HUD/menu): WASD and
   mouse should now reach the game with the Standard mapping. The HUD KBM badge
   is green while active; Escape (hold 1 s) or F8 deactivates.
2. Mouse & Keyboard → Virtual controller profiles → Open… to remap keys.
3. **Native Mouse & Keyboard → On** should now save instead of reverting. It
   only works in games that advertise MKB support (those are the games with the
   keyboard icons on xbox.com); the emulated mode works everywhere. While
   native capture is active the cursor is hidden and pinned centrally.

## Validation and limits

Release build succeeded; the pointer server verified listening on port 9269.
All contract suites pass, including new coverage: default MKB preset
auto-assignment, preset listing/assignment round trip, MKB status readback,
synthetic F8 toggle, CSS prompt suppression, and native state mirroring. The
pointer-server binary protocol is implemented to Better xCloud's documented
client parser (protocol version 2) but a live in-game native MKB session has
not been run; if a game ignores native input, the emulated mode is the
reliable fallback. Unadjusted (acceleration-free) mouse deltas are not
available without OS-level permission — native mode uses the standard
cursor-drift technique, so mouse acceleration settings still apply.
