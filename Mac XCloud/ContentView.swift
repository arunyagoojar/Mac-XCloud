//
//  ContentView.swift
//  Mac XCloud
//
//  Created by Arunya on 02/09/26.
//

import AppKit
import SwiftUI

/// Captures the SwiftUI WindowGroup window that hosts this view so it can be
/// closed by direct reference — never by guessing from title or size, which
/// could close an unrelated window.
private final class LauncherWindowBinderView: NSView {
    var onBind: ((NSWindow) -> Void)?
    private weak var lastWindow: NSWindow?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== lastWindow else { return }
        lastWindow = window
        onBind?(window)
    }
}

private struct LauncherWindowBinder: NSViewRepresentable {
    var onBind: (NSWindow) -> Void
    func makeNSView(context: Context) -> LauncherWindowBinderView {
        let view = LauncherWindowBinderView()
        view.onBind = onBind
        return view
    }
    func updateNSView(_ view: LauncherWindowBinderView, context: Context) {
        view.onBind = onBind
    }
}

/// Invisible bootstrap view: SwiftUI's WindowGroup window keeps a titlebar
/// strip no matter what, so it immediately hands off to our own AppKit main
/// window (created chrome-less) and closes itself.
struct MainWindowLauncher: View {
    @EnvironmentObject private var browser: BrowserModel
    @State private var launcherWindow: NSWindow?

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .background(LauncherWindowBinder { window in
                launcherWindow = window
            })
            .onAppear {
                browser.openMainWindow()
                // Give the AppKit window a moment to take key status before
                // closing the launcher.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [launcherWindow] in
                    launcherWindow?.close()
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
                ZStack {
                    BootVideoView(onEnded: browser.bootVideoFinished)
                        .background(Color.black)
                        .ignoresSafeArea()
                    // Once the animation has played out, the splash holds on
                    // black with a spinner until the page behind is actually
                    // ready — no frozen video frame on a slow connection.
                    if browser.hasFinishedBootVideo {
                        VStack(spacing: 14) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Loading…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity.animation(.easeIn(duration: 0.3)))
                    }
                }
                .animation(.easeIn(duration: 0.3), value: browser.hasFinishedBootVideo)
                .background(Color.black)
                .ignoresSafeArea()
                // Fade out with a subtle push-through zoom as the live
                // web page (already loaded underneath) is revealed.
                .transition(.opacity.combined(with: .scale(scale: 1.04)))
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
        .overlay(alignment: hudAlignment) {
            if browser.isStreaming && (browser.nativeHUDVisible || (browser.nativeHUDQuickGlance && browser.nativeHUDGlancing)) {
                NativeStreamHUD(browser: browser).padding(3)
            }
        }
        .overlay(alignment: .topTrailing) { spikePanel }
        .onAppear { browser.pollStreamInfo() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                browser.pollStreamInfo()
            }
        }
    }

    private var hudAlignment: Alignment {
        switch browser.nativeHUDPosition {
        case "top-left": return .topLeading
        case "bottom-left": return .bottomLeading
        case "bottom-right": return .bottomTrailing
        case "top-center": return .top
        case "bottom-center": return .bottom
        default: return .topTrailing
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

                    // Show the running title's ID so it can be pasted into a
                    // macxcloud://play/<id> deep link.
                    if browser.isStreaming, !browser.currentGameID.isEmpty {
                        HStack(spacing: 6) {
                            Text("Game: \(browser.currentGameTitle.isEmpty ? browser.currentGameID : browser.currentGameTitle)")
                                .font(.caption).lineLimit(1)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(browser.currentGameID, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc").font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Copy game ID for a macxcloud://play/\(browser.currentGameID) link")
                        }
                    }

                    Label(browser.remotePlayActive ? "Remote Play: active" : "Remote Play: inactive",
                          systemImage: browser.remotePlayActive ? "checkmark.circle" : "minus.circle")
                    Text("Remote server: \(browser.remoteServerStatus)").font(.caption)
                    Text("Remote console: \(browser.remoteConsoleStatus)").font(.caption)
                    if browser.controllerMismatch {
                        Label("Controller mismatch: native connected, browser unavailable", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Rescan Controller") { browser.retryControllerDiscovery() }
                            .buttonStyle(.bordered)
                    }

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
