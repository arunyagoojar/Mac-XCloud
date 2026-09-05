import SwiftUI

/// Compact visual preview of how a trigger effect responds across its travel.
struct TriggerEffectCurve: View {
    let parameters: AdaptiveTriggerCustomParameters

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                let levels = parameters.travelLevels
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    Path { path in
                        for index in 0..<levels.count {
                            let x = width * CGFloat(index) / CGFloat(levels.count - 1)
                            let y = height * (1 - CGFloat(levels[index]))
                            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if parameters.mode.hasEndPosition {
                        Path { path in
                            let x = width * CGFloat(parameters.endPosition)
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: height))
                        }
                        .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3]))
                    }
                }
            }
            .frame(height: 56)
            HStack {
                Text("Released").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Fully pressed").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trigger resistance preview")
        .accessibilityValue(effectSummary)
    }

    private var effectSummary: String {
        let levels = parameters.travelLevels
        return "\(parameters.mode.displayName), starting at \(Int(parameters.startPosition * 100)) percent of travel, peak force \(Int((levels.max() ?? 0) * 100)) percent."
    }
}
