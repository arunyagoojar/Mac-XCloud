// WebKit contract for the keyboard & mouse controller layout: the app's input
// adapter, in a real WKWebView, read by a poll loop that behaves like Xbox's
// stream client (navigator.getGamepads() every 4 ms; a pad's state is taken
// only when its timestamp increases). Covers playing with no controller
// connected and with one, plus everything that must not press anything.
import AppKit
import WebKit

final class Harness: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var pages: [WKWebView] = []
    var window: NSWindow!
    var messages: [String: [String]] = [:]
    var failures = 0, passes = 0

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], body["type"] as? String == "mkb-emulation" else { return }
        let key = m.webView.map { "\(ObjectIdentifier($0).hashValue)" } ?? "?"
        messages[key, default: []].append(body["state"] as? String ?? "")
    }

    func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1; print("PASS: \(label)") } else { failures += 1; print("FAIL: \(label) \(detail())") }
    }

    /// A page with the adapter installed. `physicalPad` stubs one connected
    /// DualSense the way WebKit would expose it.
    func makePage(physicalPad: Bool, native: Bool = false, enabled: Bool = true) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        let mapping = KeyboardLayout(id: UUID(), name: "Test", bindings: BuiltInKeyboardLayouts.standard.bindings).pageMapping
        let configuration: [String: Any] = ["enabled": enabled, "mapping": mapping, "mouseLook": 2, "invertY": false,
                                            "sensitivity": 1, "compensation": 0.2]
        let json = String(data: try! JSONSerialization.data(withJSONObject: configuration), encoding: .utf8)!
        let stub = physicalPad ? """
            (function () {
              const pad = { id: "DualSense Wireless Controller Extended Gamepad", index: 0, connected: true, mapping: "standard",
                axes: [0, 0, 0, 0], buttons: Array.from({length: 17}, () => ({pressed: false, touched: false, value: 0})),
                timestamp: 1000, vibrationActuator: null };
              window.__testPad = pad;
              navigator.getGamepads = function () { return [pad, null, null, null]; };
            })();
            """ : "navigator.getGamepads = function () { return [null, null, null, null]; };"
        ucc.addUserScript(WKUserScript(source: stub, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: "window.__xcgKeyboardConfig = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // The adapter runs inside the Better xCloud wrapper there; STATES is
        // Better xCloud's stream state.
        let states = "var STATES = { isPlaying: false, currentStream: { titleInfo: { details: { hasMkbSupport: \(native) } } } };"
        ucc.addUserScript(WKUserScript(source: states + "\n" + BetterXCloud.inputAdapterScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(self, name: "spikeHandler")
        config.userContentController = ucc
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), configuration: config)
        let html = """
        <html><body><div id="game-stream" style="width:600px;height:300px"></div><input id="chat"><script>
        // Xbox's input manager: poll every 4 ms, take a pad only when its timestamp moves.
        window.seen = {}; window.connectedEvents = 0;
        const last = {};
        window.addEventListener("gamepadconnected", e => { if (e.gamepad && /Keyboard/.test(e.gamepad.id)) window.connectedEvents++; });
        // Background test windows throttle timers, so the test drives the
        // poll itself: one call is one pass of Xbox's 4 ms loop.
        window.poll = () => {
          for (const pad of navigator.getGamepads()) {
            if (!pad || !pad.connected) continue;
            if (last[pad.index] !== undefined && !(pad.timestamp > last[pad.index])) continue;
            last[pad.index] = pad.timestamp;
            window.seen[pad.index] = { id: pad.id, a: pad.buttons[0].value, b: pad.buttons[1].value, rt: pad.buttons[7].value,
              axes: Array.from(pad.axes).map(v => Math.round(v * 1000) / 1000) };
          }
        };
        window.key = (type, code, target) => {
          (target || window).dispatchEvent(new KeyboardEvent(type, { code, key: code, bubbles: true, cancelable: true }));
        };
        // Let the stand-in's connection event (posted with setTimeout) arrive, then poll.
        window.wait = async ms => { await new Promise(r => setTimeout(r, Math.min(ms, 5))); poll(); };
        </script></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://www.xbox.com/en-US/play/launch/test/9NR1R1XWLCNB"))
        pages.append(web)
        return web
    }

    func run(_ web: WKWebView, _ script: String) async -> [String: Any] {
        (try? await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]) ?? [:]
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        let standalone = makePage(physicalPad: false)
        let withPad = makePage(physicalPad: true)
        let nativeGame = makePage(physicalPad: true, native: true)
        let disabled = makePage(physicalPad: false, enabled: false)
        window.contentView = standalone
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            // No controller connected: the keyboard stands in for one.
            var r = await run(standalone, """
                STATES.isPlaying = true;
                key("keydown", "Space"); await wait(40);
                const pressed = JSON.parse(JSON.stringify(seen[0] || null));
                key("keyup", "Space"); await wait(40);
                const released = JSON.parse(JSON.stringify(seen[0] || null));
                key("keydown", "KeyW"); key("keydown", "KeyD"); await wait(40);
                const diagonal = JSON.parse(JSON.stringify(seen[0] || null));
                key("keydown", "KeyA"); await wait(40);
                const newest = JSON.parse(JSON.stringify(seen[0] || null));
                key("keyup", "KeyA"); key("keyup", "KeyD"); key("keyup", "KeyW"); await wait(40);
                const centered = JSON.parse(JSON.stringify(seen[0] || null));
                return { pressed, released, diagonal, newest, centered, connectedEvents };
                """)
            let pressed = r["pressed"] as? [String: Any]
            check((pressed?["a"] as? Double) == 1 && (pressed?["id"] as? String ?? "").contains("Keyboard"),
                  "With no controller, Space presses A on a stand-in controller Xbox polls", "\(r)")
            check((r["connectedEvents"] as? Int ?? 0) == 1, "The stand-in controller is announced once with gamepadconnected", "\(r)")
            check(((r["released"] as? [String: Any])?["a"] as? Double) == 0, "Releasing Space releases A")
            let diagonal = (r["diagonal"] as? [String: Any])?["axes"] as? [Double] ?? []
            check(diagonal.count == 4 && abs(diagonal[0] - 0.707) < 0.01 && abs(diagonal[1] + 0.707) < 0.01,
                  "W + D moves the left stick up-right, kept inside the stick's circle", "\(diagonal)")
            let newest = (r["newest"] as? [String: Any])?["axes"] as? [Double] ?? []
            check(newest.count == 4 && newest[0] < -0.5, "Of opposite keys, the newest wins (A after D moves left)", "\(newest)")
            let centered = (r["centered"] as? [String: Any])?["axes"] as? [Double] ?? []
            check(centered == [0, 0, 0, 0], "Releasing every key centers the stick", "\(centered)")

            // A controller connected: keys add to it; the pad's own buttons stay.
            r = await run(withPad, """
                STATES.isPlaying = true;
                await wait(30);
                const before = JSON.parse(JSON.stringify(seen[0] || null));
                key("keydown", "KeyE"); await wait(40);
                const pressed = JSON.parse(JSON.stringify(seen[0] || null));
                key("keyup", "KeyE"); await wait(40);
                const released = JSON.parse(JSON.stringify(seen[0] || null));
                __testPad.buttons[1] = { pressed: true, touched: true, value: 1 }; __testPad.timestamp += 5; await wait(40);
                __testPad.buttons[1] = { pressed: false, touched: false, value: 0 };
                const physical = JSON.parse(JSON.stringify(seen[0] || null));
                const pads = navigator.getGamepads().filter(Boolean).length;
                return { before, pressed, released, physical, pads };
                """)
            check(((r["pressed"] as? [String: Any])?["a"] as? Double) == 1 && ((r["pressed"] as? [String: Any])?["id"] as? String ?? "").contains("DualSense"),
                  "With a controller connected, E presses A on that controller", "\(r)")
            check((r["pads"] as? Int) == 1, "No second controller appears next to a real one", "\(r)")
            check(((r["released"] as? [String: Any])?["a"] as? Double) == 0, "Releasing E releases A on the controller")
            check(((r["physical"] as? [String: Any])?["b"] as? Double) == 1, "The controller's own buttons keep working after keyboard use", "\(r)")

            // What must not press anything.
            r = await run(withPad, """
                document.getElementById("chat").focus();
                key("keydown", "Space", document.getElementById("chat")); await wait(40);
                const typing = JSON.parse(JSON.stringify(seen[0] || null));
                key("keyup", "Space", document.getElementById("chat"));
                document.getElementById("chat").blur();
                window.dispatchEvent(new KeyboardEvent("keydown", { code: "KeyR", key: "r", metaKey: true, bubbles: true }));
                await wait(40);
                const command = JSON.parse(JSON.stringify(seen[0] || null));
                window.dispatchEvent(new KeyboardEvent("keyup", { code: "KeyR", key: "r", metaKey: true, bubbles: true }));
                STATES.isPlaying = false;
                key("keydown", "Space"); await wait(40);
                const menus = JSON.parse(JSON.stringify(seen[0] || null));
                key("keyup", "Space");
                return { typing, command, menus };
                """)
            check(((r["typing"] as? [String: Any])?["a"] as? Double) == 0, "Typing in a text field presses nothing", "\(r)")
            check(((r["command"] as? [String: Any])?["x"] as? Double ?? 0) == 0 && ((r["command"] as? [String: Any])?["a"] as? Double) == 0,
                  "Command shortcuts are left to the Mac")
            check(((r["menus"] as? [String: Any])?["a"] as? Double) == 0, "Outside a game, keys are left to the Xbox page", "\(r)")

            r = await run(nativeGame, """
                STATES.isPlaying = true;
                let reached = false;
                window.addEventListener("keydown", () => { reached = true; });
                key("keydown", "Space"); await wait(40);
                const seenState = JSON.parse(JSON.stringify(seen[0] || null));
                key("keyup", "Space");
                return { a: seenState ? seenState.a : 0, reached };
                """)
            check((r["a"] as? Double ?? 0) == 0 && (r["reached"] as? Bool) == true,
                  "In a game with keyboard & mouse support, keys go to the game as keys", "\(r)")

            r = await run(disabled, """
                STATES.isPlaying = true;
                key("keydown", "Space"); await wait(40);
                return { pads: navigator.getGamepads().filter(Boolean).length };
                """)
            check((r["pads"] as? Int) == 0, "With the controller layout turned off, nothing is pressed or added")

            // Live configuration: a new layout applies without a reload.
            r = await run(standalone, """
                window.__xcgKeyboard.configure({ mapping: { KeyP: 0 } });
                key("keydown", "Space"); await wait(40);
                const old = seen[0].a;
                key("keyup", "Space");
                key("keydown", "KeyP"); await wait(40);
                const remapped = seen[0].a;
                key("keyup", "KeyP");
                return { old, remapped };
                """)
            check((r["old"] as? Double) == 0 && (r["remapped"] as? Double) == 1, "A changed layout applies to the running game at once", "\(r)")

            // Gyro as a mouse: one relative movement per native update, never repeated.
            r = await run(withPad, """
                const calls = [];
                window.BX_EXPOSED = { inputChannel: { queueMouseInput: e => calls.push(e) } };
                __xcgGyroMouse.apply({ mouseSeq: 1, mouseX: 5, mouseY: -3 });
                __xcgGyroMouse.apply({ mouseSeq: 1, mouseX: 5, mouseY: -3 });
                __xcgGyroMouse.apply({ mouseSeq: 2, mouseX: 0, mouseY: 0 });
                __xcgGyroMouse.apply({ gyroX: 0.2 });
                return { calls: JSON.stringify(calls) };
                """)
            check((r["calls"] as? String) == #"[{"X":5,"Y":-3,"Buttons":0,"WheelX":0,"WheelY":0,"Type":0}]"#,
                  "Gyro mouse movement reaches Xbox's input channel once per update, as relative movement", "\(r)")

            // Escape: a tap while the mouse is captured presses Menu briefly;
            // a hold (which releases the mouse) presses nothing.
            r = await run(standalone, """
                Object.defineProperty(document, "pointerLockElement", { configurable: true, get: () => document.body });
                const states = [];
                const snap = () => { poll(); return seen[0].a + "/" + (navigator.getGamepads()[0].buttons[9].value); };
                key("keydown", "Escape"); await wait(5);
                key("keyup", "Escape"); await wait(5);
                states.push(navigator.getGamepads()[0].buttons[9].value);
                await new Promise(r => setTimeout(r, 150)); poll();
                states.push(navigator.getGamepads()[0].buttons[9].value);
                key("keydown", "Escape"); await new Promise(r => setTimeout(r, 600));
                key("keyup", "Escape"); await wait(5);
                states.push(navigator.getGamepads()[0].buttons[9].value);
                delete document.pointerLockElement;
                return { states: states.join(",") };
                """)
            check((r["states"] as? String) == "1,0,0", "Tapping Esc presses Menu once; holding it to release the mouse presses nothing", "\(r)")

            let reported = messages.values.flatMap { $0 }
            check(reported.contains("keys"), "The page tells the app when keyboard controls are in use", "\(messages)")

            print(failures == 0 ? "\(passes) keyboard layer contract checks passed." : "\(failures) keyboard layer checks FAILED.")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

@main
struct KeyboardLayerContracts {
    static func main() {
        let app = NSApplication.shared
        let harness = Harness()
        app.delegate = harness
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
