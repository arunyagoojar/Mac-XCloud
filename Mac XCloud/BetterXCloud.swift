//
//  BetterXCloud.swift
//  Mac XCloud
//
//  Injects the MIT-licensed Better xCloud userscript (https://github.com/redphx/better-xcloud)
//  into xbox.com/play pages at document-start, and appends a small bridge
//  (window.BxCBridge) so the native settings overlay can read and change its
//  live settings.
//

import Foundation
import WebKit

enum SettingsScopeKey {
    case global
    case stream
}

enum NativeSettingsMirror {
    private static let globalKey = "nativeBetterXcloudGlobal"
    private static let streamKey = "nativeBetterXcloudStream"

    static func values(for scope: SettingsScopeKey) -> [String: Any] {
        let key = scope == .global ? globalKey : streamKey
        guard let data = UserDefaults.standard.data(forKey: key),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func save(_ value: Any, for setting: String, scope: SettingsScopeKey) {
        let key = scope == .global ? globalKey : streamKey
        var values = self.values(for: scope)
        values[setting] = value
        if JSONSerialization.isValidJSONObject(values),
           let data = try? JSONSerialization.data(withJSONObject: values) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func applySafeRendererRecoveryIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: "nativeRendererRecoveryVersion") < 3 else { return }
        save("webgl2", for: "video.player.type", scope: .stream)
        save("high-performance", for: "video.player.powerPreference", scope: .stream)
        save("cas", for: "video.processing", scope: .stream)
        save("quality", for: "video.processing.mode", scope: .stream)
        save(2, for: "video.processing.sharpness", scope: .stream)
        save("webgl-cas", for: "app.clarityPipeline", scope: .global)
        defaults.set(3, forKey: "nativeRendererRecoveryVersion")
    }

