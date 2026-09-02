//
//  ContentView.swift
//  Xbox Cloud Gaming
//
//  Created by Arunya on 02/09/26.
//

import SwiftUI

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
                .overlay(alignment: .top) { titleBarHider.allowsHitTesting(false) }

            if browser.isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(.thinMaterial)
            }
        }
        .overlay(alignment: .bottomLeading) { controllerBadge }
        .overlay(alignment: .topTrailing) { spikePanel }
        .onAppear { styleMainWindow() }
    }

    /// Removes the visible title bar: traffic lights float over the content,
    /// no title text, no gray bar.
    private func styleMainWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            for window in NSApp.windows where window.title == "Xbox Cloud Gaming" {
                window.styleMask.insert(.fullSizeContentView)
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
            }
        }
    }

    private var titleBarHider: some View {
        // Invisible strip so the (transparent) titlebar area stays draggable.
        Color.clear
            .frame(height: 28)
            .frame(maxWidth: .infinity)
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
