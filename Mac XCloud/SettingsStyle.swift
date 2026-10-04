import AppKit
import SwiftUI

// The Settings design layer, modeled on macOS System Settings: a calm page
// background, inset grouped sections on a raised surface, one row rhythm,
// plain-language labels with an optional one-line explanation, and native
// controls (small switches, pop-up menus, sliders with end labels).

enum SettingsMetrics {
    static let pageMaxWidth: CGFloat = 620
    static let controlWidth: CGFloat = 200
    static let sliderWidth: CGFloat = 200
    static let rowMinHeight: CGFloat = 38
    static let groupCorner: CGFloat = 10
}

enum SettingsPalette {
    /// Page background behind the grouped sections.
    static let page = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.118, alpha: 1)
            : NSColor(calibratedRed: 0.949, green: 0.949, blue: 0.957, alpha: 1)
    })
    /// Raised surface of a section.
    static let group = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 1, alpha: 0.055)
            : NSColor.white
    })
    static let groupBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 1, alpha: 0.07)
            : NSColor(calibratedWhite: 0, alpha: 0.06)
    })
    /// Track behind live previews (stick dots, wheel angle).
    static let well = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 1, alpha: 0.07)
            : NSColor(calibratedWhite: 0, alpha: 0.05)
    })
}

/// How far the visible settings page has scrolled; the toolbar shows its
/// hairline only once content passes beneath it, as System Settings does.
struct SettingsScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One scrolling settings page. The page title lives in the window's
/// toolbar (System Settings style); `subtitle` is an optional lead-in.
struct SettingsPage<Content: View>: View {
    private let subtitle: String?
    private let content: Content

    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, -6)
                }
                content
            }
            .font(.system(size: 13))
            .frame(maxWidth: SettingsMetrics.pageMaxWidth, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SettingsScrollOffsetKey.self,
                                       value: -proxy.frame(in: .named("settings-scroll")).minY)
            })
        }
        .coordinateSpace(name: "settings-scroll")
        .background(SettingsPalette.page)
    }
}

/// A quiet notice: something is unavailable, or needs an action first.
struct SettingsWarning: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Explains what is missing and what to do next.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: SettingsSymbol.available(icon))
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }
}

/// A titled section of rows on the raised surface.
struct SettingsGroup<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: SettingsMetrics.groupCorner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.groupCorner, style: .continuous)
                    .strokeBorder(SettingsPalette.groupBorder))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One labeled setting: label (and optional explanation) on the left, its
/// control on the right.
struct SettingsRow<Control: View>: View {
    let label: String
    let note: String?
    private let control: Control

    init(_ label: String, note: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.note = note
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .settingsRow()
    }
}

extension Binding {
    /// Passes a control's change on once SwiftUI has finished the view
    /// update it arrived in. Since macOS 26 SwiftUI draws sliders and
    /// switches itself and can set their value mid-update, and changing an
    /// observed object then is undefined behavior ("Publishing changes from
    /// within view updates is not allowed").
    func deferredWrites() -> Binding {
        Binding(get: { wrappedValue }, set: { newValue in
            DispatchQueue.main.async { wrappedValue = newValue }
        })
    }
}

/// A switch row — the most common setting.
struct SettingsToggleRow: View {
    let label: String
    var note: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(label, note: note) {
            Toggle(label, isOn: $isOn.deferredWrites())
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// Slider with plain-language end labels (and an optional value read-out),
/// so tuning reads as "Slower ··· Faster" rather than raw numbers.
struct SettingsSliderRow: View {
    let label: String
    var note: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var minimumLabel: String? = nil
    var maximumLabel: String? = nil
    var valueText: ((Double) -> String)? = nil
    var step: Double? = nil

    var body: some View {
        SettingsRow(label, note: note) {
            HStack(spacing: 8) {
                if let minimumLabel {
                    Text(minimumLabel).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                }
                slider.frame(width: SettingsMetrics.sliderWidth - (valueText == nil ? 0 : 44))
                if let maximumLabel {
                    Text(maximumLabel).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                }
                if let valueText {
                    Text(valueText(value))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder private var slider: some View {
        if let step {
            Slider(value: $value.deferredWrites(), in: range, step: step).controlSize(.small).accessibilityLabel(label)
                .accessibilityValue(valueText?(value) ?? "")
        } else {
            Slider(value: $value.deferredWrites(), in: range).controlSize(.small).accessibilityLabel(label)
                .accessibilityValue(valueText?(value) ?? "")
        }
    }
}

/// "Advanced" and similar progressive disclosure inside a section; the
/// revealed rows belong to the same section rather than a nested card.
struct SettingsDisclosure<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    private let content: Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .settingsRow()
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                Divider()
                content.transition(.opacity)
            }
        }
    }
}

/// White glyph on a tinted rounded square, as in the System Settings sidebar.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: SettingsSymbol.available(symbol))
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [tint.opacity(0.82), tint], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Tinted glyph used for identity inside rows.
struct SettingsSymbol: View {
    let name: String
    var color: Color = .accentColor

    static func available(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "gearshape" : name
    }

    var body: some View {
        Image(systemName: Self.available(name))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 20)
            .accessibilityHidden(true)
    }
}

/// Live stick preview: a dot inside a circular well.
struct StickPreview: View {
    let value: ControllerVector2
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().fill(SettingsPalette.well)
            Circle().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            Path { path in
                path.move(to: CGPoint(x: size / 2, y: 6)); path.addLine(to: CGPoint(x: size / 2, y: size - 6))
                path.move(to: CGPoint(x: 6, y: size / 2)); path.addLine(to: CGPoint(x: size - 6, y: size / 2))
            }.stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
                .offset(x: CGFloat(min(max(value.x, -1), 1)) * (size / 2 - 7),
                        y: CGFloat(-min(max(value.y, -1), 1)) * (size / 2 - 7))
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stick output")
        .accessibilityValue(String(format: "%.0f percent right, %.0f percent up", value.x * 100, value.y * 100))
    }
}

extension View {
    func settingsRow() -> some View {
        padding(.vertical, 7).frame(minHeight: SettingsMetrics.rowMinHeight)
    }

    func settingsPicker() -> some View {
        labelsHidden().pickerStyle(.menu).fixedSize()
    }
}
