// WebKit contract for keyboard & mouse: the app's injected scripts, in a real
// WKWebView, against a page that makes the same checks Xbox's stream client
// makes before it enables keyboard and mouse.
import AppKit
import WebKit

final class Harness: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var web: WKWebView!, window: NSWindow!
    var results: [String] = []
    var nativeFullscreenRequests: [Bool] = []
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        if let body = m.body as? [String: Any], body["type"] as? String == "app-fullscreen" {
            nativeFullscreenRequests.append(body["enter"] as? Bool ?? false); return
        }
        results.append("\(m.body)")
    }
    func applicationDidFinishLaunching(_ n: Notification) {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: BetterXCloud.compatibilityScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: BetterXCloud.fullscreenBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(self, name: "log"); ucc.add(self, name: "spikeHandler")
        cfg.userContentController = ucc
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), configuration: cfg)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFront(nil)
        // A page reproducing the checks Xbox's stream client makes (game-stream chunk).
        let html = """
        <html><body><div id="game-stream" tabindex="-1" style="width:600px;height:300px"></div><script>
        const log = (k, v) => webkit.messageHandlers.log.postMessage(k + "=" + v);
        const root = document.getElementById("game-stream");
        let rootEvents = 0; root.addEventListener("fullscreenchange", () => rootEvents++);
        const isFullscreen = () => (document.fullscreenElement ?? document.webkitFullscreenElement) === root;
        window.runChecks = async function () {
          log("keyboardSupported", !!navigator.keyboard);
          log("mouseSupported", !!document.exitPointerLock);
          log("fullscreenSupported", document.fullscreenEnabled || !!document.webkitFullscreenEnabled);
          try { await navigator.keyboard.lock(["Escape"]); log("keyboardLock", "resolved"); } catch (e) { log("keyboardLock", "rejected " + e); }
          log("isFullscreenBefore", isFullscreen());
          await root.requestFullscreen({ navigationUI: "hide" });
          log("isFullscreenAfterRequest", isFullscreen());
          log("rootFullscreenEvents", rootEvents);
          let escapes = [];
          window.addEventListener("keydown", e => escapes.push("down:" + e.code + ":" + e.key));
          window.addEventListener("keyup", e => escapes.push("up:" + e.code));
          // The exact dispatch BxCBridge.forwardEscape performs.
          for (const down of [true, false]) {
            const init = { key: "Escape", code: "Escape", keyCode: 27, which: 27, bubbles: true, cancelable: true };
            (document.activeElement || document.body || window).dispatchEvent(new KeyboardEvent(down ? "keydown" : "keyup", init));
          }
          log("forwardedEscape", escapes.join(","));
          await document.exitFullscreen();
          log("isFullscreenAfterExit", isFullscreen());
          log("rootFullscreenEventsAfterExit", rootEvents);
          return "done";
        };
        </script></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://www.xbox.com/en-US/play/games/x"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.web.callAsyncJavaScript("return await window.runChecks();", arguments: [:], in: nil, in: .page) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let expected = [
                        "keyboardSupported=true": "Xbox sees keyboard support (Keyboard Lock stand-in present)",
                        "mouseSupported=true": "Xbox sees mouse support",
                        "fullscreenSupported=true": "Xbox sees fullscreen support",
                        "keyboardLock=resolved": "keyboard.lock() resolves, so Xbox forwards keys to the game",
                        "isFullscreenBefore=false": "The stream starts windowed",
                        "isFullscreenAfterRequest=true": "Requesting fullscreen makes the stream root the fullscreen element",
                        "rootFullscreenEvents=1": "fullscreenchange fires on the requested element itself",
                        "forwardedEscape=down:Escape:Escape,up:Escape": "A forwarded Escape reaches the page's key listeners",
                        "isFullscreenAfterExit=false": "Exiting fullscreen clears the element",
                        "rootFullscreenEventsAfterExit=2": "Exiting fires fullscreenchange on the element",
                    ]
                    var failed = false
                    for (line, label) in expected.sorted(by: { $0.key < $1.key }) {
                        let ok = self.results.contains(line)
                        print("\(ok ? "PASS" : "FAIL"): \(label)\(ok ? "" : " — got \(self.results)")")
                        failed = failed || !ok
                    }
                    let native = self.nativeFullscreenRequests == [true, false]
                    print("\(native ? "PASS" : "FAIL"): The page asks the window to enter, then leave, native full screen")
                    if failed || !native { exit(1) }
                    print("\(expected.count + 1) WebKit keyboard & mouse contract checks passed.")
                    exit(0)
                }
            }
        }
    }
}
@main
struct WebKitContracts {
    static func main() {
        let app = NSApplication.shared
        let harness = Harness()
        app.delegate = harness
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
