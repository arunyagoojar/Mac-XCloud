# Steering temporal smoothing — source-only update

## Why revision 13 felt abrupt

Revision 13 shortened its filter time constant as rotation speed increased. Its predictor could also jump directly to the measured angle. This favored tracking speed over smooth transitions: increasing the smoothing control could have little effect while moving. Smoothing the angle alone also lets a nonlinear response curve or game dead-zone compensation introduce an abrupt change afterward.

## Research and decision

Reviewed [JoyShockMapper's gyro smoothing controls](https://github.com/JibbSmart/JoyShockMapper/blob/master/README.md), [Keijiro's critically damped smoothing example](https://github.com/keijiro/SmoothingTest), and [Ryan Juckett's derivation of damped springs](https://www.ryanjuckett.com/damped-springs/). JoyShockMapper explains the smoothing/latency tradeoff and uses speed-dependent smoothing for gyro aiming. That behavior is not the requested consistent wheel-position transition. The critically damped position response is a better fit for this requirement: it maintains position and velocity and approaches a new held target without oscillation.

Implemented the closed-form critical-damping equations directly in Swift. No dependency or copied repository source was added. This is a targeted choice, not a claim that one filter is universally best for controllers or Forza.

## Changes

- Separate absolute wheel-position estimation from final steering response. Trusted gravity/acceleration determines position; gyro remains available to bridge brief unreliable reports. Removed revision 13's motion-dependent smoothing bypass.
- Apply smoothing AFTER angle range, response curve, inversion and game dead-zone compensation, so all virtual-wheel output follows the same transition.
- Keep position and velocity across polls. Evaluate the analytic response using elapsed time; no queues, extra timer or increased polling rate. New output values progress at the existing 60 Hz poll cadence, including between changes in the sensor target. They are floating-point values, not integer-degree steps. Stream/game sampling can still differ.
- Display smoothing as 30–150 ms to reach 90% of a held step; the existing midpoint maps to 90 ms. More smoothing always increases this transition time. It does not change full-lock travel, response gain, or the final held value. Any temporal smoothing necessarily adds delay.
- Clear response momentum when centering, changing steering mode, disconnecting, receiving invalid input or encountering a long scheduling gap. Brief angle-sensor disturbances retain the bounded recovery path.
- Live display now distinguishes Angle, Target and Smoothed output. Gyro aiming, touchpad behavior, physical-stick input and web bridge remain unchanged.

A critically damped response starting at rest does not bounce around a held target. Reversing during a turn briefly decelerates the previous motion; the implementation bounds output and clamps target crossing. This provides continuity rather than an instant velocity reset.

## Validation

149 controller/model checks and 17 isolated preset-store checks passed, as did the gamepad polling, native bridge and settings-manager JavaScript suites. Tests now exercise the final response for slow steering, rather than only the angle estimator. Additional checks cover the stated 90% response times, intermediate values during a 15° step, monotonic held-step convergence, substantial differences across smoothing settings, identical analytic results across time subdivisions, tiny held targets, smoothing after dead-zone compensation, reversals, resetting and scheduling gaps. Existing sustained-angle, sensor-fallback and dropout tests still pass.

Xcode Release compilation succeeded; no downloadable application was packaged. In-game feel and physical-controller accuracy still require the user's test.

## Testing in Xcode

Run the application from the source project. Start with 90 ms smoothing and the existing turning-angle setting. Compare 30 ms with 150 ms while turning through the center; the latter should visibly soften the Smoothed output while the Target responds immediately. Hold the angle: output should settle on that target without requiring more rotation. Test a quick reversal afterward. Forza's own inner dead zone, response curve and speed-dependent assists remain downstream of this Xbox stick mapping.

## Cleanup

Removed 18 generated revision application bundles and ZIPs from the workspace outputs directory. Preserved source copies, notes and patches. No matching revision packages were present in Downloads; its controller diagnostic JSON was retained. No running Mac XCloud process was found before cleanup.