    static func javascriptObject(for scope: SettingsScopeKey) -> String {
        let values = self.values(for: scope)
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

enum BetterXCloud {

    static let resourceURL = Bundle.main.url(forResource: "better-xcloud", withExtension: "js")

    /// Safe WebKit feature shims. enumerateDevices returns an empty list until
    /// the app ever exposes capture devices; xCloud handles an empty list but
    /// crashes when mediaDevices itself is undefined.
    static let compatibilityScript = #"""
    (function () {
      try {
        if (!navigator.mediaDevices) {
          var fake = {
            enumerateDevices: function () { return Promise.resolve([]); },
            getUserMedia: function () { return Promise.reject(new DOMException('Media capture is unavailable', 'NotAllowedError')); },
            addEventListener: function () {}, removeEventListener: function () {}
          };
          Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: fake });
        } else if (typeof navigator.mediaDevices.enumerateDevices !== 'function') {
          navigator.mediaDevices.enumerateDevices = function () { return Promise.resolve([]); };
        }
      } catch (e) {}

      try {
        var original = RTCRtpReceiver.getCapabilities.bind(RTCRtpReceiver);
        RTCRtpReceiver.getCapabilities = function (kind) {
          var caps = original(kind) || { codecs: [], headerExtensions: [] };
          if (kind !== 'video') return caps;
          var codecs = Array.isArray(caps.codecs) ? caps.codecs.slice() : [];
          var profiles = [
            'profile-level-id=42e01f;packetization-mode=1',
            'profile-level-id=4d401f;packetization-mode=1',
            'profile-level-id=64001f;packetization-mode=1'
          ];
          profiles.forEach(function (fmtp) {
            /* Compare the exact profile-level-id (e.g. profile-level-id=4d401f),
               not a short prefix — a prefix like "profile-level-id=4" also
               matches WebKit's own baseline codec, which made the shim skip
               adding the Main/High profiles entirely. */
            var profile = (fmtp.split(';')[0] || '').toLowerCase();
            if (!codecs.some(function (c) { return (c.mimeType || '').toLowerCase() === 'video/h264' && (c.sdpFmtpLine || '').toLowerCase().indexOf(profile) !== -1; })) {
              codecs.push({ mimeType: 'video/H264', clockRate: 90000, sdpFmtpLine: fmtp });
            }
          });
          return Object.assign({}, caps, { codecs: codecs });
        };
      } catch (e) {}
    })();
    """#

    /// WKUserScripts for the main web view, in execution order.
    static func userScripts() -> [WKUserScript] {
        NativeSettingsMirror.applySafeRendererRecoveryIfNeeded()
        var scripts: [WKUserScript] = []

        // 0. WebKit compatibility shims, installed before Xbox/BxC evaluate
        //    browser features. WKWebView can omit mediaDevices entirely and
        //    under-report decodable H.264 profiles even though AVFoundation can
        //    decode them, which caused Xbox's error route and BxC's visual-
        //    quality selector to normalize every choice back to Default.
        scripts.append(WKUserScript(source: compatibilityScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // 1. Restore the native settings mirror, then seed M1-optimized values
        //    only where neither side has a saved user choice. The app never
        //    overwrites a later user preference on launch.
        let mirroredGlobal = NativeSettingsMirror.javascriptObject(for: .global)
        let mirroredStream = NativeSettingsMirror.javascriptObject(for: .stream)
        let defaults = """
        (function () {
          try {
            var global = JSON.parse(localStorage.getItem("BetterXcloud") || "{}");
            var stream = JSON.parse(localStorage.getItem("BetterXcloud.Stream") || "{}");
            var mirrorGlobal = \(mirroredGlobal);
            var mirrorStream = \(mirroredStream);
            Object.assign(global, mirrorGlobal);
            Object.assign(stream, mirrorStream);

            var optimizedGlobal = {
              "server.region": "default",
              "stream.video.resolution": "1080p-hq",
              "stream.video.codecProfile": "high",
              "stream.video.maxBitrate": 0,
              "stream.video.preventResolutionDrops": false,
              "server.ipv6.prefer": true,
              "ui.splashVideo.skip": true,
              "ui.feedbackDialog.disabled": true,
              "ui.reduceAnimations": false,
              "ui.controllerFriendly": true,
              "ui.systemMenu.hideHandle": true,
              "ui.controllerStatus.show": false,
              "loadingScreen.gameArt.show": true,
              "loadingScreen.waitTime.show": true,
              "block.tracking": true
            };
            var optimizedStream = {
              "video.player.type": "webgl2",
              "video.player.powerPreference": "high-performance",
              "video.processing": "cas",
              "video.processing.mode": "quality",
              "video.processing.sharpness": 2,
              "video.maxFps": 60,
              "video.brightness": 100,
              "video.contrast": 100,
              "video.saturation": 100,
              "audio.volume": 100,
              "stats.showWhenPlaying": false,
              "stats.items": ["ping", "fps", "btr", "dt", "pl", "fl"],
              "stats.position": "top-right",
              "stats.opacity.all": 90,
              "stats.opacity.background": 65,
              "stats.colors": true,
              "controller.pollingRate": 4
            };
            var defaultsVersion = parseInt(localStorage.getItem("XCG.NativeDefaultsVersion") || "0", 10);
            if (defaultsVersion < 3) {
              /* v3 recovery: an experimental WebGPU/FSR renderer could remain
                 persisted across app rollbacks and black-screen the stream.
                 Reset only the rendering pipeline once; account/session and
                 every unrelated preference remain untouched. */
              stream["video.player.type"] = "webgl2";
              stream["video.player.powerPreference"] = "high-performance";
              stream["video.processing"] = "cas";
              stream["video.processing.mode"] = "quality";
              stream["video.processing.sharpness"] = 2;
              localStorage.setItem("XCG.Upscaler", "off");
              localStorage.setItem("XCG.NativeDefaultsVersion", "3");
            } else {
              for (var k in optimizedGlobal) if (!(k in global)) global[k] = optimizedGlobal[k];
              for (var s in optimizedStream) if (!(s in stream)) stream[s] = optimizedStream[s];
            }
            // This app no longer exposes keyboard/mouse gaming or pointer capture.
            global["mkb.enabled"] = false;
            global["nativeMkb.mode"] = "off";
            global["nativeMkb.forcedGames"] = [];
            stream["mkb.p2.slot"] = 0;
            global["ui.systemMenu.hideHandle"] = true;
            global["ui.controllerStatus.show"] = false;
            localStorage.setItem("BetterXcloud", JSON.stringify(global));
            localStorage.setItem("BetterXcloud.Stream", JSON.stringify(stream));
          } catch (e) { console.error("[XCG] settings bootstrap failed", e); }
        })();
        """
        scripts.append(WKUserScript(source: defaults, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // 2. Flags the script reads at startup.
        let flags = """
        window.BX_FLAGS = Object.assign({}, window.BX_FLAGS || {}, {
          Debug: false,
          SafariWorkaround: true,
          CheckForUpdate: true,
          EnableXcloudLogging: false,
          EnableWebGPURenderer: true
        });
        """
        scripts.append(WKUserScript(source: flags, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // 3. The userscript itself, wrapped in a location guard (WKUserScript
        //    can't do @match patterns) plus a native bridge.
        if let url = resourceURL, let source = try? String(contentsOf: url, encoding: .utf8) {
            scripts.append(WKUserScript(source: wrappedScript(source: source), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        // 4. Auto-continue the "no controller connected" dialog when a native
        //    controller is connected (WKWebView exposes gamepads late).
        scripts.append(WKUserScript(source: autoContinueScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        // 5. Hide Better xCloud's injected UI (the native app owns the
        //    interface) and restyle the stats bar to match macOS.
        scripts.append(WKUserScript(source: nativeStyleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // 6. Route the site's fullscreen requests to native window fullscreen
        //    (WKWebView doesn't implement the browser Fullscreen API, which is
        //    why Xbox hides its fullscreen button).
        scripts.append(WKUserScript(source: fullscreenBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // 7. Auto-hide the mouse cursor while a controller is connected and
        //    the mouse is idle (native side enables/disables this).
        scripts.append(WKUserScript(source: cursorHideScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // 8. AMD FSR 1 (EASU + RCAS) upscaler engine, rendered at native
        //    devicePixelRatio over the stream video.
        if let upscaler = upscalerScript() {
            scripts.append(upscaler)
        }

        return scripts
    }

    /// The upscaler engine ships precomposed (FSR1 EASU/RCAS blocks inlined,
    /// AMD MIT license attributed in the file header).
    private static func upscalerScript() -> WKUserScript? {
        guard let coreURL = Bundle.main.url(forResource: "upscaler-core", withExtension: "js"),
              let source = try? String(contentsOf: coreURL, encoding: .utf8) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// The native side enables this when a controller is connected. After 2.5s
    /// of no mouse movement the cursor hides; any movement brings it back.
    static let cursorHideScript = #"""
    (function () {
      var enabled = false;
      var idleTimer = null;

      function show() {
        try { document.documentElement.classList.remove("xcg-hide-cursor"); } catch (e) {}
      }
      function hideSoon() {
        if (!enabled) { show(); return; }
        if (idleTimer) clearTimeout(idleTimer);
        idleTimer = setTimeout(function () {
          try { document.documentElement.classList.add("xcg-hide-cursor"); } catch (e) {}
        }, 2500);
      }

      ["mousemove", "mousedown", "wheel"].forEach(function (name) {
        window.addEventListener(name, function () { show(); hideSoon(); }, { passive: true });
      });
      window.addEventListener("message", function (event) {
        var data = event.data;
        if (data && data.type === "xcg-cursor-hide") {
          enabled = !!data.enabled;
          if (!enabled) { if (idleTimer) clearTimeout(idleTimer); show(); } else { hideSoon(); }
        }
        if (data && data.type === "xcg-battery") {
          try {
            var bar = document.querySelector(".bx-stats-bar");
            if (!bar) return;
            var el = document.getElementById("xcg-batt");
            if (!el) {
              el = document.createElement("span");
              el.id = "xcg-batt";
              el.style.opacity = "0.95";
              bar.appendChild(el);
            }
            el.textContent = "  |  " + data.text;
          } catch (e) {}
        }
      });
    })();
    """#

    /// Spoofs Fullscreen API support so Xbox keeps its fullscreen button, and
    /// forwards requests to the native window's fullscreen toggle.
    static let fullscreenBridgeScript = """
    (function () {
      "use strict";
      try {
        var __p = location.pathname || "";
        var __ok = location.hostname === "www.xbox.com" && (__p.indexOf("/play") !== -1 || __p.indexOf("/auth/msa") === 0);
        if (!__ok) return;

        Object.defineProperty(document, "fullscreenEnabled", {
          configurable: true,
          get: function () { return true; }
        });
        Object.defineProperty(document, "webkitFullscreenEnabled", {
          configurable: true,
          get: function () { return true; }
        });

        function enterNativeFullscreen() {
          try { window.webkit.messageHandlers.spikeHandler.postMessage({ type: "app-fullscreen" }); } catch (e) {}
        }

        Element.prototype.requestFullscreen = function () {
          enterNativeFullscreen();
          return Promise.resolve().then(function () {
            document.dispatchEvent(new Event("fullscreenchange"));
          });
        };
        Element.prototype.webkitRequestFullscreen = function () {
          enterNativeFullscreen();
          return Promise.resolve();
        };
        document.exitFullscreen = function () {
          enterNativeFullscreen();
          return Promise.resolve().then(function () {
            document.dispatchEvent(new Event("fullscreenchange"));
          });
        };
        document.webkitExitFullscreen = function () {
          enterNativeFullscreen();
          return Promise.resolve();
        };
      } catch (e) { console.error("[XCG] fullscreen bridge failed", e); }
    })();
    """

    private static func wrappedScript(source: String) -> String {
        // Strip source-map comments; keep everything else intact.
        let stripped = source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//#") }
            .joined(separator: "\n")
        // The final send path handles both physical and native-only changes.
        let cleaned = stripped
        let macroOverlayAvailable = true

        let inputAdapter = #"""
        // Install before Better xCloud or Xbox captures getGamepads.
        // Keep the actual controller identity, buttons and actuator; change only input values.
        const __xcgReadPhysicalPads = navigator.getGamepads.bind(navigator);
        const __xcgPollInput = {values:{}, at:-Infinity, reads:0, applied:0, lastAxes:[], lastLeftAxes:[], lastAllAxes:[], clock:0, lastHardware:-Infinity, wasActive:false, error:""};
        window.__xcgPollInput = __xcgPollInput;
        const __xcgPollGamepads = function() {
          const pads = Array.from(__xcgReadPhysicalPads());
          __xcgPollInput.reads++;
          const connected = pads.filter(p => p && p.connected !== false);
          const now = performance.now(), n = __xcgPollInput.values;
          const active = now - __xcgPollInput.at < 200 && n.nativeControllerCount === 1 &&
            !document.hidden && !window.BX_EXPOSED?.disableGamepadPolling;
          if (connected.length !== 1 || !Number.isFinite(__xcgPollInput.at)) return pads;
          const p = connected[0];
          // A standard four-axis controller is required; leave virtual MKB alone.
          if (p.mapping !== "standard" || p.axes.length < 4 || /virtual/i.test(p.id)) return pads;
          const axes = Array.from(p.axes), buttons = Array.from(p.buttons);
          const clamp = v => Math.max(-1, Math.min(1, v));
          if (active) {
            ["LeftThumbXAxis","LeftThumbYAxis","RightThumbXAxis","RightThumbYAxis"].forEach((k,i) => {
              if (Number.isFinite(n[k])) axes[i] = clamp(n[k] * (i % 2 ? -1 : 1));
            });
            // Native GameController has positive Y up; the browser has positive Y down.
            const gyroBase = n.gyroAxisBase === 0 ? 0 : 2;
            const touchBase = n.touchAxisBase === 0 ? 0 : 2;
            const physicalMagnitude = base => Math.hypot(p.axes[base], p.axes[base+1]);
            if (n.touchpadAim === 1 && physicalMagnitude(touchBase) <= 0.12) {
              axes[touchBase] = Number.isFinite(n.touchX) ? clamp(n.touchX) : 0;
              axes[touchBase+1] = Number.isFinite(n.touchY) ? clamp(-n.touchY) : 0;
            }
            const touchOwnsGyroStick = n.touchActive === 1 &&
              n.touchpadAim === 1 && touchBase === gyroBase;
            if (!touchOwnsGyroStick && (Number.isFinite(n.gyroX) || Number.isFinite(n.gyroY))) {
              const magnitude = physicalMagnitude(gyroBase);
              if (magnitude <= 0.05) { axes[gyroBase] = 0; axes[gyroBase+1] = 0; }
              // Fade out game-dead-zone compensation continuously as physical input increases.
              const blend = Math.max(0,Math.min(1,(magnitude - 0.05) / 0.25));
              const combine = (coarse,fine) => Number.isFinite(fine) ? coarse + (fine - coarse) * blend : coarse;
              const x = combine(n.gyroX,n.gyroFineX);
              const y = combine(n.gyroY,n.gyroFineY);
              if (Number.isFinite(x)) axes[gyroBase] = clamp(axes[gyroBase] + x);
              if (Number.isFinite(y)) axes[gyroBase+1] = clamp(axes[gyroBase+1] - y);
            }
            ["LeftTrigger","RightTrigger"].forEach((k,i) => {
              if (!Number.isFinite(n[k]) || !buttons[i+6]) return;
              const value = Math.max(0, Math.min(1,n[k]));
              buttons[i+6] = {value, pressed:value > 0.5, touched:value > 0};
            });
            __xcgPollInput.applied++;
          }
          __xcgPollInput.lastAxes = axes.slice(2,4); // Legacy right-stick diagnostics.
          __xcgPollInput.lastLeftAxes = axes.slice(0,2);
          __xcgPollInput.lastAllAxes = axes.slice(0,4);
          // Motion alone must invalidate Xbox's timestamp-based unchanged-input skip.
          // At expiry, publish a newer timestamp with physical values to release aiming.
          // WebKit hardware timestamps can use a different origin from performance.now().
          // Never let a large hardware timestamp freeze motion-only updates.
          if (active || __xcgPollInput.wasActive || p.timestamp !== __xcgPollInput.lastHardware) {
            __xcgPollInput.clock = Math.max(__xcgPollInput.clock, p.timestamp || 0, now) + 0.01;
          }
          __xcgPollInput.wasActive = active;
          __xcgPollInput.lastHardware = p.timestamp;
          const timestamp = __xcgPollInput.clock;
          const proxy = new Proxy(p, {get(target,key) {
            if (key === "axes") return axes;
            if (key === "buttons") return buttons;
            if (key === "timestamp") return timestamp;
            const value = Reflect.get(target,key,target);
            return typeof value === "function" ? value.bind(target) : value;
          }});
          return pads.map(pad => pad === p ? proxy : pad);
        };
        try { navigator.getGamepads = __xcgPollGamepads; }
        catch(error) { __xcgPollInput.error = String(error); }
        __xcgPollInput.installed = navigator.getGamepads === __xcgPollGamepads;
        """#

        let bridge = #"""
        const __xcgMacroButtonFields = Object.freeze({
          A:true, B:true, X:true, Y:true, LeftShoulder:true, RightShoulder:true,
          LeftTrigger:true, RightTrigger:true, View:true, Menu:true,
          LeftThumb:true, RightThumb:true, DPadUp:true, DPadDown:true,
          DPadLeft:true, DPadRight:true, Nexus:true, Share:true
        });
        const __xcgMacroButtons = Object.create(null);
        let __xcgNativeInput = {}, __xcgNativeInputAt = 0, __xcgMergedSamples = 0;
        const __xcgBridgeCapability = {
          profileCapture: true,
          macroOverlay: \#(macroOverlayAvailable ? "true" : "false"),
          nativeRumble: false
        };

