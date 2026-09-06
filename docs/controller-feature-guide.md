# Mac XCloud controller analysis and test guide

Prepared 5 September 2026. This is an implemented controller-feature preview, with compilation and automated regression checks completed. Live Xbox sessions, USB/Bluetooth behavior, motor feel, latency, and visual layout on the running app still require your testing. No claim of universal controller compatibility or game-authored PS5 effects is made.

## What the web can actually do

| Feature | Evidence | Decision for this app |
|---|---|---|
| Normal controller buttons and sticks | Existing WebKit Gamepad path already feeds Better xCloud | Retain the real controller and existing outgoing Xbox sample |
| Trigger vibration | WebKit implemented the `trigger-rumble` effect type; availability is device-dependent | Probe the actual actuator’s advertised effects and provide a direct web test |
| Adaptive trigger resistance | Standard web haptic effects specify vibration, not DualSense resistance/breakpoint instructions | Continue using native Apple adaptive-trigger APIs |
| Touchpad coordinates | The current Gamepad working draft includes `touches`; implementation varies | Prefer browser touch coordinates when exposed, otherwise use native touch coordinates |
| Controller gyro | Controller motion is outside the standard Gamepad API’s scope | Read native rotation rate and merge it into the outgoing right stick |

The standard’s trigger-rumble effect represents four vibration motors. It is not a language for configuring trigger resistance, detents, or weapon breakpoints. Its touch coordinates are normalized and can be translated into stick input. Merely exposing touch coordinates does not mean an Xbox game accepts touchpad gestures or native touchscreen events. [W3C Gamepad draft](https://www.w3.org/TR/gamepad/)

WebKit’s trigger-rumble implementation was marked fixed in January 2023; this does not establish support for a particular Mac, OS version, or DualSense connection. The app’s **Check Web Support** and **Test Web Triggers** determine that at runtime. [WebKit implementation record](https://bugs.webkit.org/show_bug.cgi?id=250352)

Microsoft’s documented Xbox/GameInput rumble structure contains low-frequency, high-frequency, left-trigger, and right-trigger intensities. These can vary as the game changes, but do not contain a weapon identity or a DualSense resistance curve. [Microsoft GameInputRumbleParams](https://learn.microsoft.com/en-us/gaming/gdk/docs/reference/input/gameinput/structs/gameinputrumbleparams)

Apple exposes native adaptive-trigger controls and controller touchpad input. Those are the most practical way to retain this SwiftUI/WebKit app while using features that its browser does not expose. [Apple adaptive triggers](https://developer.apple.com/documentation/gamecontroller/gcdualsenseadaptivetrigger), [Apple touchpads](https://developer.apple.com/documentation/gamecontroller/gccontrollertouchpad)

A Chromium/WebHID rewrite could access device-specific reports, but requires device permission and controller-specific USB/Bluetooth protocols. It would not cause Xbox to send PS5 data that is absent from the stream. I recommend keeping the current engine and testing this focused bridge first. [Chrome WebHID documentation](https://developer.chrome.com/docs/capabilities/hid)

## Architecture and findings

The original app has two readers of the same controller. WebKit supplies the physical Gamepad used by Xbox. Native GameController supplies controller tools, touch gestures, calibration readings, and motor output. This is not inherently wrong; the gap was that native calibration was not being applied to gameplay.

The updated path is:

**Physical controller → existing browser mapping → enabled native adjustments / browser touch → macro override → existing Xbox sender.**

No second virtual controller is registered, and `navigator.getGamepads()` is not replaced. Native gyro, optional calibration, and hold-to-fire are merged into Better xCloud’s existing mapped input sample. Saved macros have final priority. Native adjustments expire after 150 ms without updates, clear with macro/profile resets, and are gated by native focus, page visibility, and input-tool ownership. Only one controller may be present in both native and browser lists for these adjustments; ambiguous multi-controller setups leave the original sample alone.

The native-to-web delivery permits only one outstanding update, avoiding an expanding queue. This still has measurable bridge overhead; do not treat it as proven latency-free. The merged-sample counter helps establish whether the runtime hook is actually executing. Matching the bundled patch location alone does not prove a future Xbox site build will accept that patch.

The rumble bridge already received both trigger channels but discarded them. The old handler also created independent haptic pulses and ignored zero-strength stop events. Stream playback now replaces its previous player, handles silence, and bounds event lifetime. Body rumble remains an approximation using the stronger main channel and right-channel sharpness; it is not full PS5 waveform haptics or independent four-motor reproduction.

The settings layout is preserved. New controls use the existing groups, rows, switches and slider widths. The invisible end-strength row in vibration-ramp editing was removed instead of leaving an empty gap.

## Implemented features

- **Per-game profiles:** uses captured product/title IDs, never the generic browser/console name. Selecting a profile during play stores the association. Re-entering that game restores it; leaving restores the pre-game profile. Unknown games use that baseline. Missing title metadata does not erase an active association. Enable/disable in Input Presets.
- **Trigger dead zones:** independent L2/R2 start offsets remain local to the Mac and survive profile switching. Enable **Apply calibration to Xbox** under Calibration to use these in gameplay. This intentionally replaces mapped stick/trigger values, so do not simultaneously configure conflicting Better xCloud remapping for those controls.
- **Stick previews:** selectable linear, precise-center, quick-response and S-curves with previews of calibrated output, including the dead zone.
- **Rumble curve:** incoming intensity is raised to the profile exponent, multiplied by profile and global gain, and clamped. Existing Better xCloud scaling and native haptic gain still apply. Gain zero mutes; exponent above one softens weaker events.
- **Trigger stops:** independent enable switches, shared adjustable stop position, maximum resistance after the stop. Switching off restores the selected preset. This cannot create a physical travel limiter.
- **Hold-to-fire:** enabled in Shortcuts & Macros; R2 above halfway produces alternating pressed/released samples at 2–15 cycles per second. This is a dedicated repeating mode rather than a repeatedly launched fixed macro. Game fire-rate limits and polling determine actual shots.
- **Sharing:** export the saved active profile as a checksummed JSON file; import creates a new ID/name and preserves Default. Active custom trigger effects travel as self-contained snapshots. Hardware calibration and the entire unused trigger library do not travel with a profile. Save Current Profile before exporting recent web edits.
- **Custom trigger modes:** added editable two-stage resistance and detent-and-release, using the existing positional feedback implementation and preview. macOS 12.0–12.2 use constant-feedback fallback; positional modes need 12.3+ for the full shape.
- **Game-trigger translation:** optional Xbox trigger intensity → DualSense trigger vibration. Only nonzero trigger-channel signals drive this mode. The selected preset resumes afterward, and trigger stops take priority. Frequency is fixed at a normalized 0.5 because the stream supplies intensity, not authored frequency/resistance data.
- **Gyro aim:** native rotation rate → additive right stick, sensitivity, dead zone, smoothing, vertical inversion, stationary drift centering, and optional L2-held activation. It maps angular velocity to stick velocity; it is not mouse input or one-to-one angular aiming.
- **Touchpad aim:** optional absolute touch-position → additive right stick, preferring browser touch data where present. Gesture actions are suspended while this mode is enabled. Native gesture mappings can also launch saved macros.
- **Diagnostics:** actual browser effects, touch API, motion-property presence, WebHID presence, bridge counter, direct web rumble tests, raw four-channel rumble counters and bounded export. The optional `pose` property is only a presence probe, not a claim that gyro data is usable.

## Your controller test sequence

1. Quit the current app before opening the preview. Connect one DualSense by USB initially. Open **Controller Tools → Test → Check Web Support** after pressing a controller button. Confirm one browser pad appears. Try **Test Web Rumble** and **Test Web Triggers** independently. A rejected or unadvertised trigger effect is a useful finding; it does not indicate failure of native resistance controls.
2. In **Triggers & Haptics**, test the normal native pulse and each trigger stop. Verify turning a stop off restores the chosen preset. Try both new custom modes. Do not force the trigger to determine whether the stop is physically rigid; it is resistance emulation.
3. In **Touchpad**, enable gyro, keep L2-only enabled, and use **Center Gyro** while motionless. Return focus to gameplay, hold L2 and rotate the controller; verify horizontal and vertical directions, release L2, and confirm aim stops. Test inverted Y if needed. Also test motion alone without pressing any other buttons while L2-only is off: this exposes any Xbox polling-idle issue.
4. Test touchpad aim separately from gyro. Touch left/right/top/bottom, lift, and confirm the camera stops. This is a virtual stick surface, not a laptop trackpad or native Xbox touchscreen. Disable it and verify gesture actions return.
5. Enable Calibration’s gameplay switch and raise R2’s start dead zone. Confirm small pulls do nothing and full pulls still reach full input. Switch profiles and verify calibration stays unchanged. Disable gameplay calibration to restore Better xCloud’s mapped response.
6. Enable hold-to-fire, hold R2, release it, open Settings, switch focus away, disconnect and reconnect. Confirm there is no continuing synthetic fire. Test at 2 cycles/second first. Turn it off and verify normal trigger behavior returns.
7. Create two profiles. Select one during game A, another during game B, quit and re-enter both games. Verify recall. Export a saved profile and import it; verify a new profile is created and the custom trigger snapshot still works.
8. Repeat the key input/motor checks over Bluetooth. Record macOS version and connection type with any failure. Test Remote Play separately; title metadata and browser input availability can differ.

## Determining whether a game sends useful trigger feedback

First leave game-trigger translation off and leave the game’s own vibration enabled. Reset the rumble counters. Play a reproducible sequence: idle, pistol shots, automatic fire, reload, damage, movement. Capture approximately 10–20 seconds per scenario and use **Test → Export Diagnostics** after each. The log retains the latest 240 events with game and time labels; export promptly to avoid overwriting the scenario.

Interpretation:

- Main rumble and nonzero trigger fields: the game/stream delivered separate trigger vibration information. Enable translation and compare how it feels.
- Main rumble but zero trigger fields: this session did not expose useful trigger-channel feedback. Do not infer a weapon’s identity from general rumble.
- No rumble events: check the game’s vibration option, ordinary rumble, and the bridge. This does not prove the game has no feedback; interception may have failed.
- `trigger-rumble` advertised and the direct test succeeds: this browser can command that effect on this controller. It still does not prove that Xbox sent a game-authored adaptive resistance effect.

The instrumentation observes the site's decoded vibration callback before Better xCloud scaling; it is not a packet capture of every Xbox protocol message. It cannot establish the absence of an unrelated, undiscovered protocol channel.

## Bigger features and decision gates

**Automatic weapon-specific resistance:** no reliable weapon identifier or authored resistance command has been found in this input/rumble path. First collect the above traces across repeated scenarios. If trigger channels change meaningfully, improve vibration translation based on observed envelopes. If they remain absent/ambiguous, retain title-aware profiles and add explicit weapon-slot selection rather than pretend to recognize weapons. A guarantee of automatic pistol-versus-SMG resistance is not supportable from the present evidence.

**Native game touchscreen input:** requires a verified title-supported touch transport and correct coordinate/contact semantics. Mapping a DualSense touch surface to a stick or macro is implemented; arbitrary native Xbox touchscreen injection is not. The next step is testing a touch-enabled title and its actual supported-input metadata, then documenting a specific transport before adding contacts. Synthetic page touch events alone are not proof that Xbox receives them.

**Additional controllers:** gyro uses Apple's exposed motion capability; adaptive resistance currently uses Apple's DualSense type. Other devices need an individually verified output backend and transport tests. Brand names, including Steam controllers, are not a capability guarantee. If macOS cannot expose a device's motion or output features, consider a narrow HID backend or SDL integration for that model after confirming its documented report protocol—not a wholesale application rewrite.

**If gyro's merged-sample counter does not advance:** inspect the current Xbox patch location and polling/idle behavior. Keep the feature disabled until the actual outgoing sample is observed. Do not compensate by adding a second controller sender that can create duplicate input.

## Verification completed

- Xcode 26.3 Debug app build on this Mac succeeded.
- 33 controller/model checks passed, including legacy encoding, local calibration preservation, rumble curve and new trigger modes.
- 17 isolated preset-store checks passed, including non-destructive import and per-game recall.
- JavaScript tests passed for saturation, explicit rapid-fire release, macro precedence, reset, expiry, controller isolation, paused/hidden page, nonfinite values, capability inspection, raw rumble, and browser/native touch selection.
- Existing settings-manager contract passed.

These checks verify code and modeled bridge behavior. They do not certify a live Xbox session, visual layout, controller force, latency, or firmware compatibility.
