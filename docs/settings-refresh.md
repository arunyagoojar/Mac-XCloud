# Settings refresh and per-game recall

The native settings sidebar now has five groups: Play & Streaming, Controller, Motion & Steering, Profiles & Shortcuts, and App. Detailed steering and gyro diagnostics are collapsed by default. Setting explanations use tooltips where appropriate.

“Remember settings per game” is in Profiles & Shortcuts → Game Profiles. It is enabled by default. A newly encountered game gets an independent copy of the general profile; later visits restore its saved profile. Stable title IDs are preferred, with normalized website titles as a fallback. Leaving the stream restores the general profile. Existing manual profile associations remain supported; intentionally selecting one shared profile for several games still shares that profile.

Profiles include controller effects, motion/steering/touch settings, controller remapping and shortcuts, plus brightness, contrast, saturation, sharpness and volume. App appearance, connection choices and hardware calibration remain global. Title-only identification depends on the website providing a meaningful game title.

Keyboard/mouse gaming settings, activation commands, capture plumbing and the native pointer server are removed. Legacy imported profiles cannot enable them. The bundled upstream Better xCloud script is retained, with its keyboard/mouse gaming modes forcibly disabled by the native bridge. Ordinary website typing and navigation remain available.

Steering keeps the existing sensor estimator and fixed-window smoothing. Maximum steering adds an optional output cap without changing the physical full-turn angle. Diagnostics use lower-rate updates unless expanded, and steering no longer computes unused aiming results. No measured FPS or hardware latency improvement is claimed.

Validation: Xcode source compilation; isolated controller/model and profile-store contracts; JavaScript input delivery, steering range, legacy import and settings callback checks. Hardware feel and final visual acceptance require in-app testing. No downloadable app or archive was produced.