        let __xcgChannel = null, __xcgOriginalSend = null, __xcgBase = [], __xcgLastNative = false;
        let __xcgLastSendAt = 0, __xcgInputError = "", __xcgFlushTimer = null;
        let __xcgOutgoingCount = 0, __xcgLastOutgoing = [];
        function __xcgRecordOutgoing(samples) {
          __xcgOutgoingCount++;
          __xcgLastOutgoing = samples.map(sample => ({...sample}));
        }
        function __xcgEnsureInputSink() {
          const channel = window.BX_EXPOSED?.inputChannel;
          if (!channel || typeof channel.sendGamepadInput !== "function") return false;
          if (channel === __xcgChannel) return true;
          __xcgChannel = channel; __xcgBase = []; __xcgLastNative = false;
          __xcgOriginalSend = channel.sendGamepadInput.bind(channel);
          channel.sendGamepadInput = function(timestamp, samples) {
            if (!Array.isArray(samples)) return __xcgOriginalSend(timestamp, samples);
            // Cache immutable physical baselines. Never add gyro repeatedly to a reused sample.
            __xcgBase = samples.map(sample => ({...sample}));
            const output = samples.map(sample => window.BxCBridge.mergeMacroButtons({...sample}));
            __xcgLastSendAt = performance.now();
            const result = __xcgOriginalSend(timestamp, output);
            __xcgRecordOutgoing(output);
            return result;
          };
          return true;
        }
        function __xcgFlushNative() {
          try {
            if (window.__xcgPollInput?.installed && !Object.keys(__xcgMacroButtons).length) return;
            if (!__xcgEnsureInputSink() || !__xcgBase.length) return;
            const fresh = performance.now() - __xcgNativeInputAt < 200;
            const active = fresh && Object.keys(__xcgNativeInput).some(k => k !== "nativeControllerCount") || Object.keys(__xcgMacroButtons).length > 0;
            if (!active && !__xcgLastNative) return;
            const wait = 1000 / 60 - (performance.now() - __xcgLastSendAt);
            if (wait > 0) {
              if (__xcgFlushTimer === null) __xcgFlushTimer = setTimeout(() => { __xcgFlushTimer = null; __xcgFlushNative(); }, wait);
              return;
            }
            const pads = Array.from(navigator.getGamepads()).filter(Boolean);
            if (pads.length !== 1 || !__xcgBase.some(s => s.GamepadIndex === pads[0].index)) {
              __xcgBase = []; __xcgLastNative = false; return;
            }
            const output = __xcgBase.map(sample => window.BxCBridge.mergeMacroButtons({...sample, Dirty:true}));
            __xcgLastNative = !!active;
            __xcgLastSendAt = performance.now();
            __xcgOriginalSend(performance.now(), output);
            __xcgRecordOutgoing(output);
          } catch (error) { __xcgInputError = String(error); }
        }
        // Expiry sends the unmodified baseline once, including a release when motion stops.
        setInterval(function() {
          __xcgEnsureInputSink();
          if (__xcgLastNative && performance.now() - __xcgNativeInputAt >= 200) __xcgFlushNative();
        }, 100);

