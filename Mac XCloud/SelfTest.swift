#if DEBUG
import AppKit
import WebKit

/// Development aid: launch with `--xcg-selftest <directory>`. Loads the Xbox
/// page as usual (no game is started), waits for the injected scripts, checks
/// they initialized without errors, records the app's windows, writes
/// `selftest.json` and quits.
@MainActor
enum SelfTest {
    /// Collects script errors from the first moment of every page.
    static let errorCollector = """
    (function () {
      window.__xcgErrors = [];
      window.__xcgResourceErrors = 0;
      window.addEventListener("error", function (e) {
        // Failed loads (blocked trackers, images) are not script errors.
        if (!(e instanceof ErrorEvent)) { window.__xcgResourceErrors++; return; }
        try { window.__xcgErrors.push(String(e.message || e.error) + " @ " + (e.filename || "") + ":" + (e.lineno || 0)); } catch (x) {}
      }, true);
      window.addEventListener("unhandledrejection", function (e) {
        try { window.__xcgErrors.push("unhandled rejection: " + String(e.reason)); } catch (x) {}
      });
    })();
    """

    static func run(browser: BrowserModel, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { @MainActor in
            var waited = 0.0
            while !browser.bridgeReady && waited < 60 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 0.5
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            var result: [String: Any] = ["bridgeReady": browser.bridgeReady, "secondsToBridge": waited]
            let script = """
                const out = {};
                out.url = location.href;
                out.bridge = typeof window.BxCBridge === "object";
                out.adapterInstalled = !!(window.__xcgPollInput && window.__xcgPollInput.installed);
                out.getGamepadsIsAdapter = !!window.__xcgPollInput && navigator.getGamepads.toString().includes("__xcgReadPhysicalPads");
                out.keyboard = window.__xcgKeyboard ? window.__xcgKeyboard.diagnostics() : null;
                out.gyroMouse = window.__xcgGyroMouse ? window.__xcgGyroMouse.diagnostics() : null;
                try { out.mkb = window.BxCBridge.mkbDiagnostics(); } catch (e) { out.mkbError = String(e); }
                try { out.audio = window.BxCBridge.setAudioHaptics(false); } catch (e) { out.audioError = String(e); }
                try { out.configure = window.BxCBridge.configureKeyboard({}); } catch (e) { out.configureError = String(e); }
                out.keyboardLock = !!navigator.keyboard;
                out.errors = (window.__xcgErrors || []).slice(0, 20);
                out.resourceErrors = window.__xcgResourceErrors || 0;
                return JSON.stringify(out);
                """
            do {
                if let text = try await browser.callAsyncJS(script) as? String,
                   let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    result["page"] = object
                }
            } catch { result["pageError"] = error.localizedDescription }
            result["visibleWindows"] = NSApp.windows.filter(\.isVisible).map { "\($0.identifier?.rawValue ?? "-") | \($0.title)" }
            result["allWindows"] = NSApp.windows.map { "\($0.identifier?.rawValue ?? "-") | \($0.title) | \(type(of: $0))" }
            result["recentGames"] = browser.gameLibrary.recent.map { "\($0.id) \($0.title)" }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("selftest.json"))
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
