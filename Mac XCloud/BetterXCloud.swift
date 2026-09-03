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
        // Insert only a finite button overlay after Better xCloud has produced
        // its mapped sample. Physical gamepad fields otherwise remain untouched.
        let mappingMarker = "if(shareButtonPressed&&!shareButtonHandled)window.dispatchEvent(new Event(BxEvent.CAPTURE_SCREENSHOT));"
        let macroMerge = mappingMarker + "if(window.BxCBridge)window.BxCBridge.mergeMacroButtons(xCloudGamepad);"
        let macroOverlayAvailable = stripped.components(separatedBy: mappingMarker).count == 2
        let cleaned = macroOverlayAvailable
            ? stripped.replacingOccurrences(of: mappingMarker, with: macroMerge)
            : stripped

        let bridge = #"""
        const __xcgMacroButtonFields = Object.freeze({
          A:true, B:true, X:true, Y:true, LeftShoulder:true, RightShoulder:true,
          LeftTrigger:true, RightTrigger:true, View:true, Menu:true,
          LeftThumb:true, RightThumb:true, DPadUp:true, DPadDown:true,
          DPadLeft:true, DPadRight:true, Nexus:true, Share:true
        });
        const __xcgMacroButtons = Object.create(null);
        const __xcgBridgeCapability = {
          profileCapture: true,
          macroOverlay: \#(macroOverlayAvailable ? "true" : "false"),
          nativeRumble: false
        };

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
          return false;
        };

        window.BxCBridge = {
          capabilities: __xcgBridgeCapability,
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
            return true;
          },
          resetMacroButtons: function () {
            Object.keys(__xcgMacroButtons).forEach(function (key) { delete __xcgMacroButtons[key]; });
            return true;
          },
          mergeMacroButtons: function (sample) {
            if (!__xcgBridgeCapability.macroOverlay || !sample || typeof sample !== "object") return sample;
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
          regions: function () { try { return STATES.serverRegions || {}; } catch (e) { return {}; } },
          selectedRegion: function () { try { return STATES.selectedRegion || {}; } catch (e) { return {}; } },
          getGlobal: function (k) {
            if (!isGlobalPref(k)) throw new Error("Setting is not global: " + k);
            return getGlobalPref(k);
          },
          setGlobal: function (k, v) {
            if (!isGlobalPref(k)) throw new Error("Setting is not global: " + k);
            setGlobalPref(k, v, "ui");
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
          profileByID: async function (kind, selected) {
            var payload = await this.listProfiles(kind);
            var records = payload && payload.data || {};
            var record = records[String(selected)] || records[selected];
            if (!record) return null;
            return { sourceID: Number(record.id ?? selected), name: String(record.name || "Default"), data: record.data || {} };
          },
          captureInputPresetSettings: async function () {
            var p1 = Number(this.getBaseStream("mkb.p1.preset.mappingId", -1));
            var p2 = Number(this.getBaseStream("mkb.p2.preset.mappingId", 0));
            var keyboard = Number(this.getBaseStream("keyboardShortcuts.preset.inGameId", -1));
            var controllerSettings = this.getBaseStream("controller.settings", {}) || {};
            var gamepad = null;
            try { gamepad = Array.from(navigator.getGamepads()).filter(Boolean)[0] || null; } catch (e) {}
            var controller = gamepad && controllerSettings[gamepad.id] || {};
            var shortcuts = Number(controller.shortcutPresetId ?? -1);
            var customization = Number(controller.customizationPresetId ?? 0);
            return {
              mkbEnabled: this.rawGlobal()["mkb.enabled"] === true,
              nativeMkbMode: String(this.rawGlobal()["nativeMkb.mode"] ?? "default"),
              p1Slot: Number(this.getBaseStream("mkb.p1.slot", 1)),
              p2Slot: Number(this.getBaseStream("mkb.p2.slot", 0)),
              mkbP1: await this.profileByID("mkb", p1),
              mkbP2: await this.profileByID("mkb", p2),
              keyboard: await this.profileByID("keyboard", keyboard),
              controllerShortcuts: await this.profileByID("controller-shortcuts", shortcuts),
              controllerCustomization: await this.profileByID("controller-customization", customization)
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
            try { setGlobalPref("mkb.enabled", bundle.mkbEnabled === true, "ui"); } catch (e) { warnings.push("mkb.enabled: " + String(e)); }
            try { setGlobalPref("nativeMkb.mode", String(bundle.nativeMkbMode || "default"), "ui"); } catch (e) { warnings.push("nativeMkb.mode: " + String(e)); }
            try {
              if (!isCurrent()) return { ok: false, cancelled: true, warnings: [] };
              this.setBaseStream("mkb.p1.slot", bundle.p1Slot ?? 1);
              this.setBaseStream("mkb.p2.slot", bundle.p2Slot ?? 0);
              var p1 = await this.upsertManagedProfile("mkb", bundle.mkbP1, prefix + "mkb-p1");
              if (!isCurrent()) return { ok: false, cancelled: true, warnings: [] };
              var p2 = await this.upsertManagedProfile("mkb", bundle.mkbP2, prefix + "mkb-p2");
              if (!isCurrent()) return { ok: false, cancelled: true, warnings: [] };
              this.setBaseStream("mkb.p1.preset.mappingId", p1 === null ? -1 : p1);
              this.setBaseStream("mkb.p2.preset.mappingId", p2 === null ? 0 : p2);
              await StreamSettings.refreshMkbSettings();
            } catch (e) { warnings.push("mkb profiles: " + String(e)); }
            try {
              if (!isCurrent()) return { ok: false, cancelled: true, warnings: [] };
              var keyboard = await this.upsertManagedProfile("keyboard", bundle.keyboard, prefix + "keyboard");
              if (!isCurrent()) return { ok: false, cancelled: true, warnings: [] };
              this.setBaseStream("keyboardShortcuts.preset.inGameId", keyboard === null ? -1 : keyboard);
              await StreamSettings.refreshKeyboardShortcuts();
            } catch (e) { warnings.push("keyboard: " + String(e)); }
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
            return { ok: warnings.length === 0, warnings: warnings };
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
            var gamepad = null;
            try { gamepad = Array.from(navigator.getGamepads()).filter(Boolean)[0] || null; } catch (e) {}
            var settings = this.getBaseStream("controller.settings", {}) || {};
            var controller = gamepad && settings[gamepad.id] || {};
            return {
              mkb: Number(this.getBaseStream("mkb.p1.preset.mappingId", -1)),
              keyboard: Number(this.getBaseStream("keyboardShortcuts.preset.inGameId", -1)),
              controllerShortcuts: Number(controller.shortcutPresetId ?? -1),
              controllerCustomization: Number(controller.customizationPresetId ?? 0),
              gamepadId: gamepad ? gamepad.id : null
            };
          },
          selectProfile: async function (kind, id) {
            if (kind === "mkb") {
              this.setBaseStream("mkb.p1.preset.mappingId", id);
              await StreamSettings.refreshMkbSettings();
              return id;
            }
            if (kind === "keyboard") {
              this.setBaseStream("keyboardShortcuts.preset.inGameId", id);
              await StreamSettings.refreshKeyboardShortcuts();
              return id;
            }
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
