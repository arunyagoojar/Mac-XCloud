//
//  BetterXCloud.swift
//  Xbox Cloud Gaming
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

    /// Reliable axis-only overlay for native gyro/steering. It wraps
    /// navigator.getGamepads at document-start and returns lightweight proxy
    /// objects whose axes are adjusted; buttons and every other property are
    /// the original browser values.
    static let gamepadAxisOverlayScript = #"""
    (function () {
      'use strict';
      try {
        var nativeGetGamepads = navigator.getGamepads && navigator.getGamepads.bind(navigator);
        if (!nativeGetGamepads) return;
        var nativeAxes = [0, 0, 0, 0];
        var enabled = false;
        window.__xcgSetNativeAxes = function (next) {
          enabled = !!(next && next.enabled);
          var values = next && next.axes || [];
          for (var i = 0; i < 4; i++) {
            var value = Number(values[i]);
            nativeAxes[i] = Number.isFinite(value) ? Math.max(-1, Math.min(1, value)) : 0;
          }
        };
        navigator.getGamepads = function () {
          var pads = nativeGetGamepads() || [];
          if (!enabled) return pads;
          var output = Array.from(pads);
          for (var i = 0; i < output.length; i++) {
            var pad = output[i];
            if (!pad || !pad.axes || pad.axes.length < 4) continue;
            var axes = Array.from(pad.axes);
            for (var axis = 0; axis < 4; axis++) {
              axes[axis] = Math.max(-1, Math.min(1, Number(axes[axis] || 0) + nativeAxes[axis]));
            }
            output[i] = new Proxy(pad, {
              get: function (target, property) {
                if (property === 'axes') return axes;
                var value = Reflect.get(target, property, target);
                return typeof value === 'function' ? value.bind(target) : value;
              }
            });
          }
          return output;
        };
      } catch (error) { try { console.error('[XCG] gyro axis overlay failed', error); } catch (_) {} }
    })();
    """#

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
            var prefix = fmtp.substring(0, 18).toLowerCase();
            if (!codecs.some(function (c) { return (c.mimeType || '').toLowerCase() === 'video/h264' && (c.sdpFmtpLine || '').toLowerCase().indexOf(prefix) !== -1; })) {
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
        var scripts: [WKUserScript] = []

        // 0. WebKit compatibility shims, installed before Xbox/BxC evaluate
        //    browser features. WKWebView can omit mediaDevices entirely and
        //    under-report decodable H.264 profiles even though AVFoundation can
        //    decode them, which caused Xbox's error route and BxC's visual-
        //    quality selector to normalize every choice back to Default.
        scripts.append(WKUserScript(source: compatibilityScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // Gyro must be visible to Xbox even if Better xCloud's minified mapping
        // marker changes. This document-start wrapper modifies only the four
        // standard stick axes and leaves every button/object mapping untouched.
        scripts.append(WKUserScript(source: gamepadAxisOverlayScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

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
              "stats.showWhenPlaying": true,
              "stats.items": ["ping", "fps", "btr", "dt", "pl", "fl"],
              "stats.position": "top-right",
              "stats.opacity.all": 90,
              "stats.opacity.background": 65,
              "stats.colors": true,
              "controller.pollingRate": 4
            };
            var defaultsVersion = parseInt(localStorage.getItem("XCG.NativeDefaultsVersion") || "0", 10);
            if (defaultsVersion < 2) {
              /* One corrective migration for the earlier low/off native UI.
                 Once v2 is recorded, user choices always win. */
              Object.assign(global, optimizedGlobal);
              Object.assign(stream, optimizedStream);
              localStorage.setItem("XCG.NativeDefaultsVersion", "2");
            } else {
              for (var k in optimizedGlobal) if (!(k in global)) global[k] = optimizedGlobal[k];
              for (var s in optimizedStream) if (!(s in stream)) stream[s] = optimizedStream[s];
            }
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
        let cleaned = source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//#") }
            .joined(separator: "\n")

        let bridge = #"""
        const __xcgInputFields = Object.freeze({
          A: [0, 1], B: [0, 1], X: [0, 1], Y: [0, 1],
          LeftShoulder: [0, 1], RightShoulder: [0, 1],
          LeftTrigger: [0, 1], RightTrigger: [0, 1],
          View: [0, 1], Menu: [0, 1], LeftThumb: [0, 1], RightThumb: [0, 1],
          DPadUp: [0, 1], DPadDown: [0, 1], DPadLeft: [0, 1], DPadRight: [0, 1],
          Nexus: [0, 1], Share: [0, 1],
          LeftThumbXAxis: [-1, 1], LeftThumbYAxis: [-1, 1],
          RightThumbXAxis: [-1, 1], RightThumbYAxis: [-1, 1]
        });
        const __xcgAxes = ["LeftThumbXAxis", "LeftThumbYAxis", "RightThumbXAxis", "RightThumbYAxis"];
        const __xcgAxesWithDefault = __xcgAxes.concat(["default"]);
        const __xcgNativeInput = {
          sequence: 0,
          updatedAt: 0,
          enabled: false,
          values: Object.create(null),
          calibration: Object.create(null),
          curve: Object.create(null),
          deadzone: Object.create(null),
          gyro: Object.create(null),
          touchpad: Object.create(null),
          macro: Object.create(null),
          suppressBrowserRumble: false
        };
        const __xcgBridgeCapability = {
          inputMerge: false,
          inputMergeReason: "patch-pending",
          nativeRumble: false
        };

        function __xcgFinite(value, fallback, min, max) {
          value = Number(value);
          if (!Number.isFinite(value)) return fallback;
          if (typeof min === "number") value = Math.max(min, value);
          if (typeof max === "number") value = Math.min(max, value);
          return value;
        }
        function __xcgFiniteMap(value, keys, min, max) {
          var out = Object.create(null);
          if (!value || typeof value !== "object") return out;
          keys.forEach(function (key) {
            if (Object.prototype.hasOwnProperty.call(value, key)) {
              var number = Number(value[key]);
              if (Number.isFinite(number)) out[key] = Math.max(min, Math.min(max, number));
            }
          });
          return out;
        }
        function __xcgTransformAxis(value, calibration, curve, deadzone) {
          var v = __xcgFinite(value, 0, -1, 1);
          calibration = calibration && typeof calibration === "object" ? calibration : {};
          var center = __xcgFinite(calibration.center ?? calibration.offset, 0, -1, 1);
          var minimum = __xcgFinite(calibration.min, -1, -1, center);
          var maximum = __xcgFinite(calibration.max, 1, center, 1);
          var span = v < center ? center - minimum : maximum - center;
          var scale = __xcgFinite(calibration.scale, 1, 0, 4);
          var invert = calibration.invert === true ? -1 : 1;
          v = Math.max(-1, Math.min(1, ((v - center) / Math.max(0.0001, span)) * scale * invert));
          var dz = __xcgFinite(deadzone, 0, 0, 0.99);
          var magnitude = Math.abs(v);
          if (magnitude <= dz) return 0;
          magnitude = (magnitude - dz) / (1 - dz);
          var exponent = __xcgFinite(curve, 1, 0.1, 5);
          return Math.max(-1, Math.min(1, Math.sign(v) * Math.pow(magnitude, exponent)));
        }
        function __xcgSanitizeMacro(value) {
          var out = Object.create(null);
          if (!value || typeof value !== "object") return out;
          Object.keys(__xcgInputFields).forEach(function (key) {
            if (!Object.prototype.hasOwnProperty.call(value, key)) return;
            var range = __xcgInputFields[key];
            var number = Number(value[key]);
            if (Number.isFinite(number)) out[key] = Math.max(range[0], Math.min(range[1], number));
          });
          ["duration", "durationMs", "repeat", "delay", "delayMs", "interval", "intervalMs"].forEach(function (key) {
            if (!Object.prototype.hasOwnProperty.call(value, key)) return;
            var max = key === "repeat" ? 1000 : 600000;
            var number = Number(value[key]);
            if (Number.isFinite(number)) out[key] = Math.max(0, Math.min(max, number));
          });
          return out;
        }
        function __xcgApplyObject(target, source) {
          if (!source || typeof source !== "object") return;
          Object.keys(source).forEach(function (key) {
            if (Object.prototype.hasOwnProperty.call(__xcgInputFields, key)) {
              var range = __xcgInputFields[key];
              var number = Number(source[key]);
              if (Number.isFinite(number)) target[key] = Math.max(range[0], Math.min(range[1], number));
            }
          });
        }
        function __xcgPatchBundledSource() {
          /* Better xCloud constructs this string inside Patcher.patchPollGamepads.
             Replacing its unique terminator puts the native merge after BxC's
             mappings/ranges and immediately before the packet continues. */
          var marker = "if(shareButtonPressed&&!shareButtonHandled)window.dispatchEvent(new Event(BxEvent.CAPTURE_SCREENSHOT));\n";
          try {
            if (typeof controller_customization_default !== "string") throw new Error("controller_customization_default unavailable");
            var occurrences = controller_customization_default.split(marker).length - 1;
            if (occurrences !== 1) throw new Error(occurrences ? "ambiguous mapping marker" : "mapping marker absent");
            controller_customization_default = controller_customization_default.replace(
              marker,
              marker.slice(0, -2) + ";if(window.BxCBridge)window.BxCBridge.mergeGamepadSample(xCloudGamepad,currentGamepad);\n"
            );
            __xcgBridgeCapability.inputMerge = true;
            __xcgBridgeCapability.inputMergeReason = null;
          } catch (error) {
            __xcgNativeInput.enabled = false;
            __xcgBridgeCapability.inputMerge = false;
            __xcgBridgeCapability.inputMergeReason = String(error && error.message || error);
            try { console.error("[XCG] Native input merge disabled:", error); } catch (_) {}
          }

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
          } catch (error) {}
          return !!__xcgNativeInput.suppressBrowserRumble;
        };

        // Re-chain the gyro axis overlay after Better xCloud has initialized;
        // its MKB emulation may replace navigator.getGamepads later.
        try {
          var chainedGetGamepads = navigator.getGamepads.bind(navigator);
          var chainedAxes = [0, 0, 0, 0];
          var chainedEnabled = false;
          window.__xcgSetNativeAxes = function (next) {
            chainedEnabled = !!(next && next.enabled);
            var values = next && next.axes || [];
            for (var i = 0; i < 4; i++) {
              var value = Number(values[i]);
              chainedAxes[i] = Number.isFinite(value) ? Math.max(-1, Math.min(1, value)) : 0;
            }
          };
          navigator.getGamepads = function () {
            var pads = chainedGetGamepads() || [];
            if (!chainedEnabled) return pads;
            return Array.from(pads).map(function (pad) {
              if (!pad || !pad.axes || pad.axes.length < 4) return pad;
              var axes = Array.from(pad.axes);
              for (var i = 0; i < 4; i++) axes[i] = Math.max(-1, Math.min(1, Number(axes[i] || 0) + chainedAxes[i]));
              return new Proxy(pad, { get: function (target, property) {
                if (property === 'axes') return axes;
                var value = Reflect.get(target, property, target);
                return typeof value === 'function' ? value.bind(target) : value;
              }});
            });
          };
          __xcgBridgeCapability.gyroAxisOverlay = true;
        } catch (error) {
          __xcgBridgeCapability.gyroAxisOverlay = false;
          try { console.error('[XCG] chained gyro overlay failed', error); } catch (_) {}
        }

        window.BxCBridge = {
          capabilities: __xcgBridgeCapability,
          nativeInputState: __xcgNativeInput,
          updateNativeInput: function (next) {
            next = next && typeof next === "object" ? next : {};
            if (next.suppressBrowserRumble !== undefined) __xcgNativeInput.suppressBrowserRumble = next.suppressBrowserRumble === true;
            if (!__xcgBridgeCapability.inputMerge) {
              __xcgNativeInput.enabled = false;
              return { ok: false, capability: this.capabilities, state: this.nativeInputState };
            }
            if (next.reset === true) {
              __xcgNativeInput.values = Object.create(null);
              __xcgNativeInput.calibration = Object.create(null);
              __xcgNativeInput.curve = Object.create(null);
              __xcgNativeInput.deadzone = Object.create(null);
              __xcgNativeInput.gyro = Object.create(null);
              __xcgNativeInput.touchpad = Object.create(null);
              __xcgNativeInput.macro = Object.create(null);
            }
            if (next.values || next.axes || next.buttons || next.leftStick || next.rightStick || next.leftTrigger !== undefined || next.rightTrigger !== undefined) {
              var values = Object.assign({}, next.values || {}, next.axes || {});
              if (next.leftStick) Object.assign(values, { LeftThumbXAxis: next.leftStick.x, LeftThumbYAxis: next.leftStick.y });
              if (next.rightStick) Object.assign(values, { RightThumbXAxis: next.rightStick.x, RightThumbYAxis: next.rightStick.y });
              if (next.leftTrigger !== undefined) values.LeftTrigger = next.leftTrigger;
              if (next.rightTrigger !== undefined) values.RightTrigger = next.rightTrigger;
              var buttons = next.buttons || {};
              var buttonMap = {
                a: "A", b: "B", x: "X", y: "Y", menu: "Menu", options: "View", home: "Nexus",
                leftShoulder: "LeftShoulder", rightShoulder: "RightShoulder",
                leftStick: "LeftThumb", rightStick: "RightThumb",
                dpadUp: "DPadUp", dpadDown: "DPadDown", dpadLeft: "DPadLeft", dpadRight: "DPadRight"
              };
              Object.keys(buttonMap).forEach(function (key) {
                if (!Object.prototype.hasOwnProperty.call(buttons, key)) return;
                var button = buttons[key];
                values[buttonMap[key]] = button && typeof button === "object" ? button.value : button;
              });
              __xcgNativeInput.values = __xcgFiniteMap(values, Object.keys(__xcgInputFields), -1, 1);
              Object.keys(__xcgNativeInput.values).forEach(function (key) {
                var range = __xcgInputFields[key];
                __xcgNativeInput.values[key] = Math.max(range[0], Math.min(range[1], __xcgNativeInput.values[key]));
              });
              if (next.enabled === undefined) __xcgNativeInput.enabled = true;
            }
            if (next.calibration && typeof next.calibration === "object") __xcgNativeInput.calibration = next.calibration;
            if (next.curve && typeof next.curve === "object") __xcgNativeInput.curve = __xcgFiniteMap(next.curve, __xcgAxesWithDefault, 0.1, 5);
            if (next.deadzone && typeof next.deadzone === "object") __xcgNativeInput.deadzone = __xcgFiniteMap(next.deadzone, __xcgAxesWithDefault, 0, 0.99);
            if (next.gyro && typeof next.gyro === "object") {
              var gyro = Object.assign({}, next.gyro);
              if (next.gyro.x !== undefined) gyro.RightThumbXAxis = next.gyro.x;
              if (next.gyro.y !== undefined) gyro.RightThumbYAxis = next.gyro.y;
              __xcgNativeInput.gyro = __xcgFiniteMap(gyro, __xcgAxes, -1, 1);
            }
            if (next.touchpad && typeof next.touchpad === "object") {
              var touchpad = Object.assign({}, next.touchpad);
              if (next.touchpad.x !== undefined) touchpad.RightThumbXAxis = next.touchpad.x;
              if (next.touchpad.y !== undefined) touchpad.RightThumbYAxis = next.touchpad.y;
              __xcgNativeInput.touchpad = __xcgFiniteMap(touchpad, __xcgAxes, -1, 1);
            }
            if (next.macro !== undefined) __xcgNativeInput.macro = __xcgSanitizeMacro(next.macro);
            if (next.enabled !== undefined) __xcgNativeInput.enabled = next.enabled === true;
            __xcgNativeInput.updatedAt = Date.now();
            __xcgNativeInput.sequence = (__xcgNativeInput.sequence + 1) >>> 0;
            return { ok: true, capability: this.capabilities, state: this.nativeInputState };
          },
          mergeGamepadSample: function (sample, gamepad) {
            if (!__xcgBridgeCapability.inputMerge || !__xcgNativeInput.enabled || !sample || typeof sample !== "object") return sample;
            var state = __xcgNativeInput;
            __xcgApplyObject(sample, state.values);
            __xcgAxes.forEach(function (key) {
              var base = Object.prototype.hasOwnProperty.call(state.values, key) ? state.values[key] : sample[key];
              var calibration = state.calibration[key] || {};
              var curve = state.curve[key] ?? state.curve.default;
              var deadzone = state.deadzone[key] ?? state.deadzone.default;
              var transformed = __xcgTransformAxis(base, calibration, curve, deadzone);
              transformed += __xcgFinite(state.gyro[key], 0, -1, 1);
              transformed += __xcgFinite(state.touchpad[key], 0, -1, 1);
              sample[key] = Math.max(-1, Math.min(1, transformed));
            });
            __xcgApplyObject(sample, state.macro);
            if (gamepad && Number.isFinite(Number(gamepad.index))) sample.GamepadIndex = Math.max(0, Math.min(255, Number(gamepad.index)));
            sample.Dirty = true;
            return sample;
          },
          setGamepadPollingPaused: function (flag) {
            if (!window.BX_EXPOSED || typeof window.BX_EXPOSED !== "object") return false;
            window.BX_EXPOSED.disableGamepadPolling = flag === true;
            return window.BX_EXPOSED.disableGamepadPolling;
          },
          regions: function () { try { return STATES.serverRegions || {}; } catch (e) { return {}; } },
          selectedRegion: function () { try { return STATES.selectedRegion || {}; } catch (e) { return {}; } },
          getGlobal: function (k) { return getGlobalPref(k); },
          setGlobal: function (k, v) { setGlobalPref(k, v, "ui"); return getGlobalPref(k); },
          getStream: function (k) { return getStreamPref(k); },
          setStream: function (k, v) { setStreamPref(k, v, "ui"); return getStreamPref(k); },
          rawGlobal: function () { try { return JSON.parse(localStorage.getItem("BetterXcloud") || "{}"); } catch (e) { return {}; } },
          rawStream: function () { try { return JSON.parse(localStorage.getItem("BetterXcloud.Stream") || "{}"); } catch (e) { return {}; } },
          profileTable: function (kind) {
            if (kind === "mkb") return MkbMappingPresetsTable.getInstance();
            if (kind === "keyboard") return KeyboardShortcutsTable.getInstance();
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
          streamInfo: function () {
            try {
              var stream = STATES.currentStream || {};
              var remote = STATES.remotePlay || {};
              var title = stream.titleInfo && stream.titleInfo.product && stream.titleInfo.product.title;
              title = title || remote.title || remote.consoleName || remote.name || stream.title || "";
              if (!title) title = document.title.replace(/ - Xbox Cloud Gaming.*/, "");
              return { playing: !!STATES.isPlaying, title: title || "", region: (STATES.selectedRegion && (STATES.selectedRegion.displayName || STATES.selectedRegion.shortName)) || remote.region || "" };
            } catch (e) { return { playing: false, title: "", region: "" }; }
          },
          streamStats: async function () {
            var collector = StreamStatsCollector.getInstance();
            await collector.collect();
            var stats = collector.currentStats || {};
            var finite = function (value, fallback) { value = Number(value); return Number.isFinite(value) ? value : fallback; };
            var pl = stats.pl || {}, fl = stats.fl || {}, dt = stats.dt || {};
            return {
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
            if (kind === "mkb") return await StreamSettings.refreshMkbSettings();
            if (kind === "keyboard") return await StreamSettings.refreshKeyboardShortcuts();
            return await StreamSettings.refreshControllerSettings();
          },
          profileSelections: function () {
            var raw = this.rawStream();
            var gamepad = null;
            try { gamepad = Array.from(navigator.getGamepads()).filter(Boolean)[0] || null; } catch (e) {}
            var cs = gamepad && raw["controller.settings"] ? raw["controller.settings"][gamepad.id] : null;
            return {
              mkb: raw["mkb.p1.preset.mappingId"] ?? -1,
              keyboard: raw["keyboardShortcuts.preset.inGameId"] ?? -1,
              controllerShortcuts: cs ? cs.shortcutPresetId : -1,
              controllerCustomization: cs ? cs.customizationPresetId : 0,
              gamepadId: gamepad ? gamepad.id : null
            };
          },
          selectProfile: async function (kind, id) {
            if (kind === "mkb") {
              setStreamPref("mkb.p1.preset.mappingId", id, "ui");
              await StreamSettings.refreshMkbSettings();
              return id;
            }
            if (kind === "keyboard") {
              setStreamPref("keyboardShortcuts.preset.inGameId", id, "ui");
              await StreamSettings.refreshKeyboardShortcuts();
              return id;
            }
            var gamepad = null;
            try { gamepad = Array.from(navigator.getGamepads()).filter(Boolean)[0] || null; } catch (e) {}
            if (!gamepad) throw new Error("Connect a controller first");
            var settings = getStreamPref("controller.settings") || {};
            var record = settings[gamepad.id] || {shortcutPresetId:-1, customizationPresetId:0};
            if (kind === "controller-shortcuts") record.shortcutPresetId = id;
            if (kind === "controller-customization") record.customizationPresetId = id;
            settings[gamepad.id] = record;
            setStreamPref("controller.settings", settings, "ui");
            await StreamSettings.refreshControllerSettings();
            return id;
          }
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
        /* Better xCloud UI chrome — fully replaced by the native settings window */
        '.bx-top-buttons { display: none !important; }',
        '.bx-header-settings-button { display: none !important; }',
        '.bx-centered-dialog { display: none !important; }',
        '.bx-navigation-dialog { display: none !important; }',
        '.bx-guide-home-buttons { display: none !important; }',
        '.bx-controller-shortcuts-manager-container { display: none !important; }',
        '.bx-keyboard-shortcuts-manager-container { display: none !important; }',
        '.bx-toast { display: none !important; }',
        '#bx-game-bar { display: none !important; }',
        /* Stats bar — macOS look: SF font, frosted rounded capsule */
        '.bx-stats-bar {',
        '  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif !important;',
        '  font-size: 12px !important;',
        '  font-weight: 500 !important;',
        '  letter-spacing: 0.02em;',
        '  border-radius: 10px !important;',
        '  border: 1px solid rgba(255, 255, 255, 0.10) !important;',
        '  background-color: rgba(18, 18, 22, 0.55) !important;',
        '  backdrop-filter: blur(24px) saturate(1.6) !important;',
        '  -webkit-backdrop-filter: blur(24px) saturate(1.6) !important;',
        '  box-shadow: 0 6px 20px rgba(0, 0, 0, 0.35) !important;',
        '  margin-top: 4px !important;',
        '  margin-right: 10px !important;',
        '  padding: 7px 14px !important;',
        '}',
        '.bx-stats-bar * { font-family: inherit !important; letter-spacing: inherit !important; }',
        /* Auto-hiding mouse cursor: the page adds this class after idle time
           while a controller is connected (see cursorHideScript). */
        'html.xcg-hide-cursor, html.xcg-hide-cursor * { cursor: none !important; }'
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
        var observer = new MutationObserver(function () { addStyle(); removeBxButtons(); });
        observer.observe(document.documentElement, { childList: true, subtree: true });
        setInterval(removeBxButtons, 1500);
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
