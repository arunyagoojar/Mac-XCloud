import SwiftUI
import AppKit

/// Composited by AppKit over the WebKit video; no web-rendered stats UI or CSS blur.
struct NativeStreamHUD: View {
    @ObservedObject var browser: BrowserModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                ForEach(browser.nativeHUDItems, id: \.self) { key in
                    HStack(spacing: 3) {
                        Text(key.uppercased()).foregroundStyle(.secondary)
                        Text(value(for: key)).monospacedDigit().foregroundColor(color(for: key))
                    }
                }
                if context.date.timeIntervalSince(browser.telemetryUpdatedAt) > 4 {
                    Text("Updating…").foregroundStyle(.orange)
                }
            }
            .font(.system(size: browser.nativeHUDTextSize, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(NativeHUDBlur().overlay(Color.black.opacity(browser.nativeHUDBackground * 0.3)))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
            .opacity(browser.nativeHUDOpacity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Stream statistics")
            .allowsHitTesting(false)
        }
    }
    private func color(for key: String) -> Color {
        guard browser.nativeHUDColors else { return .primary }
        switch key {
        case "ping": return browser.telemetry.pingMs >= 100 ? .red : browser.telemetry.pingMs >= 75 ? .orange : .primary
        case "dt": return browser.telemetry.decodeTimeMs >= 12 ? .red : .primary
        case "pl": return browser.telemetry.packetLossPercent > 1 ? .red : .primary
        default: return .primary
        }
    }
    private func value(for key: String) -> String {
        if key == "batt", let level = browser.controllerInput.batteryPercent { return "\(level)%" }
        return browser.nativeHUDValues[key]?.trimmingCharacters(in: .whitespaces) ?? "—"
    }
}
private struct NativeHUDBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
