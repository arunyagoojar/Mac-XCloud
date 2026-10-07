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
      /* Keyboard Lock stand-in. Xbox's stream client enables keyboard & mouse
         only when navigator.keyboard exists, and forwards keys to the game
         only after keyboard.lock() succeeds. WebKit has no Keyboard Lock API;
         the native app provides the equivalent itself (Escape goes to the
         game while the mouse is captured; holding it releases the mouse). */
      try {
        if (!("keyboard" in navigator)) {
          var keyboard = {
            lock: function () { return Promise.resolve(); },
            unlock: function () {},
            getLayoutMap: function () { return Promise.resolve(new Map()); },
            addEventListener: function () {}, removeEventListener: function () {}
          };
          Object.defineProperty(Navigator.prototype, "keyboard", { configurable: true, get: function () { return keyboard; } });
        }
      } catch (e) {}
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
            'profile-level-id=42001f;packetization-mode=1',
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
    /// `keyboardConfiguration` is the controller layout's JSON
    /// (`KeyboardMouseStore.pageConfigurationJSON`).
    static func userScripts(keyboardConfiguration: String = "{}") -> [WKUserScript] {
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
            /* Keyboard & mouse. nativeMkb.mode "default" lets games with
               keyboard & mouse support use it natively; "off" disables that.
               Every other game plays through the app's own controller layout
               (keyboardLayer), so Better xCloud's virtual controller stays off.
               Builds up to 1.3.8 forced native support off on every launch
               and left that value in storage; migrate once. */
            if (localStorage.getItem("XCG.MkbMigrated.v1") !== "1") {
              global["nativeMkb.mode"] = "default";
              localStorage.setItem("XCG.MkbMigrated.v1", "1");
            }
            global["mkb.enabled"] = false;
            if (mirrorGlobal["nativeMkb.mode"] === "default" || mirrorGlobal["nativeMkb.mode"] === "off") {
              global["nativeMkb.mode"] = mirrorGlobal["nativeMkb.mode"];
            } else if (global["nativeMkb.mode"] !== "off") {
              /* "on" is Android-app-only in Better xCloud and would be
                 normalized away; "default" is the desktop equivalent. */
              global["nativeMkb.mode"] = "default";
            }
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
        let nativeMkbAllowed = (NativeSettingsMirror.values(for: .global)["nativeMkb.mode"] as? String) != "off"
        let flags = """
        window.BX_FLAGS = Object.assign({}, window.BX_FLAGS || {}, {
          Debug: false,
          SafariWorkaround: true,
          CheckForUpdate: true,
          EnableXcloudLogging: false,
          EnableWebGPURenderer: true\(nativeMkbAllowed ? ",\n  FeatureGates: { EnableMouseAndKeyboard: true }" : "")
        });
        window.__xcgKeyboardConfig = \(keyboardConfiguration);
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

        return scripts
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

    /// Element fullscreen for the Xbox page, backed by the native window.
    ///
    /// WKWebView's own element fullscreen would move the page into a separate
    /// WebKit-owned window (losing the app's overlays) and would claim the
    /// Escape key. Instead the page gets a faithful Fullscreen API: requesting
    /// fullscreen records the element, reports it through
    /// `document.fullscreenElement`, fires `fullscreenchange` on it (Xbox
    /// listens on the element itself) and asks the app to enter native
    /// fullscreen. Xbox's stream only offers mouse capture while it believes
    /// it is fullscreen, so this state has to be exact.
    ///
    /// Leaving native fullscreen from the window (green button, ⌃⌘F) keeps
    /// the page's state, so keyboard & mouse keep working in a window.
    static let fullscreenBridgeScript = #"""
    (function () {
      "use strict";
      try {
        var path = location.pathname || "";
        if (location.hostname !== "www.xbox.com" || !(path.indexOf("/play") !== -1 || path.indexOf("/auth/msa") === 0)) return;
        var element = null;
        function current() { return element && element.isConnected ? element : null; }
        function post(enter) {
          try { window.webkit.messageHandlers.spikeHandler.postMessage({ type: "app-fullscreen", enter: enter }); } catch (e) {}
        }
        function announce(target) {
          var node = target && target.isConnected ? target : document;
          ["fullscreenchange", "webkitfullscreenchange"].forEach(function (name) {
            try { node.dispatchEvent(new Event(name, { bubbles: true })); } catch (e) {}
          });
        }
        function getter(object, name, read) {
          try { Object.defineProperty(object, name, { configurable: true, get: read }); } catch (e) {}
        }
        getter(Document.prototype, "fullscreenEnabled", function () { return true; });
        getter(Document.prototype, "webkitFullscreenEnabled", function () { return true; });
        getter(Document.prototype, "fullscreenElement", current);
        getter(Document.prototype, "webkitFullscreenElement", current);
        getter(Document.prototype, "webkitCurrentFullScreenElement", current);
        getter(Document.prototype, "webkitIsFullScreen", function () { return !!current(); });
        getter(Document.prototype, "fullscreen", function () { return !!current(); });

        function enter(target) {
          var previous = current();
          element = target;
          if (previous !== target) announce(target);
          post(true);
        }
        function exit() {
          var previous = current();
          element = null;
          if (previous) announce(previous);
          post(false);
        }
        Element.prototype.requestFullscreen = function () { enter(this); return Promise.resolve(); };
        Element.prototype.webkitRequestFullscreen = function () { enter(this); };
        Element.prototype.webkitRequestFullScreen = Element.prototype.webkitRequestFullscreen;
        Document.prototype.exitFullscreen = function () { exit(); return Promise.resolve(); };
        Document.prototype.webkitExitFullscreen = function () { exit(); };
        Document.prototype.webkitCancelFullScreen = Document.prototype.webkitExitFullscreen;
        /* The app reports when the native window leaves fullscreen because
           the stream ended or the user left it from the page's own control. */
        window.__xcgExitPageFullscreen = function () {
          var previous = current();
          element = null;
          if (previous) announce(previous);
        };
      } catch (e) { console.error("[XCG] fullscreen bridge failed", e); }
    })();
    """#

    /// Wraps navigator.getGamepads before Better xCloud or Xbox captures it:
    /// native motion values and the keyboard controller layout join the
    /// controller Xbox polls. Runs inside the Better xCloud wrapper so it can
    /// read `STATES`; also loaded on its own by the WebKit contract tests.
    static let inputAdapterScript = #"""
    // Install before Better xCloud or Xbox captures getGamepads.
    // Keep the actual controller identity, buttons and actuator; change only input values.
    const __xcgReadPhysicalPads = navigator.getGamepads.bind(navigator);
    const __xcgPollInput = {values:{}, at:-Infinity, reads:0, applied:0, lastAxes:[], lastLeftAxes:[], lastAllAxes:[], clock:0, lastHardware:-Infinity, wasActive:false, proxied:false, keyboardVersion:0, error:""};
    window.__xcgPollInput = __xcgPollInput;

    /* Keyboard & mouse as an Xbox controller, for games without keyboard &
       mouse support. Keys and mouse buttons press controller inputs and
       mouse movement becomes stick velocity, delivered through the
       controller Xbox already polls (or a stand-in when none is connected),
       so every press travels exactly the way a physical controller's does.
       The controller and the keyboard never play at once: whichever was
       used last is in control and the other is ignored. A key, a click or
       the wheel takes over; using a button, trigger or stick gives control
       back. Games with their own keyboard & mouse support are left to Xbox,
       and while it is in use the controller's motion output pauses. */
    const __xcgKeyboard = (function () {
      const config = {enabled:true, mapping:{}, mouseLook:2, invertY:false, sensitivity:1, compensation:0.2};
      Object.assign(config, window.__xcgKeyboardConfig || {});
      const held = new Map(), directionCounts = new Map(), order = {100:[], 200:[]}, wheelTimers = {};
      const mouse = {dx:0, dy:0, vx:0, vy:0, x:0, y:0, last:0, lastEvent:0, timer:0};
      const state = {buttons:new Array(17).fill(0), axes:[0,0,0,0], version:0, key:"", engaged:false, input:"controller"};
      const pad = {id:"Mac Xcloud Keyboard Controller (STANDARD GAMEPAD)", index:0, connected:true, mapping:"standard",
        axes:[0,0,0,0], buttons:Array.from({length:17}, () => ({pressed:false, touched:false, value:0})),
        timestamp:performance.now(), vibrationActuator:null, hapticActuators:[]};
      let padShown = false, padVersion = -1, reported = "", nativeUsed = false;

      function stream() {
        try {
          if (typeof STATES === "undefined" || !STATES) return null;
          const details = STATES.currentStream && STATES.currentStream.titleInfo && STATES.currentStream.titleInfo.details;
          return {playing:!!STATES.isPlaying, native:!!(details && details.hasMkbSupport)};
        } catch (e) { return null; }
      }
      function eligible() {
        const s = config.enabled ? stream() : null;
        return !!(s && s.playing && !s.native);
      }
      // A game playing with its own keyboard & mouse support.
      function nativeGame() {
        const s = stream();
        return !!(s && s.playing && s.native);
      }
      function useNative() {
        if (nativeUsed || !nativeGame()) return;
        nativeUsed = true;
        report();
      }
      function locked() { return document.pointerLockElement === document.body; }
      function editable(node) {
        return !!(node && (node.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(node.tagName || "")));
      }
      // "off" (no game), "ready" (nothing used yet), "keyboard", "mouse"
      // (keyboard with the mouse captured), "native" (the game's own
      // keyboard & mouse) or "controller" (back on the controller).
      function report() {
        const next = nativeGame() ? (nativeUsed ? "native" : state.engaged ? "controller" : "off")
          : !eligible() ? "off" : state.input === "keyboard" ? (locked() ? "mouse" : "keyboard")
          : state.engaged ? "controller" : "ready";
        if (next === reported) return;
        reported = next;
        try { window.webkit.messageHandlers.spikeHandler.postMessage({type:"mkb-emulation", state:next}); } catch (e) {}
      }
      function useKeyboard() {
        if (state.input === "keyboard") return;
        state.input = "keyboard";
        state.engaged = true;
        state.version++;
        report();
      }
      function useController() {
        if (nativeUsed) { nativeUsed = false; state.engaged = true; report(); }
        if (state.input === "controller") return;
        state.input = "controller";
        releaseAll();
        state.version++;
        report();
      }
      // Keys held on opposite sides of a stick: the newest wins.
      function stick(base) {
        let x = 0, y = 0;
        const list = order[base];
        for (let i = list.length - 1; i >= 0 && (x === 0 || y === 0); i--) {
          const direction = list[i] - base;
          if (x === 0 && direction >= 2) x = direction === 2 ? -1 : 1;
          if (y === 0 && direction < 2) y = direction === 0 ? -1 : 1;
        }
        if (x !== 0 && y !== 0) { x *= Math.SQRT1_2; y *= Math.SQRT1_2; }
        return [x, y];
      }
      function recompute() {
        const buttons = new Array(17).fill(0);
        held.forEach(index => { if (index >= 0 && index < 17) buttons[index] = 1; });
        const left = stick(100), right = stick(200);
        const axes = [left[0], left[1], right[0], right[1]];
        if (config.mouseLook && (mouse.x !== 0 || mouse.y !== 0)) {
          const base = config.mouseLook === 1 ? 0 : 2;
          let x = axes[base] + mouse.x, y = axes[base + 1] + mouse.y;
          const length = Math.hypot(x, y);
          if (length > 1) { x /= length; y /= length; }
          axes[base] = x; axes[base + 1] = y;
        }
        const key = buttons.join("") + "|" + axes.map(v => v.toFixed(3)).join(",");
        if (key === state.key) return;
        state.key = key; state.buttons = buttons; state.axes = axes; state.version++;
      }
      function press(code, index) {
        useKeyboard();
        if (held.get(code) === index) return;
        if (held.has(code)) release(code);
        held.set(code, index);
        if (index >= 100) {
          const base = index >= 200 ? 200 : 100, list = order[base], at = list.indexOf(index);
          directionCounts.set(index, (directionCounts.get(index) || 0) + 1);
          if (at !== -1) list.splice(at, 1);
          list.push(index);
        }
        state.engaged = true;
        recompute();
        report();
      }
      function release(code) {
        if (!held.has(code)) return;
        const index = held.get(code);
        held.delete(code);
        if (index >= 100) {
          const count = (directionCounts.get(index) || 1) - 1;
          if (count > 0) directionCounts.set(index, count);
          else {
            directionCounts.delete(index);
            const list = order[index >= 200 ? 200 : 100], at = list.indexOf(index);
            if (at !== -1) list.splice(at, 1);
          }
        }
        recompute();
      }
      function stopMouse() {
        if (mouse.timer) { clearInterval(mouse.timer); mouse.timer = 0; }
        mouse.dx = 0; mouse.dy = 0; mouse.vx = 0; mouse.vy = 0;
        if (mouse.x !== 0 || mouse.y !== 0) { mouse.x = 0; mouse.y = 0; recompute(); }
      }
      function releaseMouse() {
        Array.from(held.keys()).forEach(code => { if (/^(Mouse|Scroll)/.test(code)) release(code); });
        stopMouse();
      }
      function releaseAll() {
        held.clear(); directionCounts.clear(); order[100].length = 0; order[200].length = 0;
        stopMouse();
        recompute();
      }
      /* Mouse movement is accumulated and turned into stick velocity on a
         steady clock (one stick value per mouse event would flicker with
         event timing), smoothed lightly and released smoothly when the
         mouse stops. 600 px/s reaches full stick at sensitivity 1. */
      function stepMouse() {
        const now = performance.now();
        const dt = Math.max((now - mouse.last) / 1000, 0.001);
        mouse.last = now;
        const idle = now - mouse.lastEvent > 40;
        const rawX = mouse.dx / dt, rawY = mouse.dy / dt;
        mouse.dx = 0; mouse.dy = 0;
        const a = 1 - Math.exp(-dt / (idle ? 0.012 : 0.018));
        mouse.vx += (rawX - mouse.vx) * a; mouse.vy += (rawY - mouse.vy) * a;
        const speed = Math.hypot(mouse.vx, mouse.vy);
        let x = 0, y = 0;
        if (speed >= 15) {
          const scale = (Number(config.sensitivity) || 1) / 600;
          x = mouse.vx * scale; y = mouse.vy * scale * (config.invertY ? -1 : 1);
          const length = Math.hypot(x, y);
          // Lift the slowest movement past the game's stick dead zone.
          const weight = Math.min(Math.max(Number(config.compensation) || 0, 0), 0.5);
          const onset = Math.min(Math.max((speed - 15) / 40, 0), 1);
          const magnitude = Math.min(weight * onset + (1 - weight * onset) * Math.min(length, 1), 1);
          if (length > 0) { x *= magnitude / length; y *= magnitude / length; }
        }
        x = Math.round(x * 1000) / 1000; y = Math.round(y * 1000) / 1000;
        if (x !== mouse.x || y !== mouse.y) { mouse.x = x; mouse.y = y; recompute(); }
        if (idle && x === 0 && y === 0) { clearInterval(mouse.timer); mouse.timer = 0; mouse.vx = 0; mouse.vy = 0; }
      }
      // While the mouse is captured, a tap of Escape presses Menu (pause, as
      // on PC); holding it releases the mouse, and then presses nothing.
      let escapeDownAt = 0;
      function onEscape(event) {
        if (!locked() || !eligible()) { escapeDownAt = 0; return; }
        if (event.type === "keydown") { if (!event.repeat) escapeDownAt = performance.now(); return; }
        const tapped = escapeDownAt > 0 && performance.now() - escapeDownAt < 450;
        escapeDownAt = 0;
        if (!tapped) return;
        press("Escape", 9);
        setTimeout(() => release("Escape"), 90);
      }
      function onKey(event) {
        const code = event.code;
        if (!code) return;
        if (event.type === "keydown" && !event.metaKey && code !== "Escape" && !editable(event.target)) useNative();
        if (code === "Escape") { onEscape(event); return; }
        if (event.type === "keyup") {
          if (held.has(code)) { release(code); event.preventDefault(); event.stopImmediatePropagation(); }
          return;
        }
        // Command shortcuts belong to the Mac.
        if (event.metaKey) return;
        const index = config.mapping[code];
        if (typeof index !== "number" || editable(event.target) || !eligible()) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        if (!event.repeat) press(code, index);
      }
      function onMouseButton(event) {
        // The game's own keyboard & mouse captures the mouse on another element.
        if (event.type === "mousedown" && document.pointerLockElement) useNative();
        if (!locked()) return;
        const code = "Mouse" + event.button;
        if (event.type === "mouseup") { release(code); return; }
        const index = config.mapping[code];
        if (typeof index === "number" && eligible()) { event.preventDefault(); press(code, index); }
      }
      function onWheel(event) {
        if (document.pointerLockElement) useNative();
        if (!locked() || !eligible()) return;
        const code = event.deltaY < 0 ? "ScrollUp" : event.deltaY > 0 ? "ScrollDown"
          : event.deltaX < 0 ? "ScrollLeft" : event.deltaX > 0 ? "ScrollRight" : "";
        const index = config.mapping[code];
        if (typeof index !== "number") return;
        event.preventDefault();
        press(code, index);
        clearTimeout(wheelTimers[code]);
        // Long enough for the game to see one press per notch.
        wheelTimers[code] = setTimeout(() => release(code), 80);
      }
      function onMove(event) {
        const dx = Number(event.movementX) || 0, dy = Number(event.movementY) || 0;
        if (document.pointerLockElement && Math.abs(dx) + Math.abs(dy) >= 4) useNative();
        // Movement alone never takes over from the controller (a brushed
        // trackpad would); once the keyboard is in control it looks around.
        if (!config.mouseLook || !locked() || !eligible() || state.input !== "keyboard") return;
        const now = performance.now();
        mouse.dx += dx;
        mouse.dy += dy;
        mouse.lastEvent = now;
        if (!mouse.timer) { mouse.last = mouse.lastEvent; mouse.timer = setInterval(stepMouse, 8); }
      }
      // A click on the game captures the mouse for looking around.
      function onClick(event) {
        if (document.pointerLockElement || !eligible()) return;
        const target = event.target;
        if (!target || !target.closest || !target.closest("#game-stream")) return;
        if (!config.mouseLook && !Object.keys(config.mapping).some(k => /^(Mouse|Scroll)/.test(k))) return;
        try {
          const request = document.body.requestPointerLock();
          if (request && typeof request.catch === "function") request.catch(() => {});
        } catch (e) {}
      }
      try {
        window.addEventListener("keydown", onKey, true);
        window.addEventListener("keyup", onKey, true);
        document.addEventListener("mousedown", onMouseButton, true);
        document.addEventListener("mouseup", onMouseButton, true);
        document.addEventListener("wheel", onWheel, {capture:true, passive:false});
        document.addEventListener("mousemove", onMove, true);
        document.addEventListener("click", onClick, true);
        document.addEventListener("pointerlockchange", () => {
          if (!locked()) releaseMouse();
          report();
        });
        // Keys released while another window had focus never send keyup.
        window.addEventListener("blur", releaseAll);
        document.addEventListener("visibilitychange", () => { if (document.hidden) releaseAll(); });
        setInterval(() => {
          if (!eligible() && (held.size || state.input !== "controller")) {
            releaseAll(); state.input = "controller";
          }
          if (!eligible() && !nativeGame()) { state.engaged = false; nativeUsed = false; }
          report();
        }, 1000);
      } catch (e) {}

      return {
        state,
        configure(next) {
          Object.assign(config, next || {});
          if (!config.mouseLook) stopMouse();
          if (!config.enabled) { releaseAll(); state.engaged = false; }
          recompute();
          report();
        },
        releaseMouse() { releaseMouse(); report(); },
        useController() { useController(); },
        /* The keyboard is in control (and the game uses the layout). */
        typing() { return state.input === "keyboard" && eligible(); },
        /* The game's own keyboard & mouse support is in use. */
        nativeInUse() { return nativeUsed && nativeGame(); },
        /* With no controller connected the keyboard stands in for one, at
           the first free slot, announced the way a connected pad is. */
        standIn(pads) {
          if (!padShown) {
            let slot = 0;
            while (slot < pads.length && pads[slot] && pads[slot].connected !== false) slot++;
            pad.index = slot; padShown = true; padVersion = -1;
            setTimeout(() => {
              try { const event = new Event("gamepadconnected"); event.gamepad = pad; window.dispatchEvent(event); } catch (e) {}
            }, 0);
          }
          if (padVersion !== state.version) {
            padVersion = state.version;
            pad.axes = state.axes.slice();
            pad.buttons = state.buttons.map(v => ({pressed:v > 0.5, touched:v > 0, value:v}));
            pad.timestamp = performance.now();
          }
          return pad;
        },
        hideStandIn() {
          if (!padShown) return;
          padShown = false;
          pad.connected = false;
          setTimeout(() => {
            try { const event = new Event("gamepaddisconnected"); event.gamepad = pad; window.dispatchEvent(event); } catch (e) {}
            pad.connected = true;
          }, 0);
        },
        diagnostics() {
          return {enabled:config.enabled, eligible:eligible(), engaged:state.engaged, input:state.input, locked:locked(), nativeInUse:nativeUsed,
            held:Array.from(held.keys()), axes:state.axes.slice(), version:state.version,
            standIn:padShown ? pad.index : null, mapped:Object.keys(config.mapping).length};
        }
      };
    })();
    window.__xcgKeyboard = __xcgKeyboard;

    /* Whether the controller was just used: a button or trigger newly
       pressed, or a stick newly pushed out. Edges only, so a held trigger
       or a drifting stick cannot keep taking control back, and motion (a
       controller bumped on the desk) never does. */
    const __xcgControllerUse = {pressed:0, sticks:[false, false]};
    function __xcgControllerUsed(p) {
      let pressed = 0;
      Array.from(p.buttons).forEach((b, i) => {
        const value = b && typeof b === "object" ? Number(b.value) || 0 : Number(b) || 0;
        if (i < 17 && value > (i === 6 || i === 7 ? 0.3 : 0.5)) pressed |= (1 << i);
      });
      const sticks = [Math.hypot(p.axes[0], p.axes[1]) > 0.45, Math.hypot(p.axes[2], p.axes[3]) > 0.45];
      const last = __xcgControllerUse;
      // Tracked on every poll, so a button already held when the keyboard
      // took over is not mistaken for a new press.
      const used = (pressed & ~last.pressed) !== 0 || (sticks[0] && !last.sticks[0]) || (sticks[1] && !last.sticks[1]);
      last.pressed = pressed; last.sticks = sticks;
      return used;
    }

    const __xcgPollGamepads = function() {
      const pads = Array.from(__xcgReadPhysicalPads());
      __xcgPollInput.reads++;
      const connected = pads.filter(p => p && p.connected !== false);
      const keyboard = __xcgKeyboard.state;
      // Native motion and the keyboard ride on one standard controller.
      const p = connected.find(pad => pad.mapping === "standard" && pad.axes.length >= 4 && !/virtual/i.test(pad.id));
      if (!p) {
        if (keyboard.engaged && __xcgKeyboard.typing()) {
          const standIn = __xcgKeyboard.standIn(pads);
          pads[standIn.index] = standIn;
        } else {
          __xcgKeyboard.hideStandIn();
        }
        return pads;
      }
      __xcgKeyboard.hideStandIn();
      const now = performance.now(), n = __xcgPollInput.values;
      // Using the controller takes over from the keyboard (or from the
      // game's own keyboard & mouse): a new press or a stick pushed out.
      if (__xcgControllerUsed(p)) __xcgKeyboard.useController();
      const typing = __xcgKeyboard.typing();
      // With several controllers it is ambiguous which one the native
      // motion belongs to (local co-op): leave native input out. While the
      // game's own keyboard & mouse is in use, motion pauses too.
      const active = connected.length === 1 && now - __xcgPollInput.at < 200 && n.nativeControllerCount >= 1 &&
        !document.hidden && !window.BX_EXPOSED?.disableGamepadPolling && !__xcgKeyboard.nativeInUse();
      const keyboardChanged = keyboard.version !== __xcgPollInput.keyboardVersion;
      // Once a controller has been adjusted its timestamps are ours: Xbox
      // ignores any older one, so it is never handed back raw.
      if (!__xcgPollInput.proxied && !active && !typing && !keyboardChanged) return pads;
      __xcgPollInput.proxied = true;
      let axes = Array.from(p.axes), buttons = Array.from(p.buttons);
      const clamp = v => Math.max(-1, Math.min(1, v));
      if (active && !typing) {
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
        // A gyro pause button can be kept from the game.
        if (Number.isInteger(n.suppressButton) && buttons[n.suppressButton]) {
          buttons[n.suppressButton] = {value:0, pressed:false, touched:false};
        }
        __xcgPollInput.applied++;
      }
      if (typing) {
        // The keyboard plays alone: the controller's own buttons, sticks and
        // motion are set aside until it is used again.
        buttons = buttons.map((_, i) => {
          const value = i < 17 ? keyboard.buttons[i] : 0;
          return {value, pressed:value > 0.5, touched:value > 0};
        });
        axes = axes.map((_, i) => i < 4 ? keyboard.axes[i] : 0);
      }
      __xcgPollInput.lastAxes = axes.slice(2,4); // Legacy right-stick diagnostics.
      __xcgPollInput.lastLeftAxes = axes.slice(0,2);
      __xcgPollInput.lastAllAxes = axes.slice(0,4);
      // Motion alone must invalidate Xbox's timestamp-based unchanged-input skip.
      // At expiry, publish a newer timestamp with physical values to release aiming.
      // WebKit hardware timestamps can use a different origin from performance.now().
      // Never let a large hardware timestamp freeze motion-only updates.
      if (active || __xcgPollInput.wasActive || keyboardChanged || p.timestamp !== __xcgPollInput.lastHardware) {
        __xcgPollInput.clock = Math.max(__xcgPollInput.clock, p.timestamp || 0, now) + 0.01;
      }
      __xcgPollInput.wasActive = active;
      __xcgPollInput.keyboardVersion = keyboard.version;
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

    private static func wrappedScript(source: String) -> String {
        // Strip source-map comments; keep everything else intact.
        let stripped = source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//#") }
            .joined(separator: "\n")
        // The final send path handles both physical and native-only changes.
        let cleaned = stripped
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
          macroOverlay: true,
          nativeRumble: false
        };
        // Keyboard & mouse diagnostics. Passive counters prove whether
        // WKWebView delivers key and mouse events to the page; the pointer-lock
        // watcher tells the native side when the mouse is captured, so it can
        // route the Escape key.
        const __xcgMkbStats = { keyDowns: 0, lastKey: "", mouseMoves: 0,
          lastMovementX: 0, lastMovementY: 0, lastPointerLockError: "", pointerLocked: false,
          pointerLockSupported:
          (typeof HTMLElement === "function" && typeof HTMLElement.prototype.requestPointerLock === "function") };
        let __xcgLastMkbState = "";
        function __xcgPostMkbState() {
          const state = String(__xcgMkbStats.pointerLocked);
          if (state === __xcgLastMkbState) return;
          __xcgLastMkbState = state;
          try { window.webkit.messageHandlers.spikeHandler.postMessage({ type: "mkb-state",
            pointerLocked: __xcgMkbStats.pointerLocked }); } catch (e) {}
        }
        try {
          window.addEventListener("keydown", function (e) {
            __xcgMkbStats.keyDowns++; __xcgMkbStats.lastKey = e.code || e.key || "";
          }, { passive: true, capture: true });
          window.addEventListener("mousemove", function (e) {
            __xcgMkbStats.mouseMoves++;
            __xcgMkbStats.lastMovementX = e.movementX || 0;
            __xcgMkbStats.lastMovementY = e.movementY || 0;
          }, { passive: true, capture: true });
          document.addEventListener("pointerlockerror", function () {
            __xcgMkbStats.lastPointerLockError = String(new Date().toISOString());
            __xcgMkbStats.pointerLocked = !!document.pointerLockElement;
            __xcgLastMkbState = "";
            __xcgPostMkbState();
          });
          document.addEventListener("pointerlockchange", function () {
            __xcgMkbStats.pointerLocked = !!document.pointerLockElement;
            __xcgPostMkbState();
          });
        } catch (e) {}

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
          mkbDiagnostics: function () {
            const details = (STATES.currentStream && STATES.currentStream.titleInfo && STATES.currentStream.titleInfo.details) || null;
            let padCount = -1;
            try { padCount = Array.from(navigator.getGamepads()).filter(Boolean).length; } catch (e) {}
            return {
              userAgent: navigator.userAgent,
              platform: navigator.platform || "",
              maxTouchPoints: navigator.maxTouchPoints || 0,
              browserMkbCapability: !!(STATES.browser && STATES.browser.capabilities && STATES.browser.capabilities.mkb),
              pointerLockSupported: __xcgMkbStats.pointerLockSupported,
              pointerLockElement: document.pointerLockElement ? (document.pointerLockElement.tagName || "element") : null,
              lastPointerLockError: __xcgMkbStats.lastPointerLockError || "",
              keyDowns: __xcgMkbStats.keyDowns,
              lastKey: __xcgMkbStats.lastKey,
              mouseMoves: __xcgMkbStats.mouseMoves,
              lastMovementX: __xcgMkbStats.lastMovementX,
              lastMovementY: __xcgMkbStats.lastMovementY,
              gamepadAPIAvailable: typeof navigator.getGamepads === "function",
              gamepadCount: padCount,
              supportedInputTypes: (details && details.supportedInputTypes) || [],
              hasMkbSupport: details ? (details.hasMkbSupport === true ? true : (details.hasMkbSupport === false ? false : null)) : null,
              nativeMkbMode: getGlobalPref("nativeMkb.mode"),
              inputChannelAvailable: !!(window.BX_EXPOSED && window.BX_EXPOSED.inputChannel),
              streamSessionAvailable: !!(window.BX_EXPOSED && window.BX_EXPOSED.streamSession),
              updateInputConfigurationAvailable: !!(window.BX_EXPOSED && window.BX_EXPOSED.streamSession &&
                typeof window.BX_EXPOSED.streamSession.updateInputConfigurationAsync === "function"),
              keyboardLockShim: !!navigator.keyboard,
              pageFullscreen: !!document.fullscreenElement,
              controllerLayout: window.__xcgKeyboard ? window.__xcgKeyboard.diagnostics() : null,
              route: (function () {
                if (details && details.hasMkbSupport) return "Native keyboard & mouse (the game supports it)";
                const layout = window.__xcgKeyboard ? window.__xcgKeyboard.diagnostics() : { enabled: false };
                return layout.enabled ? "Controller layout (the game is made for controllers)"
                  : "Controller layout is turned off in Mac Xcloud settings";
              })()
            };
          },
          /* Applies the keyboard & mouse layout and settings to the running
             page; takes effect at once. */
          configureKeyboard: function (config) {
            if (!window.__xcgKeyboard) return false;
            window.__xcgKeyboard.configure(config);
            return true;
          },
          /* Escape while the mouse is captured: the native app intercepts the
             key before WebKit (which would release the mouse) and forwards it
             as a page event, so a quick press reaches the game. */
          forwardEscape: function (down) {
            try {
              const init = { key: "Escape", code: "Escape", keyCode: 27, which: 27, bubbles: true, cancelable: true };
              (document.activeElement || document.body || window).dispatchEvent(new KeyboardEvent(down ? "keydown" : "keyup", init));
              return true;
            } catch (e) { return false; }
          },
          releasePointer: function () {
            try {
              if (window.__xcgKeyboard) window.__xcgKeyboard.releaseMouse();
              if (document.pointerLockElement) document.exitPointerLock();
              return true;
            } catch (e) { return false; }
          },
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
            // Same rule as the polling adapter: native input belongs to the
            // only connected controller, never to one of several.
            let padMatches = pads.length === 1 && sample.GamepadIndex === pads[0].index;
            if (!window.__xcgPollInput?.installed && sample.Virtual !== true && padMatches &&
                __xcgNativeInput.nativeControllerCount >= 1 &&
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
              nativeMkbMode: String(getGlobalPref("nativeMkb.mode") || "default"),
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
            // Keyboard & mouse switches are app-wide (they take effect when the
            // page loads), so a game profile never changes them.
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
            /* The raw video receiver figures: the network's own jitter
               (Better xCloud's "jitter" is the playout buffer's delay),
               picture freezes and the decoded height. */
            var video = collector.lastVideoStat || {};
            return {
              display: Object.fromEntries(Object.entries(stats).map(([key, value]) => [key, value.toString()])),
              ping: finite(stats.ping && stats.ping.current, -1),
              fps: finite(stats.fps && stats.fps.current, 0),
              bitrate: finite(stats.btr && stats.btr.current, 0),
              loss: {
                packets: finite(pl.dropped, 0),
                received: finite(pl.received, 0),
                packetPercent: finite(pl.dropped, 0) * 100 / Math.max(1, finite(pl.received, 0) + finite(pl.dropped, 0)),
                frames: finite(fl.dropped, 0),
                framePercent: finite(fl.dropped, 0) * 100 / Math.max(1, finite(fl.received, 0) + finite(fl.dropped, 0))
              },
              frames: { received: finite(fl.received, 0), dropped: finite(fl.dropped, 0), freezes: finite(video.freezeCount, 0) },
              jitter: finite(stats.jit && stats.jit.current, 0),
              networkJitter: finite(video.jitter, 0) * 1000,
              height: finite(video.frameHeight, 0),
              resolution: String(stats.res && stats.res.current || ""),
              decodeTime: finite(dt.current, 0)
            };
          },
          regionList: function () { try { return Object.keys(STATES.serverRegions).map(function (k) { var r = STATES.serverRegions[k]; return { name: k, displayName: r.displayName || k, shortName: r.shortName || k, baseUri: r.baseUri || '' }; }); } catch (e) { return []; } },
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
        // A fresh page starts with keyboard & mouse released; say so, so the
        // app never carries state over from the page it replaced.
        __xcgPostMkbState();
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
            \(inputAdapterScript)
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
        /* Every Better xCloud surface has a native counterpart in the app:
           settings and profile dialogs, key binding, badges, the virtual
           controller prompt. None of its web UI is shown. */
        '.bx-mkb-pointer-lock-msg,.bx-settings-dialog,.bx-settings-tabs-container,.bx-key-binding-dialog,.bx-key-binding-dialog-overlay,.bx-navigation-dialog-overlay,.bx-fullscreen-text,.bx-badges { display:none !important; }',
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
}