        function __xcgFinite(value, fallback, min, max) {
          value = Number(value);
          if (!Number.isFinite(value)) return fallback;
          if (typeof min === "number") value = Math.max(min, value);
          if (typeof max === "number") value = Math.min(max, value);
          return value;
        }
        function __xcgPatchBundledSource() {
          /* Patcher.playVibration prepends vibration_adjust_default to the site's
             playVibration body. Appending here therefore reports adjusted values
             and can return before the browser actuator receives them. */
          try {
            if (typeof vibration_adjust_default !== "string") throw new Error("vibration adjustment unavailable");
            var zeroIntensityMarker = "e.repeat=0;return";
            if (vibration_adjust_default.indexOf(zeroIntensityMarker) !== -1) {
              vibration_adjust_default = vibration_adjust_default.replace(
                zeroIntensityMarker,
                "e.repeat=0,e.leftMotorPercent=0,e.rightMotorPercent=0,e.leftTriggerMotorPercent=0,e.rightTriggerMotorPercent=0"
              );
            }
            if (vibration_adjust_default.indexOf("__xcgPostNativeRumble") === -1) {
              vibration_adjust_default = "if(e)e.__xcgRaw={leftMotorPercent:Number(e.leftMotorPercent)||0,rightMotorPercent:Number(e.rightMotorPercent)||0,leftTriggerMotorPercent:Number(e.leftTriggerMotorPercent)||0,rightTriggerMotorPercent:Number(e.rightTriggerMotorPercent)||0};" + vibration_adjust_default;
              vibration_adjust_default += ";if(window.__xcgPostNativeRumble&&window.__xcgPostNativeRumble(e))return";
            }
            __xcgBridgeCapability.nativeRumble = true;
          } catch (error) {
            __xcgBridgeCapability.nativeRumble = false;
            try { console.error("[XCG] Native rumble bridge disabled:", error); } catch (_) {}
          }
        }

        window.__xcgPostNativeRumble = function (event) {
          try {
            var pad = event && event.gamepad;
            var finite = function (value, fallback, min, max) { return __xcgFinite(value, fallback, min, max); };
            var payload = {
              type: "native-rumble",
              raw: event && event.__xcgRaw || {},
              gamepadID: pad && typeof pad.id === "string" ? pad.id : "",
              gamepadId: pad && typeof pad.id === "string" ? pad.id : "",
              gamepadIndex: finite(event && (event.gamepadIndex ?? (pad && pad.index)), -1, -1, 255),
              mainMotorPercents: {
                left: finite(event && event.leftMotorPercent, 0, 0, 100),
                right: finite(event && event.rightMotorPercent, 0, 0, 100)
              },
              triggerMotorPercents: {
                left: finite(event && event.leftTriggerMotorPercent, 0, 0, 100),
                right: finite(event && event.rightTriggerMotorPercent, 0, 0, 100)
              },
              leftMotorPercent: finite(event && event.leftMotorPercent, 0, 0, 100),
              rightMotorPercent: finite(event && event.rightMotorPercent, 0, 0, 100),
              leftTriggerMotorPercent: finite(event && event.leftTriggerMotorPercent, 0, 0, 100),
              rightTriggerMotorPercent: finite(event && event.rightTriggerMotorPercent, 0, 0, 100)
            };
            if (event && (event.durationMs !== undefined || event.duration !== undefined)) {
              payload.duration = finite(event.duration ?? event.durationMs, 0, 0, 600000);
              payload.durationMs = finite(event.durationMs ?? event.duration, 0, 0, 600000);
            }
            if (event && event.repeat !== undefined) payload.repeat = finite(event.repeat, 0, 0, 1000);
            window.webkit.messageHandlers.spikeHandler.postMessage(payload);
          } catch (error) { return false; }
          // The native handler owns rumble for this app. Returning true stops
          // Better xCloud from also driving the browser actuator a second time.
          return true;
        };

