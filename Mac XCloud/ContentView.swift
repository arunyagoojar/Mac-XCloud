//
//  ContentView.swift
//  Mac XCloud
//
//  Created by Arunya on 02/09/26.
//

import AppKit
import SwiftUI

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
        // The drag strip replaces the hidden title bar; in full screen there
        // is nothing to drag and it would only swallow clicks on the game.
        .overlay(alignment: .top) {
            if !browser.isFullscreen { WindowDragStrip().frame(height: 28).frame(maxWidth: .infinity) }
        }
        .overlay(alignment: .top) {
            if let offer = browser.setupOffer {
                GameSetupBanner(offer: offer,
                                onSetUp: browser.acceptSetupOffer,
                                onNotNow: { browser.dismissSetupOffer(forever: false) },
                                onNever: { browser.dismissSetupOffer(forever: true) })
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                PlayHint(hint: browser.transientHint ?? stateHint)
            }
        }
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

    /// One short hint at a time about keyboard & mouse play.
    private var stateHint: GameHint? {
        guard browser.isStreaming || browser.pointerCaptured else { return nil }
        switch browser.keyboardEmulationState {
        case "keyboard":
            let usesMouse = browser.keyboardMouse.selectedLayout.mouseLook != .off
            return GameHint(key: "kbm-keyboard", text: usesMouse ? "Keyboard & mouse · Click the game to use the mouse" : "Keyboard",
                            symbol: "keyboard")
        case "mouse": return GameHint(key: "kbm-mouse", text: "Keyboard & mouse · Hold Esc to release the mouse", symbol: "computermouse")
        case "native": return GameHint(key: "kbm-native", text: "Keyboard & mouse · The game's own controls", symbol: "keyboard")
        case "controller": return GameHint(key: "kbm-controller", text: "Controller", symbol: "gamecontroller")
        default: return browser.pointerCaptured ? GameHint(key: "pointer", text: "Hold Esc to release the mouse", symbol: nil) : nil
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
            if !isControllerConnected && !browser.isStreaming {
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

/// One notice for the top of the game window. `key` identifies it, so the
/// same notice is not replayed by every view update.
struct GameHint: Equatable {
    let key: String
    let text: String
    var symbol: String? = nil
}

/// A brief notice at the top of the game (like Chrome's "Press and hold Esc
/// to exit"). Each new notice shows for a few seconds, then fades.
private struct PlayHint: View {
    let hint: GameHint?
    @State private var shown: GameHint?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let shown {
                HStack(spacing: 7) {
                    if let symbol = shown.symbol {
                        Image(systemName: SettingsSymbol.available(symbol)).font(.system(size: 12, weight: .semibold))
                    }
                    Text(shown.text)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
                .padding(.top, 36)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: shown)
        .onChange(of: hint) { next in
            hideTask?.cancel()
            shown = next
            guard next != nil else { return }
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if !Task.isCancelled { shown = nil }
            }
        }
    }
}
