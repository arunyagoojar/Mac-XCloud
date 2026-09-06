# Revision 9 — one Gyro mode picker, mouse-style touch servo, smoother strokes

## Changes

- **One Gyro mode picker** replaces the separate aiming/steering/flick toggles and stick pickers: Off, Aiming (right stick), Steering wheel (left stick), Flick shifting. Only the controls relevant to the selected mode are shown. Stored fields are unchanged, so saved profiles and the injected script keep working; the picker writes the same underlying settings.
- **Touchpad aiming is now a mouse-style servo.** The old pipeline differentiated finger position into velocity every report, which amplified sensor noise into jitter and saturated every short swipe — worst at the pad edges where play is a series of short ratchet flicks. Now finger travel accumulates into a target and a proportional servo drives the stick toward it: output is a smooth function of accumulated undelivered travel, per-report coordinate noise averages out instead of being differentiated, slow drags glide above the game dead zone, flicks deliver exact travel, and a resting or lifted finger stops the camera. Sensitivity scales travel directly.
- **Gyro stroke onset is ramped.** The dead-zone carrier used to jump from zero to its full value in one frame at every motion onset — a visible twitch. It now fades in over roughly two frames; sustained slow motion still reaches the full carrier. Slow-motion smoothing is stronger (1€ minimum cutoff 5 → 3.5) while fast strokes stay responsive (beta 6 → 7).
- **Steering clarifications.** The response curve is sub-linear so small cruising tilts keep usable resolution above the carrier, the default full-lock tilt is 40°, and Flick shifting no longer requires turning "Only while holding L2" off manually. A **Live steering** row shows the measured tilt angle and the output being sent, so a non-responding game can be told apart from a non-computing mode.
- Removed the last dead mouse-mode branch from the injected script's polling adapter.

## Why steering could look completely dead

Steering output must exceed the game's own inner stick dead zone before anything happens. With Forza's default dead zone, a push of 0.12–0.30 can sit inside it: slow tilts do nothing and mid tilts flicker around the boundary. The Live steering row now shows whether output is being produced; raise **Steering push** until the car responds, or set the game's steering dead zone to zero and lower the push for the finest cruising control. Steering is measured against the neutral saved by Center Gyro — press it again whenever your resting grip changes.

## Quick test

1. **Touchpad:** swipe slowly, then fast, near the pad centre and near the right edge. Motion should be proportional everywhere, with no lurch on short edge flicks, and lifting or holding the finger still should stop the camera within a fraction of a second.
2. **Aiming:** set the game response curve to Linear; slow strokes should be smooth with no onset twitch, and retracing right-then-left should return the view to its start.
3. **Steering:** Gyro mode → Steering wheel, press Center Gyro while driving straight, tilt a few degrees — Live steering should show the angle and output immediately. If the car ignores it, raise Steering push; if small tilts feel too strong, set the game's dead zone to zero and lower the push.
4. **Flick shifting:** Gyro mode → Flick shifting; repeated quick downshifts should still fire without any L2 setting changes.

## Validation and limits

Release build succeeded. 95 controller/model contract checks pass, including: touch travel accumulation, immediate near-full-speed flick command, complete delivery with a short glide and no creep, slow-drag glide above the game dead zone, immediate stop on lift, resistance to resting-finger coordinate shiver, gyro mode mapping and profile round trip, plus all prior steering, flick, and gyro turnaround coverage. Browser polling, bridge, and preset-store contracts pass.

Live feel is pending on the controller. The servo models delivery with an assumed 1:1 game gain; games with heavy response curves change the scale (not the smoothness) of touch motion, which the sensitivity slider absorbs. Steering through a stick remains bounded by the game's own dead zone and response curve; the Live steering readout exists precisely to make that visible.
