//
//  WebView.swift
//  Mac XCloud
//
//  Created by Arunya on 02/09/26.
//

import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    @ObservedObject var browser: BrowserModel

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The persistent default store keeps the Microsoft sign-in across
        // app relaunches.
        config.websiteDataStore = .default()

        let contentController = WKUserContentController()
        // Better xCloud injection (stats, region, quality, splash skip, …)
        // plus the app's own capability/gamepad polling script.
        for script in BetterXCloud.userScripts() {
            contentController.addUserScript(script)
        }
        contentController.addUserScript(
            WKUserScript(source: Coordinator.capabilitiesScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
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

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        if coordinator.browser.webView === nsView {
            coordinator.browser.webView = nil
        }
        nsView.navigationDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "spikeHandler")
        nsView.stopLoading()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser)
    }

    @MainActor
    final class Coordinator: NSObject {
        fileprivate let browser: BrowserModel

        init(browser: BrowserModel) {
            self.browser = browser
        }

        /// Reports environment capabilities and polls for connected gamepads,
        /// messaging the native side whenever the set of controllers changes.
        static let capabilitiesScript = #"""
        (function () {
          function send(type, data) {
            try {
              window.webkit.messageHandlers.spikeHandler.postMessage(Object.assign({ type: type }, data));
            } catch (e) {}
          }
          var didSendReady = false;
          function sendSiteReady() {
            if (didSendReady) return;
            var readyState = document.readyState;
            var interactive = readyState === 'interactive' || readyState === 'complete';
            var host = location.hostname || '';
            var isAuth = host.indexOf('login.live.com') !== -1 || host.indexOf('login.microsoftonline.com') !== -1;
            var hasAuthForm = !!document.querySelector('input[type="email"], input[name="loginfmt"], form');
            var hasXboxShell = !!document.querySelector('#PageContent, [class*="HomePage"], main, [role="main"]');
            var bridgeReady = typeof window.BxCBridge === 'object';
            if (!interactive || !(isAuth ? hasAuthForm : (hasXboxShell && bridgeReady))) return;
            didSendReady = true;
            send('site-ready', {
              url: location.href,
              readyState: readyState,
              bridgeReady: bridgeReady,
              bridgeCapabilities: window.BxCBridge && window.BxCBridge.capabilities || null
            });
          }
          send('env', {
            url: location.href,
            gamepadAPI: typeof navigator.getGamepads === 'function',
            webrtc: typeof RTCPeerConnection !== 'undefined',
            ua: navigator.userAgent
          });
          sendSiteReady();
          window.addEventListener('bxc-bridge-ready', sendSiteReady);
          document.addEventListener('readystatechange', sendSiteReady);
          try {
            new MutationObserver(sendSiteReady).observe(document.documentElement, { childList: true, subtree: true });
          } catch (e) {}
          var last = 'init';
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
            } catch (e) {
              send('gamepad-error', { detail: String(e) });
            }
          }, 1500);
        })();
        """#
    }
}

extension WebView.Coordinator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        browser.navigationStarted()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        browser.syncNavState()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        browser.syncNavState()
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        browser.setLoading(false)
        browser.syncNavState()
        // Re-sync cursor auto-hide state with every fresh page load.
        let connected = !browser.report.nativeControllerIDs.isEmpty
        webView.evaluateJavaScript("window.postMessage({ type: 'xcg-cursor-hide', enabled: \(connected) }, '*')", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        browser.navigationFailed(error, url: webView.url)
        browser.note("Navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        browser.navigationFailed(error, url: webView.url)
        browser.note("Load failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        browser.webContentTerminated()
        browser.note("Web content process terminated")
    }
}

extension WebView.Coordinator: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        browser.handleSpikeMessage(message)
    }
}
