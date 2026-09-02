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

    /// WKUserScripts for the main web view, in execution order.
    static func userScripts() -> [WKUserScript] {
        var scripts: [WKUserScript] = []

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
          EnableWebGPURenderer: false
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

        return scripts
    }

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

        let bridge = """
        window.BxCBridge = {
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
        """

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
        '  margin-top: 10px !important;',
        '  padding: 7px 14px !important;',
        '}',
        '.bx-stats-bar * { font-family: inherit !important; letter-spacing: inherit !important; }'
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
