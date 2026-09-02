//
//  ContentView.swift
//  Xbox Cloud Gaming
//
//  Created by Arunya on 02/09/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var browser: BrowserModel

    var body: some View {
        ZStack(alignment: .top) {
            WebView(browser: browser)

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
    }

    private var controllerBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "gamecontroller")
            Text(browser.report.nativeControllerIDs.isEmpty
                 ? "No controller"
                 : "\(browser.report.nativeControllerIDs.count) controller\(browser.report.nativeControllerIDs.count == 1 ? "" : "s")")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .padding(12)
        .opacity(0.85)
        .allowsHitTesting(false)
    }

    private var spikePanel: some View {
        Group {
            if browser.showReport {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Compatibility Spike")
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

                    if browser.report.webControllerIDs.count != browser.report.nativeControllerIDs.count {
                        Text("Web-visible gamepads: \(browser.report.webControllerIDs.count) — bridge needed")
                            .font(.caption)
                            .foregroundStyle(.orange)
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
