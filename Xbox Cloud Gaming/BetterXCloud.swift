//
//  BetterXCloud.swift
//  Xbox Cloud Gaming
//
//  Injects the MIT-licensed Better xCloud userscript (https://github.com/redphx/better-xcloud)
//  into xbox.com/play pages at document-start, and appends a small bridge
//  (window.BxCBridge) so the native settings overlay can read and change its
//  live settings.
//

import WebKit

enum BetterXCloud {

    static let resourceURL = Bundle.main.url(forResource: "better-xcloud", withExtension: "js")

    /// WKUserScripts for the main web view, in execution order.
    static func userScripts() -> [WKUserScript] {
        var scripts: [WKUserScript] = []

        // 1. Sensible app defaults for BxC settings, before the script reads them.
        let defaults = """
        (function () {
          try {
            var s = JSON.parse(localStorage.getItem("BetterXcloud") || "{}");
            var appDefaults = { "ui.splashVideo.skip": true, "ui.feedbackDialog.disabled": true };
            var changed = false;
            for (var k in appDefaults) { if (!(k in s)) { s[k] = appDefaults[k]; changed = true; } }
            if (changed) localStorage.setItem("BetterXcloud", JSON.stringify(s));
          } catch (e) {}
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

        return scripts
    }

    private static func wrappedScript(source: String) -> String {
        // Strip source-map comments; keep everything else intact.
        let cleaned = source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//#") }
            .joined(separator: "\n")

        let bridge = """
        window.BxCBridge = {
          regions: function () { try { return STATES.serverRegions || {}; } catch (e) { return {}; } },
          getGlobal: function (k) { return getGlobalPref(k); },
          setGlobal: function (k, v) { setGlobalPref(k, v, "ui"); },
          getStream: function (k) { return getStreamPref(k); },
          setStream: function (k, v) { setStreamPref(k, v, "ui"); }
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
        '.bx-centered-dialog { display: none !important; }',
        '.bx-navigation-dialog { display: none !important; }',
        '.bx-guide-home-buttons { display: none !important; }',
        '.bx-controller-shortcuts-manager-container { display: none !important; }',
        '.bx-keyboard-shortcuts-manager-container { display: none !important; }',
        '#bx-game-bar { display: none !important; }',
        /* Stats bar — macOS look: SF font, frosted rounded capsule */
        '.bx-stats-bar {',
        '  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif !important;',
        '  font-size: 12px !important;',
        '  font-weight: 500 !important;',
        '  letter-spacing: 0.02em;',
        '  border-radius: 10px !important;',
        '  border: 1px solid rgba(255, 255, 255, 0.10) !important;',
        '  backdrop-filter: blur(20px) saturate(1.5) !important;',
        '  -webkit-backdrop-filter: blur(20px) saturate(1.5) !important;',
        '  box-shadow: 0 6px 20px rgba(0, 0, 0, 0.35) !important;',
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
      addStyle();
      try {
        new MutationObserver(addStyle).observe(document.documentElement, { childList: true, subtree: true });
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
