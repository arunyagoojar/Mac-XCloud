# Revision 7 — held steering and touchpad cleanup

- Removed the touchpad-to-mouse UI and native mouse delivery path. Previously saved mouse-mode flags are ignored, so touchpad aiming always reaches the selected stick.
- Left-stick gyro now provides angle-based steering. It saves a neutral left/right tilt, holds the stick while that angle is held, and returns to centre when the controller returns to its saved neutral. It does not require L2 and takes priority over the flick-shift setting.
- Right-stick gyro retains continuous aiming and optional flick shifting.
- Touchpad sensitivity now scales filtered movement on every output update, with an expanded 0.05–3 range. It is no longer applied before filtering. Touch remains laptop-style: slide to turn, stop or lift to stop.

For Forza: select Left stick for gyro, hold the controller comfortably with its face angled toward you, press Center Gyro while level, then tilt it left/right like a steering wheel. Hold the angle to keep steering. Press Center Gyro again if you change your resting position.

Validation: Release build, controller/model contracts including ten seconds of held-angle steering, bidirectional steering and neutral return, plus browser input regression tests. This build still needs live in-game validation; the hold test uses simulated sensor input.