        window.BxCBridge = {
          capabilities: __xcgBridgeCapability,
          controllerDiagnostics: function() {
            const pads = Array.from(navigator.getGamepads()).filter(Boolean);
            return {
              inputHookInstalled: __xcgEnsureInputSink(),
              pollingAdapter: window.__xcgPollInput || null,
              mouseSupportedInputTypes: STATES.currentStream?.titleInfo?.details?.supportedInputTypes ?? [],
              physicalBaselineSamples: __xcgBase.length,
              lastInputError: __xcgInputError,
              lastSendAgeMs: Math.round(performance.now() - __xcgLastSendAt),
              outgoingSendCount: __xcgOutgoingCount,
              lastOutgoingSamples: __xcgLastOutgoing.map(sample => ({...sample})),
              mergedSamples: __xcgMergedSamples,
              nativeInputFresh: performance.now() - __xcgNativeInputAt < 200,
              webHID: !!navigator.hid,
              pads: pads.map(p => ({ id:p.id, index:p.index, axes:p.axes.length, buttons:p.buttons.length,
                effects:Array.from(p.vibrationActuator?.effects || []), touchSurfaceAPI:"touches" in p,
                motionAPI:"pose" in p, mapping:p.mapping }))
            };
          },
          testWebRumble: async function(trigger) {
            const pads = Array.from(navigator.getGamepads()).filter(Boolean);
            if (pads.length !== 1) return "Connect exactly one browser-visible controller";
            const actuator = pads[0].vibrationActuator;
            const effect = trigger ? "trigger-rumble" : "dual-rumble";
            if (!actuator || !Array.from(actuator.effects || []).includes(effect)) return effect + " is not advertised by this browser/controller";
            try { return await actuator.playEffect(effect, {duration:200, startDelay:0, strongMagnitude:trigger?0:0.3, weakMagnitude:trigger?0:0.3, leftTrigger:trigger?0.3:0, rightTrigger:trigger?0.3:0}); }
            catch(error) { return String(error); }
          },
          updateNativeInput: function(values) {
            __xcgNativeInput = values || {};
            __xcgNativeInputAt = performance.now();
            if (window.__xcgPollInput) {
              window.__xcgPollInput.values = __xcgNativeInput;
              window.__xcgPollInput.at = __xcgNativeInputAt;
            }
            __xcgFlushNative();
            return window.__xcgPollInput?.installed || __xcgChannel !== null;
          },
          updateMacroButtons: function (delta) {
            delta = delta && typeof delta === "object" ? delta : {};
            Object.keys(delta).forEach(function (key) {
              if (!__xcgMacroButtonFields[key]) return;
              if (delta[key] === null || delta[key] === undefined) {
                delete __xcgMacroButtons[key];
                return;
              }
              var value = Number(delta[key]);
              if (Number.isFinite(value)) __xcgMacroButtons[key] = Math.max(0, Math.min(1, value));
              else delete __xcgMacroButtons[key];
            });
            __xcgFlushNative();
            return true;
          },
          resetMacroButtons: function () {
            __xcgNativeInput = {};
            if (window.__xcgPollInput) { window.__xcgPollInput.values = {}; window.__xcgPollInput.at = performance.now(); }
            Object.keys(__xcgMacroButtons).forEach(function (key) { delete __xcgMacroButtons[key]; });
            __xcgFlushNative();
            return true;
          },
          mergeMacroButtons: function (sample) {
            if (!__xcgBridgeCapability.macroOverlay || !sample || typeof sample !== "object") return sample;
            let pads = Array.from(navigator.getGamepads()).filter(Boolean);
            if (!window.__xcgPollInput?.installed && sample.Virtual !== true && pads.length === 1 && sample.GamepadIndex === pads[0].index &&
                __xcgNativeInput.nativeControllerCount === 1 &&
                performance.now() - __xcgNativeInputAt < 200 && !document.hidden && !BX_EXPOSED.disableGamepadPolling) {
              __xcgMergedSamples++;
              const n = __xcgNativeInput;
              ["LeftTrigger", "RightTrigger", "LeftThumbXAxis", "LeftThumbYAxis", "RightThumbXAxis", "RightThumbYAxis"].forEach(key => {
                if (Number.isFinite(n[key])) { sample[key] = Math.max(key.includes("Axis") ? -1 : 0, Math.min(1, n[key])); sample.Dirty = true; }
              });
              const touchPrefix = n.touchAxisBase === 0 ? "LeftThumb" : "RightThumb";
              const gyroPrefix = n.gyroAxisBase === 0 ? "LeftThumb" : "RightThumb";
              if (n.touchpadAim === 1) {
                // Native values are relative trackpad output, not absolute browser touch coordinates.
                for (const [value,key] of [[n.touchX,touchPrefix+"XAxis"],[n.touchY,touchPrefix+"YAxis"]]) {
                  if (Number.isFinite(value)) { sample[key] = Math.max(-1,Math.min(1,(sample[key] || 0)+value)); sample.Dirty = true; }
                }
              }
              if (!(n.touchActive === 1 && n.touchpadAim === 1 && touchPrefix === gyroPrefix)) {
                const moving = Math.hypot(sample[gyroPrefix+"XAxis"] || 0,sample[gyroPrefix+"YAxis"] || 0) > 0.12;
                for (const [coarse,fine,key] of [[n.gyroX,n.gyroFineX,gyroPrefix+"XAxis"],[n.gyroY,n.gyroFineY,gyroPrefix+"YAxis"]]) {
                  const value = moving && Number.isFinite(fine) ? fine : coarse;
                  if (Number.isFinite(value)) { sample[key] = Math.max(-1,Math.min(1,(sample[key] || 0)+value)); sample.Dirty = true; }
                }
              }
            }
            Object.keys(__xcgMacroButtons).forEach(function (key) {
              var value = Number(__xcgMacroButtons[key]);
              if (Number.isFinite(value)) sample[key] = Math.max(0, Math.min(1, value));
            });
            if (Object.keys(__xcgMacroButtons).length) sample.Dirty = true;
            return sample;
          },
          setGamepadPollingPaused: function (flag) {
            if (!window.BX_EXPOSED || typeof window.BX_EXPOSED !== "object") return false;
            window.BX_EXPOSED.disableGamepadPolling = flag === true;
            return window.BX_EXPOSED.disableGamepadPolling;
          },
          rescanGamepads: function () {
            try {
              return typeof window.__xcgRescanBrowserGamepads === "function"
                ? window.__xcgRescanBrowserGamepads() : false;
            } catch (e) { return false; }
          },
          regions: function () { try { return STATES.serverRegions || {}; } catch (e) { return {}; } },
          selectedRegion: function () { try { return STATES.selectedRegion || {}; } catch (e) { return {}; } },
          getGlobal: function (k) {
            if (!isGlobalPref(k)) throw new Error("Setting is not global: " + k);
            return getGlobalPref(k);
          },
          setGlobal: function (k, v) {
            if (!isGlobalPref(k)) throw new Error("Setting is not global: " + k);
            setGlobalPref(k, v, "ui");
            if (k === "ui.theme") {
              var style = document.getElementById("xcg-live-theme");
              if (!style) { style = document.createElement("style"); style.id = "xcg-live-theme"; (document.head || document.documentElement).appendChild(style); }
              style.textContent = getGlobalPref(k) === "dark-oled" ? 'html,body,body[data-theme="dark"]{background-color:#000!important;--gds-containerSolidAppBackground:#000!important;--gds-backgroundPrimary:#000!important}' : '';
            }
            return getGlobalPref(k);
          },
          getStream: function (k) {
            if (!isStreamPref(k)) throw new Error("Setting is not stream: " + k);
            return getStreamPref(k);
          },
          setStream: function (k, v) {
            if (!isStreamPref(k)) throw new Error("Setting is not stream: " + k);
            setStreamPref(k, v, "ui");
            return getStreamPref(k);
          },
          getPublic: function (scope, k) {
            if (scope === "global") return this.getGlobal(k);
            if (scope === "stream") return this.getStream(k);
            throw new Error("Unknown setting scope: " + scope);
          },
          setPublic: function (scope, k, v) {
            if (scope === "global") return this.setGlobal(k, v);
            if (scope === "stream") return this.setStream(k, v);
            throw new Error("Unknown setting scope: " + scope);
          },
          rawGlobal: function () { try { return JSON.parse(localStorage.getItem("BetterXcloud") || "{}"); } catch (e) { return {}; } },
          rawStream: function () { try { return JSON.parse(localStorage.getItem("BetterXcloud.Stream") || "{}"); } catch (e) { return {}; } },
          rawSameScope: function (scope, k) {
            if (scope === "global") return this.rawGlobal()[k];
            /* Stream settings can be overridden per game. The public getter is
               the only same-scope value that is safe for the native mirror. */
            if (scope === "stream") return this.getStream(k);
            throw new Error("Unknown setting scope: " + scope);
          },
          settingsSnapshot: function () {
            var out = { global: {}, stream: {}, rawGlobal: {}, rawStream: {} };
            (ALL_PREFS.global || []).forEach(function (k) {
              try { out.global[k] = getGlobalPref(k); } catch (e) {}
            });
            (ALL_PREFS.stream || []).forEach(function (k) {
              try { out.stream[k] = getStreamPref(k); } catch (e) {}
            });
            try { out.rawGlobal = this.rawGlobal(); } catch (e) {}
            return out;
          },
          getBaseStream: function (key, fallback) {
            try {
              if (typeof STORAGE !== "undefined" && STORAGE.Stream) {
                var storage = STORAGE.Stream;
                if (storage.settings && Object.prototype.hasOwnProperty.call(storage.settings, key)) {
                  var value = storage.settings[key];
                  return value && typeof value === "object" ? JSON.parse(JSON.stringify(value)) : value;
                }
                var definition = typeof storage.getDefinition === "function" ? storage.getDefinition(key) : null;
                if (definition && Object.prototype.hasOwnProperty.call(definition, "default")) {
                  var defaultValue = definition.default;
                  return defaultValue && typeof defaultValue === "object" ? JSON.parse(JSON.stringify(defaultValue)) : defaultValue;
                }
              }
              var raw = this.rawStream();
              return Object.prototype.hasOwnProperty.call(raw, key) ? raw[key] : fallback;
            } catch (e) { return fallback; }
          },
          setBaseStream: function (key, value) {
            if (typeof STORAGE === "undefined" || !STORAGE.Stream) throw new Error("Base stream storage unavailable");
            /* Calling BaseSettingsStorage directly bypasses the current game's
               override while retaining validation, the in-memory cache, storage,
               and Better xCloud's setting.changed event. */
            var accepted = BaseSettingsStorage.prototype.setSetting.call(STORAGE.Stream, key, value, "ui");
            return this.getBaseStream(key, accepted);
          },
          profileTable: function (kind) {
            if (kind === "controller-shortcuts") return ControllerShortcutsTable.getInstance();
            if (kind === "controller-customization") return ControllerCustomizationsTable.getInstance();
            throw new Error("Unknown profile type: " + kind);
          },
          listProfiles: async function (kind) {
            return await this.profileTable(kind).getPresets();
          },
          createProfile: async function (kind, name, data) {
            return await this.profileTable(kind).newPreset(name.trim(), data);
          },
          saveProfile: async function (kind, preset) {
            if (!preset || preset.id <= 0) throw new Error("Default profiles are read-only");
            return await this.profileTable(kind).updatePreset(preset);
          },
          deleteProfile: async function (kind, id) {
            if (id <= 0) throw new Error("Default profiles are read-only");
            return await this.profileTable(kind).deletePreset(id);
          },
          profileByID: async function (kind, selected) {
            var payload = await this.listProfiles(kind);
            var records = payload && payload.data || {};
            var record = records[String(selected)] || records[selected];
            if (!record) return null;
            return { sourceID: Number(record.id ?? selected), name: String(record.name || "Default"), data: record.data || {} };
          },
          captureInputPresetSettings: async function () {
            var controllerSettings = this.getBaseStream("controller.settings", {}) || {};
            var gamepad = null;
            try { gamepad = Array.from(navigator.getGamepads()).filter(Boolean)[0] || null; } catch (e) {}
            var controller = gamepad && controllerSettings[gamepad.id] || {};
            var shortcuts = Number(controller.shortcutPresetId ?? -1);
            var customization = Number(controller.customizationPresetId ?? 0);
            return {
              mkbEnabled: false,
              nativeMkbMode: "off",
              p1Slot: 1,
              p2Slot: 0,
              mkbP1: null,
              mkbP2: null,
              keyboard: null,
              controllerShortcuts: await this.profileByID("controller-shortcuts", shortcuts),
              controllerCustomization: await this.profileByID("controller-customization", customization),
              streamPreferences: Object.fromEntries(["video.brightness", "video.contrast", "video.saturation", "video.processing.sharpness", "audio.volume"].map(key => [key, getStreamPref(key)]))
            };
          },
          upsertManagedProfile: async function (kind, snapshot, managedName) {
            if (!snapshot || !snapshot.data) return null;
            var payload = await this.listProfiles(kind);
            var records = payload && payload.data || {};
            var existing = Object.keys(records).map(function (key) { return records[key]; })
              .find(function (record) { return record && record.id > 0 && record.name === managedName; });
            if (existing) {
              var existingID = Number(existing.id);
              await this.saveProfile(kind, { id: existingID, name: managedName, data: snapshot.data });
              return existingID;
            }
            return Number(await this.createProfile(kind, managedName, snapshot.data));
          },
          applyInputPresetSettings: async function (bundle, presetName, applyToken) {
            bundle = bundle && typeof bundle === "object" ? bundle : {};
            this.inputPresetApplyToken = String(applyToken || "");
            var bridge = this, isCurrent = function () { return bridge.inputPresetApplyToken === String(applyToken || ""); };
            var warnings = [], prefix = "XCG · " + String(presetName || "Input Preset") + " · ";
            if (!isCurrent()) return { ok: false, cancelled: true, warnings: [] };
            // Legacy profile fields remain readable, but cannot reactivate removed features.
            try { setGlobalPref("mkb.enabled", false, "ui"); setGlobalPref("nativeMkb.mode", "off", "ui"); } catch (e) {}
            try {
              if (!isCurrent()) return { ok: false, cancelled: true, warnings: [] };
              var shortcuts = await this.upsertManagedProfile("controller-shortcuts", bundle.controllerShortcuts, prefix + "controller-shortcuts");
              if (!isCurrent()) return { ok: false, cancelled: true, warnings: [] };
              var customization = await this.upsertManagedProfile("controller-customization", bundle.controllerCustomization, prefix + "controller-customization");
              if (!isCurrent()) return { ok: false, cancelled: true, warnings: [] };
              var controllerSettings = this.getBaseStream("controller.settings", {}) || {};
              var pads = [];
              try { pads = Array.from(navigator.getGamepads()).filter(Boolean); } catch (e) {}
              pads.forEach(function (pad) {
                var record = controllerSettings[pad.id] || {};
                record.shortcutPresetId = shortcuts === null ? -1 : shortcuts;
                record.customizationPresetId = customization === null ? 0 : customization;
                controllerSettings[pad.id] = record;
              });
              this.setBaseStream("controller.settings", controllerSettings);
              await StreamSettings.refreshControllerSettings();
            } catch (e) { warnings.push("controller profiles: " + String(e)); }
            const liveKeys = ["video.brightness", "video.contrast", "video.saturation", "video.processing.sharpness", "audio.volume"];
            for (const key of liveKeys) {
              if (!isCurrent()) return {ok:false, cancelled:true, warnings:[]};
              const value = bundle.streamPreferences?.[key];
              if (Number.isFinite(value)) {
                try { setStreamPref(key, value, "ui"); } catch (e) { warnings.push(key + ": " + String(e)); }
              }
            }
            return { ok: warnings.length === 0, warnings: warnings };
          },
          streamInfo: function () {
            try {
              var stream = STATES.currentStream || {};
              var remote = STATES.remotePlay || {};
              var title = stream.titleInfo && stream.titleInfo.product && stream.titleInfo.product.title;
              title = title || remote.title || stream.title || "";
              if (!title) title = document.title.replace(/ - Xbox Cloud Gaming.*/, "");
              return { hudVisible: getStreamPref("stats.showWhenPlaying") === true,
                hudItems: getStreamPref("stats.items"), hudPosition: getStreamPref("stats.position"),
                hudOpacity: getStreamPref("stats.opacity.all"), hudBackground: getStreamPref("stats.opacity.background"),
                hudColors: getStreamPref("stats.colors"), hudQuickGlance: getStreamPref("stats.quickGlance.enabled"), hudTextSize: getStreamPref("stats.textSize"),
                gameID: String(stream.titleInfo?.product?.productId || stream.titleInfo?.details?.productId || stream.xboxTitleId || stream.titleInfo?.details?.xboxTitleId || stream.titleInfo?.titleId || ""), playing: !!STATES.isPlaying, title: title || "", region: (STATES.selectedRegion && (STATES.selectedRegion.displayName || STATES.selectedRegion.shortName)) || remote.region || "" };
            } catch (e) { return { playing: false, title: "", region: "" }; }
          },
          streamStats: async function () {
            var collector = StreamStatsCollector.getInstance();
            await collector.collect();
            var stats = collector.currentStats || {};
            var finite = function (value, fallback) { value = Number(value); return Number.isFinite(value) ? value : fallback; };
            var pl = stats.pl || {}, fl = stats.fl || {}, dt = stats.dt || {};
            return {
              display: Object.fromEntries(Object.entries(stats).map(([key, value]) => [key, value.toString()])),
              ping: finite(stats.ping && stats.ping.current, -1),
              fps: finite(stats.fps && stats.fps.current, 0),
              bitrate: finite(stats.btr && stats.btr.current, 0),
              loss: {
                packets: finite(pl.dropped, 0),
                packetPercent: finite(pl.dropped, 0) * 100 / Math.max(1, finite(pl.received, 0) + finite(pl.dropped, 0)),
                frames: finite(fl.dropped, 0),
                framePercent: finite(fl.dropped, 0) * 100 / Math.max(1, finite(fl.received, 0) + finite(fl.dropped, 0))
              },
              frames: { received: finite(fl.received, 0), dropped: finite(fl.dropped, 0) },
              jitter: finite(stats.jit && stats.jit.current, 0),
              resolution: String(stats.res && stats.res.current || ""),
              decodeTime: finite(dt.current, 0)
            };
          },
          regionList: function () { try { return Object.keys(STATES.serverRegions).map(function (k) { var r = STATES.serverRegions[k]; return { name: k, baseUri: r.baseUri || '' }; }); } catch (e) { return []; } },
          refreshProfiles: async function (kind) {
            return await StreamSettings.refreshControllerSettings();
          },
          profileSelections: function () {
            var gamepad = null;
            try { gamepad = Array.from(navigator.getGamepads()).filter(Boolean)[0] || null; } catch (e) {}
            var settings = this.getBaseStream("controller.settings", {}) || {};
            var controller = gamepad && settings[gamepad.id] || {};
            return {
              controllerShortcuts: Number(controller.shortcutPresetId ?? -1),
              controllerCustomization: Number(controller.customizationPresetId ?? 0),
              gamepadId: gamepad ? gamepad.id : null
            };
          },
          selectProfile: async function (kind, id) {
            if (!["controller-shortcuts", "controller-customization"].includes(kind)) throw new Error("Unsupported profile type");
            var gamepad = null;
            try { gamepad = Array.from(navigator.getGamepads()).filter(Boolean)[0] || null; } catch (e) {}
            if (!gamepad) throw new Error("Connect a controller first");
            var settings = this.getBaseStream("controller.settings", {}) || {};
            var record = settings[gamepad.id] || {shortcutPresetId:-1, customizationPresetId:0};
            if (kind === "controller-shortcuts") record.shortcutPresetId = id;
            if (kind === "controller-customization") record.customizationPresetId = id;
            settings[gamepad.id] = record;
            this.setBaseStream("controller.settings", settings);
            await StreamSettings.refreshControllerSettings();
            return id;
          }
        };
        // Rendering and the collection timer are owned by native macOS UI.
        const __xcgOldStats = StreamStats.getInstance();
        __xcgOldStats.stop();
        __xcgOldStats.start = async function() {};
        const __xcgStatsCollector = StreamStatsCollector.getInstance();
        const __xcgCollect = __xcgStatsCollector.collect.bind(__xcgStatsCollector);
        let __xcgCollectTask = null, __xcgCollectedAt = -Infinity, __xcgStatsPeer = null;
        __xcgStatsCollector.collect = function() {
          const peer = STATES.currentStream?.peerConnection;
          if (peer !== __xcgStatsPeer) {
            __xcgStatsPeer = peer; this.lastVideoStat = undefined;
            this.selectedCandidatePairId = null; __xcgCollectedAt = -Infinity;
          }
          if (__xcgCollectTask) return __xcgCollectTask;
          if (performance.now() - __xcgCollectedAt < 750) return Promise.resolve();
          let timeout;
          const bounded = Promise.race([__xcgCollect(), new Promise((_, reject) => {
            timeout = setTimeout(() => reject(new Error("Stream stats timed out")), 2500);
          })]);
          __xcgCollectTask = bounded.then(() => { __xcgCollectedAt = performance.now(); })
            .finally(() => { clearTimeout(timeout); __xcgCollectTask = null; });
          return __xcgCollectTask;
        };
        __xcgPatchBundledSource();
        try {
          window.dispatchEvent(new CustomEvent("bxc-bridge-ready", { detail: { capabilities: __xcgBridgeCapability } }));
          window.webkit.messageHandlers.spikeHandler.postMessage({ type: "bridge-ready", capabilities: __xcgBridgeCapability });
        } catch (e) {}
        """#

        return """
        (function () {
          "use strict";
          try {
            var __p = location.pathname || "";
            var __ok = location.hostname === "www.xbox.com" && (__p === "/play" || __p.indexOf("/play/") === 0 || __p.indexOf("/auth/msa") === 0 || /\\/play\\/?$/.test(__p));
            if (!__ok) return;
            \(inputAdapter)
            \(cleaned)
            \(bridge)
          } catch (e) {
            try { console.error("[XCG] Better xCloud injection failed:", e); } catch (e2) {}
          }
        })();
        """
    }

    /// Auto-dismisses Xbox's "No controller is connected" dialog. The web view
    /// exposes gamepads a moment after a stream starts, so the site can show
    /// this dialog even though a controller is connected and working.
    static let autoContinueScript = #"""
    (function () {
      function scan() {
        try {
          var dialogs = document.querySelectorAll('[role="dialog"], div[class*="Dialog"]');
          for (var i = 0; i < dialogs.length; i++) {
            var d = dialogs[i];
            if (!d || d.__xcgHandled) continue;
            var text = (d.innerText || '').toLowerCase();
            if (text.indexOf('controller') === -1) continue;
            if (text.indexOf('no controller') === -1 && text.indexOf("isn't connected") === -1 && text.indexOf('not connected') === -1) continue;
            var buttons = d.querySelectorAll('button');
            for (var j = 0; j < buttons.length; j++) {
              var label = (buttons[j].innerText || '').trim().toLowerCase();
              if (label === 'continue' || label === 'ok' || label === 'got it' || label === 'dismiss' || label.indexOf('continue') === 0) {
                d.__xcgHandled = true;
                buttons[j].click();
                return;
              }
            }
          }
        } catch (e) {}
      }
      function start() {
        try {
          var observer = new MutationObserver(function () { scan(); });
          observer.observe(document.body, { childList: true, subtree: true });
          setInterval(scan, 1000);
        } catch (e) {}
      }
      if (document.body) { start(); } else { document.addEventListener('DOMContentLoaded', start); }
    })();
    """#

    /// Hides every piece of UI Better xCloud injects (buttons, dialogs, menus) —
    /// the native app provides the interface — and restyles the stats bar to
    /// look like a macOS control instead of a browser widget.
    static let nativeStyleScript = #"""
    (function () {
      var css = [
        '.bx-top-buttons,.bx-header-settings-button,.bx-centered-dialog,.bx-navigation-dialog,.bx-guide-home-buttons,.bx-controller-shortcuts-manager-container,.bx-keyboard-shortcuts-manager-container,.bx-toast,#bx-game-bar { display:none !important; }',
        '.bx-stats-bar,#bx-stats-bar { display:none !important; }',
        'html.xcg-hide-cursor,html.xcg-hide-cursor * { cursor:none !important; }'
      ].join('\n');

      function addStyle() {
        try {
          if (document.getElementById('xcg-native-style')) return;
          var style = document.createElement('style');
          style.id = 'xcg-native-style';
          style.textContent = css;
          (document.head || document.documentElement).appendChild(style);
        } catch (e) {}
      }

      /* Better xCloud clones the site's HUD buttons for its stream shortcuts
         (they carry title attributes) — remove the clones; the native app owns
         settings and the menu bar owns navigation. */
      var bxButtonTitles = ['Better xCloud', 'Stream stats', 'Reload page', 'Back to home', 'Take screenshot'];
      function removeBxButtons() {
        try {
          var hud = document.getElementById('StreamHud');
          if (!hud) return;
          var buttons = hud.querySelectorAll('button[title]');
          for (var i = 0; i < buttons.length; i++) {
            var title = buttons[i].getAttribute('title') || '';
            if (bxButtonTitles.indexOf(title) !== -1) {
              var container = buttons[i].closest('div[class^="HUDButton"]') || buttons[i];
              container.remove();
            }
          }
        } catch (e) {}
      }

      addStyle();
      removeBxButtons();
      try {
        var scanPending = false;
        var observer = new MutationObserver(function () {
          if (scanPending) return;
          scanPending = true;
          setTimeout(function() { scanPending = false; addStyle(); removeBxButtons(); }, 250);
        });
        observer.observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}

    })();
    """#

    /// Reads all overlay-relevant settings in one call.
    static let readStateJS = """
    (function () {
      try {
        if (typeof BxCBridge === 'undefined') return JSON.stringify({ bridge: false });
        var g = function (k) { try { return BxCBridge.getGlobal(k); } catch (e) { return null; } };
        var s = function (k) { try { return BxCBridge.getStream(k); } catch (e) { return null; } };
        return JSON.stringify({
          bridge: true,
          regions: BxCBridge.regions(),
          region: g('server.region'),
          resolution: g('stream.video.resolution'),
          rawBitrate: (JSON.parse(localStorage.getItem('BetterXcloud') || '{}'))['stream.video.maxBitrate'] || 0,
          preventDrops: g('stream.video.preventResolutionDrops'),
          splashSkip: g('ui.splashVideo.skip'),
          feedbackDisabled: g('ui.feedbackDialog.disabled'),
          statsShow: s('stats.showWhenPlaying'),
          statsPosition: s('stats.position'),
          statsItems: s('stats.items'),
          vibrationMode: s('deviceVibration.mode'),
          vibrationIntensity: s('deviceVibration.intensity')
        });
      } catch (e) { return JSON.stringify({ bridge: false, error: String(e) }); }
    })();
    """
}
