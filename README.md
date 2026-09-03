# Mac XCloud

A native macOS app for Xbox Cloud Gaming. Mac Xcloud wraps xbox.com/play in a
chrome-less native window and layers on native macOS features:

- Persistent Microsoft/Xbox sign-in (WKWebsiteDataStore)
- Native Settings window (stream quality, stats overlay, region picker, MKB)
- DualSense support: adaptive triggers (21 modes), haptics, LED, touchpad,
  calibration, shortcuts, and macros
- Custom full input presets with a protected Default preset, stored locally in
  `~/Library/Application Support/Xbox Cloud data/`
- Menu-bar status (ping, FPS, bitrate, packet loss) with quick actions and
  direct Left/Right adaptive-trigger mode switching
- Xbox boot animation splash and clarity pipeline (FSR/CAS/USM)

## Releasing updates (one command)

Everything is automated. After changing the app, run:

```bash
./release.sh "What I changed"
```

That commits, pushes, and watches GitHub Actions, which:

1. Builds a Release app with an auto-incrementing version (`1.<build number>`).
2. Signs the archive with Sparkle EdDSA (no Apple Developer account needed).
3. Publishes a GitHub Release and updates the update feed (`appcast.xml`).

Installed copies of Mac Xcloud check the feed hourly and update themselves
automatically; users can also use **Check for Updates…** in the app menu or
the menu bar. Manual workflow trigger: the *Release* workflow on GitHub →
*Run workflow*.

The update signing key lives in the repo secret `SPARKLE_EDDSA_PRIVATE_KEY`;
the matching public key is embedded in `Config/Info.plist`.

## Distribution without an Apple Developer account

There is no free Apple license for notarized Mac distribution — a free Apple
ID only signs for personal use. Mac Xcloud therefore uses the standard
no-cost path:

- Updates delivered through Sparkle are EdDSA-signed, so they install
  automatically without Apple's Gatekeeper.
- **First-time** manual downloads (from GitHub Releases) need one extra step:
  right-click the app → **Open** → confirm. After that it launches normally
  forever.

## Building

Requires Xcode with the macOS 15.7 SDK or newer:

```bash
xcodebuild -project "Mac XCloud.xcodeproj" -scheme "Mac XCloud" \
  -configuration Release -destination "platform=macOS" build
```

The app is sandboxed and needs no special account to build or run. Sign in with
your Microsoft account inside the app on first launch.

## Controller notes

- Adaptive-trigger effects are approximations using Apple's GameController
  APIs; xCloud does not transmit the original DualSense effect data.
- Momentary controller dropouts, if any, are related to macOS
  GameController/WebKit gamepad handling, not the network stream. Prefer a
  wired connection if your Bluetooth link is unstable.

## Credits

- [Better xCloud](https://github.com/redphx/better-xcloud) by redphx — bundled
  engine (v6.7.12), MIT License. © redphx and Better xCloud contributors.
- Xbox Cloud Gaming is a service of Microsoft. This project is an independent
  native wrapper and is not affiliated with or endorsed by Microsoft.
