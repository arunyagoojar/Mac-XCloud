# Revision 18 — MKB root-cause closure, inline profile editor, universal builds

## Mouse & keyboard — what was actually wrong, verified against Better xCloud 6.7.12

The user shared the full Better xCloud 6.7.12 userscript; every conclusion below
is traced in that source (the app bundles the same version).

1. **Emulated controller: no preset assigned.** The handler's keyboard/mouse
   path returns early on `!this.PRESET`; the preset resolves from the stream
   setting `mkb.p1.preset.mappingId`, default `null`. Revision 17's
   auto-assignment of the built-in Standard layout (id −1) is the fix. The
   user's last in-game test predated that build.
2. **Native MKB "On" reverting to "default"**: the setting's `ready` handler
   deletes the "on" option unless the host provides `AppInterface`, captured at
   userscript load (`var AppInterface = window.AppInterface`). The app's shim
   is injected in the same document-start user script, ahead of that capture —
   verified in `wrappedScript` ordering (`inputAdapter → BxC → bridge`). The
   user's revert screenshot predates revision 17; r17/r18 keep "On".
3. **Missing keyboard icons on xbox.com**: those icons are the Xbox site's own
   UI, shown when the browser reports Chromium-style MKB support. WebKit does
   not, so the site hides them — cosmetic, and irrelevant to the emulated
   controller, which works in any game. For the site's *own* native MKB
   experience, the User-Agent profile setting (Edge + Windows) is the known
   lever; treat it as experimental.
4. **The emulated handler's keyboard gate** (`xCloudPollingMode !== "none"` /
   `isPolling`) is satisfied by activation (F8/⇧⌘K) — with the preset present,
   input flows either through the site's polling of the injected virtual pad
   or Better xCloud's direct channel.

The app also implements the host contract Better xCloud expects for native
MKB: `AppInterface` (pointer capture routing) and the localhost WebSocket
pointer server (protocol v2, port 9269, verified listening), so "On" is
selectable and functional for MKB-advertised games.

## Controller configuration safety

The MKB work writes only Better xCloud's own `mkb.p1.preset.mappingId`
preference. The app's controller configuration (`nativeController.settings.v1`,
profiles, steering/gyro/touch state machines, adaptive-trigger code) has no
overlapping writes; steering and gyro behavior is unchanged by the MKB work.

## Profile editor moves into the settings panel

Virtual-controller and keyboard-shortcut profile managers no longer open a
separate window. A new `SettingsRoute.profileEditor` case renders the editor
inside the settings panel's existing back/forward/home navigation, with the
"Open…" buttons pushing the route and keyboard focus scoped to the editor.

## Universal (Intel + Apple Silicon) builds

Release builds are now universal (`ARCHS = arm64 x86_64`, `ONLY_ACTIVE_ARCH =
NO` in both project Release configurations, plus explicit flags in the GitHub
release workflow and `release.sh` — verified producing an `x86_64 arm64`
binary). Deployment target remains macOS 12.

## Remote Play tester feedback (logged, actions pending)

- Works well overall: controllers over WiFi/2.4 GHz and chained Parsec setups,
  "no latency after turning the console on", 12-year-old Intel MacBook praised.
- **Console in standby doesn't wake** ("We can't connect to your console right
  now"): waking a standby console requires the console power-on handshake,
  which is not part of the current connection path — needs its own
  investigation and cannot be validated without an Xbox console.
- Requests logged for next iterations: group Remote Play settings apart from
  Cloud settings, consolidate stream/video/overlay and controller groups, and
  an on-screen back affordance when browsing away from the home page (⌘[ and
  the menu Back item exist today).

## Validation

Release build succeeded; packaged binary is `x86_64 arm64`. All suites pass:
163 controller/model checks, bridge contracts (MKB status/toggle/preset
assignment/prompt suppression), gamepad polling contracts (steering channel,
201-level sweep), 17 preset-store checks, settings-manager contract. Not
verified live: an in-game MKB session and native MKB in an MKB-advertised
title — these need a running stream on the user's account.
