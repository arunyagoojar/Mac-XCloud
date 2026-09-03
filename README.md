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

## Releasing updates (fully automatic)

You never need to export, zip, or upload anything. **Every push to `main`
releases by itself**: GitHub Actions builds the app, signs it, publishes a
GitHub Release, and updates the feed that installed apps auto-update from.

```bash
git add -A && git commit -m "What I changed" && git push
```

(Or run `./release.sh "What I changed"` — it does exactly the above plus
watches the build for you. Both are equivalent.)

**Version numbers are optional.** Sparkle orders updates by build number,
which increases automatically on every push — you can change code and push
forever without touching versions. If you *do* want to name a version (say
`1.5` or `2.0`), just change **MARKETING_VERSION** in the target's Build
Settings before pushing; that exact number is released and displayed. Leave
it at the default `1` and releases show as `1.<build number>`.

To update the version in Xcode: target *Mac XCloud* → *Signing & Capabilities*
is not it — go to **Build Settings → Versioning → Marketing Version**. Or ask
your assistant to bump it.

Manual workflow trigger: the *Release* workflow on GitHub → *Run workflow*.

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
