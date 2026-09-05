import AppKit
import SwiftUI

/// Shared compact layout for Settings and its single-section controller pages.
struct SettingsPage<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .font(.system(size: 13))
                .frame(maxWidth: 600, alignment: .leading)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

struct SettingsGroup<Content: View>: View {
    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1))
        }
    }
}

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
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Controls supply their own accessible labels; Text values retain
            // their content rather than being renamed to the row label.
            control
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .settingsRow()
    }
}

struct SettingsSymbol: View {
    let name: String
    var color: Color = .accentColor

    static func available(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "gearshape" : name
    }

    var body: some View {
        Image(systemName: Self.available(name))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension View {
    func settingsRow() -> some View {
        padding(.vertical, 5).frame(minHeight: 40)
    }

    func settingsPicker() -> some View {
        labelsHidden().frame(width: 168, alignment: .trailing)
    }
}
