//
//  WebView.swift
//  Xbox Cloud Gaming
//
//  Created by Arunya on 02/09/26.
//

import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    @ObservedObject var browser: BrowserModel

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Per-profile persistent store keeps the Microsoft sign-in (and each
        // profile's session) across app relaunches.
        config.websiteDataStore = browser.activeDataStore

        let contentController = WKUserContentController()
        contentController.addUserScript(
            WKUserScript(source: Coordinator.spikeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        contentController.add(context.coordinator, name: "spikeHandler")
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        browser.webView = webView
        webView.load(URLRequest(url: BrowserModel.homeURL))
        return webView
    }

    func updateNSView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let browser: BrowserModel

        init(browser: BrowserModel) {
            self.browser = browser
        }

        /// Reports environment capabilities and polls for connected gamepads,
        /// messaging the native side whenever the set of controllers changes.
        static let spikeScript = #"""
        (function () {
          function send(type, data) {
            try {
              window.webkit.messageHandlers.spikeHandler.postMessage(Object.assign({ type: type }, data));
            } catch (e) {}
          }
          send('env', {
            url: location.href,
            gamepadAPI: typeof navigator.getGamepads === 'function',
            webrtc: typeof RTCPeerConnection !== 'undefined',
            ua: navigator.userAgent
          });
          var last = 'init';
          var lastSignedOut = null;
          setInterval(function () {
            try {
              if (typeof navigator.getGamepads !== 'function') { return; }
              var pads = Array.from(navigator.getGamepads()).filter(Boolean);
              var ids = pads.map(function (p) { return p.id; });
              var state = JSON.stringify(ids);
              if (state !== last) {
                last = state;
                send('gamepads', { count: ids.length, ids: ids });
              }
              var text = document.body ? document.body.innerText.slice(0, 1500).toLowerCase() : '';
              var signedOut = text.indexOf('sign in') !== -1;
              if (signedOut !== lastSignedOut) {
                lastSignedOut = signedOut;
                send('authcheck', { signedOut: signedOut, url: location.href });
              }
            } catch (e) {
              send('gamepad-error', { detail: String(e) });
            }
          }, 1500);
        })();
        """#
    }
}

extension WebView.Coordinator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        NSLog("XCG nav request: %@", navigationAction.request.url?.absoluteString ?? "nil")
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        NSLog("XCG nav start")
        browser.setLoading(true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("XCG load FAILED: %@", error.localizedDescription)
        browser.setLoading(false)
        browser.note("Load failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("XCG nav didFinish: %@", webView.url?.absoluteString ?? "nil")
        browser.setLoading(false)
        browser.syncNavState()

        // Belt-and-braces: probe the signed-in state directly, in addition to
        // the injected polling script.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let webView = self.browser.webView else { return }
            webView.evaluateJavaScript(Self.signedOutProbe) { result, _ in
                MainActor.assumeIsolated {
                    if let signedOut = result as? Bool {
                        NSLog("XCG probe signedOut=%d", signedOut ? 1 : 0)
                        self.browser.handleAuthCheck(signedOut: signedOut)
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("XCG nav FAILED: %@", error.localizedDescription)
        browser.setLoading(false)
        browser.note("Navigation failed: \(error.localizedDescription)")
    }

    static let signedOutProbe = """
    (function () {
      try {
        var t = document.body ? document.body.innerText.slice(0, 1500).toLowerCase() : '';
        return t.indexOf('sign in') !== -1;
      } catch (e) { return true; }
    })();
    """
}

extension WebView.Coordinator: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        browser.handleSpikeMessage(message)
    }
}
