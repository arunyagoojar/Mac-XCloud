//
//  ContentView.swift
//  Mac XCloud
//
//  Created by Arunya on 02/09/26.
//

import SwiftUI

/// Invisible bootstrap view: SwiftUI's WindowGroup window keeps a titlebar
/// strip no matter what, so it immediately hands off to our own AppKit main
/// window (created chrome-less) and closes itself.
struct MainWindowLauncher: View {
    @EnvironmentObject private var browser: BrowserModel

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .onAppear {
                browser.openMainWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    for window in NSApp.windows where window.identifier?.rawValue != "xcg-main" && window.isVisible {
                        // Only close SwiftUI's empty launcher window.
                        if window.frame.width >= 800, window.title == "Mac Xcloud" || window.title.isEmpty {
                            window.close()
                        }
                    }
                }
            }
    }
}

/// Invisible replacement for the removed title bar: drag to move the window,
/// double-click to zoom (maximize into available space). Traffic lights stay
/// clickable because they're window-level buttons layered above this strip.
final class WindowDragStripView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            window?.performZoom(nil)
        }
        // Single press: do nothing here; dragging is handled in mouseDragged
        // so double-clicks aren't swallowed by the drag tracking loop.
    }

    override func mouseDragged(with event: NSEvent) {
        if event.clickCount < 2 {
            window?.performDrag(with: event)
        }
    }
}

struct WindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragStripView { WindowDragStripView() }
    func updateNSView(_ view: WindowDragStripView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject private var browser: BrowserModel

    /// A controller counts as connected if either GameController or the page's
    /// Gamepad API sees one — WebKit and GameController don't always agree.
    private var isControllerConnected: Bool {
        !browser.report.nativeControllerIDs.isEmpty || !browser.report.webControllerIDs.isEmpty
    }

    var body: some View {
        ZStack(alignment: .top) {
            WebView(browser: browser)

            switch browser.loadPhase {
            case .initialLoading:
                BootVideoView(onFinished: browser.bootVideoFinished)
                    .background(Color.black)
                    .ignoresSafeArea()
                    .transition(.opacity)
            case .failed(let failure):
                ConnectionIssueView(
                    failure: failure,
                    onRetry: browser.retryLoading,
                    onQuit: { NSApp.terminate(nil) }
                )
                .transition(.opacity)
            case .ready, .subsequentLoading:
                EmptyView()
            }
        }
        .overlay(alignment: .bottomLeading) { controllerBadge }
        .overlay(alignment: .bottomTrailing) {
            if case .subsequentLoading = browser.loadPhase {
                MinimalLoadingIndicator(label: "Loading")
            }
        }
        .overlay(alignment: .top) { WindowDragStrip().frame(height: 28).frame(maxWidth: .infinity) }
        .overlay(alignment: .topTrailing) { spikePanel }
        .onAppear { browser.pollStreamInfo() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                browser.pollStreamInfo()
            }
        }
    }

    private var controllerBadge: some View {
        Group {
            if !isControllerConnected {
                HStack(spacing: 6) {
                    Image(systemName: "gamecontroller")
                    Text("No controller")
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .padding(12)
                .opacity(0.85)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isControllerConnected)
        .allowsHitTesting(false)
    }

    private var spikePanel: some View {
        Group {
            if browser.showReport {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Diagnostics")
                        .font(.headline)

                    Label(browser.report.gamepadAPI ? "Gamepad API: available" : "Gamepad API: MISSING",
                          systemImage: browser.report.gamepadAPI ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(browser.report.gamepadAPI ? .green : .red)

                    Label(browser.report.webRTC ? "WebRTC: available" : "WebRTC: MISSING",
                          systemImage: browser.report.webRTC ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(browser.report.webRTC ? .green : .red)

                    Label("Native controllers: \(browser.report.nativeControllerIDs.count)",
                          systemImage: "gamecontroller")

                    ForEach(browser.report.nativeControllerIDs, id: \.self) { id in
                        Text("• \(id)").font(.caption).padding(.leading, 8)
                    }

                    ForEach(Array(browser.report.messages.suffix(4).enumerated()), id: \.offset) { _, message in
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(12)
                .frame(width: 290, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                .padding(12)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BrowserModel())
}
