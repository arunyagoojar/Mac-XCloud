# Revision 13 — small-angle steering and full-lock tracking

Scope: steering only. Gyro aiming, touchpad processing, web input routing, profile settings and streaming performance settings are unchanged.

## Findings

The saved Default profile inspected during diagnosis had approximately 25.065° full lock per side, 0.50 smoothing, 1.003 response exponent and zero game dead-zone compensation. This confirms the angle setting was persisted. It does not establish which Forza settings were active or measure physical-controller angle accuracy.

Revision 12 allowed gyro prediction to move the estimate away from the absolute gravity/acceleration angle. If rate projection disagrees with actual wheel rotation, smoothing delays correction and creates a movement-dependent angle error. This is a reproducible model weakness and a plausible contributor to the user's symptoms, not a confirmed live-controller diagnosis.

## Fix

For valid angle reports, constrain the predicted step between the previous filtered position and the measured angle. Prediction can accelerate convergence but cannot pull against the absolute angle or overshoot it. During rotation, shorten the correction time constant according to rotation-rate magnitude. Keep stationary noise filtering and confidence weighting for acceleration disturbances. Apply the correction speed limit only to low-confidence reports; trustworthy turns are no longer restricted by that limit.

There is no new movement dead zone or change to the angle-to-stick gain. Existing held-angle, saved-center and short-dropout behavior remains. Smoothing still has a finite settling time, but no longer allows an opposing prediction to accumulate an offset on valid reports.

Live steering now distinguishes measured angle, filtered angle and calculated steering percentage. These are app-side diagnostics; they do not measure the game's front-wheel angle. Last stream delivery remains available separately.

## Validation

Release build succeeded. All 132 controller/model checks and the gamepad polling, native bridge and settings-manager JavaScript suites passed. New tests cover 1°/second motion and 25° turns in both directions at smoothing 0, 0.5 and 1, deliberately using opposing gyro projection. Slow-angle error stays below 0.086° in those synthetic traces; 25° turns reach over 99% stick output. Revision 12 fails the new slow-angle regression test. These numbers are model-test results, not hardware measurements.

## Next Forza test

Keep your 25° setting. Center while holding the controller still in your normal driving grip. Test small left/right leans, then 25° turns. The new live readout should show near ±100% output at the selected angle. If measured angle is wrong, report measured versus physical angle. If filtered angle differs substantially, report both. If app output is correct but the game barely steers, check the game's steering inner dead zone and speed-dependent steering response. With app compensation at zero, a nonzero game dead zone can still swallow small inputs. For proportional center control, use zero for both when available.

This remains an Xbox stick mapping. It does not bypass Forza's controller steering assists or become a native force-feedback wheel input device. No live in-game verification was performed for this revision.
