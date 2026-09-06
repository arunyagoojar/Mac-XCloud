# Revision 4: aiming timing, neutral zones and tilt mode

## What changed

- Corrected a clock-origin bug: a large hardware timestamp could prevent motion-only changes from registering. The browser-facing timestamp now advances monotonically for motion and release, regardless of the hardware clock origin.
- Removed a duplicate timing gate that could skip native controller samples. The existing 60 Hz timer remains; UI publication remains throttled.
- Browser delivery keeps the newest pending sample instead of discarding it while the previous update is in flight. This also preserves pending releases without queuing old samples.
- Gyro returns exactly to zero inside its motion dead zone. Removed the default 12% jump and the smoothing tail at rest. Explicit saved dead-zone compensation remains, with a gradual onset.
- Short 8 ms time-constant filtering reduces sensor noise and follows changes quickly. This is a filter setting, not a measured end-to-end latency claim.
- Touch-down creates a neutral origin. Slide away to move the stick; return to the neutral zone or lift to stop. Each new contact recentres. Light filtering applies to movement, with immediate neutral/release.
- Physical right-stick movement above 12% takes priority over both enhancements; an active touch takes priority over gyro. Gyro/touch do not modify left-stick axes or buttons. Explicit stream calibration and rapid-fire settings still perform their requested overrides.
- Existing gesture blocking during touch aiming remains.
- Added optional Tilt mode. It uses gravity-relative pitch/roll displacement, holds output while tilted, has a 3° neutral zone and reaches full stick at 20°. Standard gyro mode continues to measure movement speed for aiming.

## Try this for gear shifting

1. Quit the previous build and launch this build.
2. Enable gyro and Tilt mode; switch off Only while holding L2.
3. Hold the controller comfortably at rest and press Center Gyro.
4. Focus the game. Tilt forward/backward without pressing another control. Return to centre between shifts. A game that shifts on a new stick press needs a neutral release between shifts.
5. Test steering and throttle while shifting. Then test touch aiming separately: place a finger, slide, return to its starting point, lift.

For camera aiming, switch Tilt mode off. Start with game dead-zone compensation at zero; raise it only if the game's own stick dead zone ignores slow input. Use the game's right-stick dead-zone settings as appropriate.

## Verification and limits

Release build; 49 controller/model checks; preset compatibility checks; polling and bridge checks. The regression tests cover hardware clocks ahead of browser clocks, motion-only input, unchanged steering/throttle/buttons, physical/touch priority, neutral/release, expiry and duplicate movement prevention.

Live latency, sensor behavior and gameplay still require controller testing. The app cannot remove Bluetooth, stream-network or game processing delay. These changes do not add a new high-frequency render loop or redesign the overlay.
