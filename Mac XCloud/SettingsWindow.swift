//
//  SettingsWindow.swift
//  Mac XCloud
//
//  Same-window settings home and detail routes with mouse/keyboard navigation.
//  SettingsModel continues to own Better xCloud values and readback.
//

import AppKit
import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject private var browser: BrowserModel
    @ObservedObject var model: SettingsModel
    @State private var supportFailure: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 208)
            Divider()
            VStack(spacing: 0) {
                settingsHeader
                Divider()
                routeContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .onAppear {
                browser.isSettingsWindowOpen = true
                model.load()
            }
            .onDisappear {
                browser.isSettingsWindowOpen = false
            }
            .frame(minWidth: 800, minHeight: 620)
            .alert("Could Not Open Ko-fi", isPresented: Binding(
                get: { supportFailure != nil },
                set: { if !$0 { supportFailure = nil } }
            )) {
                Button("OK", role: .cancel) { supportFailure = nil }
            } message: {
                Text(supportFailure ?? "")
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .sheet(isPresented: Binding(get: { model.showForcedMKBPicker }, set: { model.showForcedMKBPicker = $0 })) {
                ForcedMKBPicker(model: model)
            }
    }

    @ViewBuilder
    private var routeContent: some View {
        switch model.route {
        case .home:
            settingsHome
        case .category:
            settingsDetail(model)
        case .controllerSection(let section):
            ControllerToolsView(service: browser.controllerFeatures, section: section)
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
            Button(action: model.navigateBack) {
                Image(systemName: "chevron.left")
            }
            .help("Back")
            .accessibilityLabel("Back")
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!model.canGoBackInSettings && model.route == .home)

            Button(action: model.navigateForward) {
                Image(systemName: "chevron.right")
            }
            .help("Forward")
            .accessibilityLabel("Forward")
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!model.canGoForwardInSettings)

            Button(action: model.navigateHome) {
                Image(systemName: "house")
            }
            .help("Settings Home")
            .accessibilityLabel("Settings Home")
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(model.route == .home)
        }

            Text(routeTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.needsReload {
                Button {
                    browser.reload()
                    model.needsReload = false
                    browser.closeSettingsWindow()
                } label: {
                    Label("Reload to Apply", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Color(nsColor: .windowBackgroundColor))
        .zIndex(1)
    }

    private var routeTitle: String {
        switch model.route {
        case .home:
            return "Settings"
        case .category(let id):
            return SettingsCategory.all.first(where: { $0.id == id })?.title ?? "Settings"
        case .controllerSection(let section):
            return section.rawValue
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appName).font(.system(size: 13, weight: .semibold))
                    Text(versionLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 6)

            Button(action: openSupportPage) {
                Label("Buy me a coffee?", systemImage: SettingsSymbol.available("cup.and.saucer.fill"))
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
            .help("Support the developer on Ko-fi (opens in your browser)")
            .accessibilityLabel("Buy me a coffee? Open Ko-fi in browser")

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        sidebarRow("About", symbol: "info.circle", color: .gray, route: .home)
                        ForEach(Array(SettingsCategory.all.enumerated()), id: \.element.id) { index, category in
                            if index == 0 || category.id == "mkb" || category.id == "site" {
                                Spacer().frame(height: 8)
                            }
                            sidebarRow(category.title, symbol: category.icon, color: categoryColor(category.id),
                                       route: .category(category.id))
                        }
                        Spacer().frame(height: 8)
                        ForEach(ControllerToolSection.allCases) { section in
                            sidebarRow(section.rawValue, symbol: section.icon, color: .purple,
                                       route: .controllerSection(section))
                        }
                    }
                    .padding(.bottom, 4)
                }
                .onChange(of: model.route) { route in
                    proxy.scrollTo(route == .home ? "About" : routeTitle)
                }
            }
        }
        .padding(10)
        .background(.regularMaterial)
    }

    private func sidebarRow(_ title: String, symbol: String, color: Color,
                            route: SettingsRoute) -> some View {
        let selected = model.route == route
        return Button { model.navigate(to: route) } label: {
            HStack(spacing: 8) {
                SettingsSymbol(name: symbol, color: color)
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(title)
        .id(title)
    }

    private func categoryColor(_ id: String) -> Color {
        switch id {
        case "server", "stream", "remote": return .blue
        case "stats": return .green
        case "clarity", "video": return .indigo
        case "mkb": return .orange
        default: return .gray
        }
    }

    private var settingsHome: some View {
        SettingsPage {
            SettingsGroup("About \(appName)") {
                Text("A native macOS home for Xbox Cloud Gaming, powered by Better xCloud.")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                SettingsRow("Version") { Text(versionLabel).foregroundStyle(.secondary) }
                Divider()
                SettingsRow("Engine") { Text("Better xCloud v6.7.12").foregroundStyle(.secondary) }
                Divider()
                SettingsRow("License") { Text("MIT · redphx/better-xcloud").foregroundStyle(.secondary) }
            }
            SettingsGroup("Settings Summary") {
                SettingsRow("Cloud preferences", note: "Choose a category in the sidebar to configure streaming, video, and input.") {
                    Text(model.bridgeAvailable ? "Ready" : "Not loaded").foregroundStyle(.secondary)
                }
                Divider()
                SettingsRow("Controller tools", note: "Test, calibrate, and customize your controller in this window.") {
                    Text("7 sections").foregroundStyle(.secondary)
                }
            }
            suggestedButton
            if let message = model.saveMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Stream and region changes apply to your next game. Overlay and video changes apply live. Use Back, Forward, or Home to revisit pages.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Mac Xcloud"
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) (Build \(build))"
    }

    private func openSupportPage() {
        supportFailure = nil
        guard let url = URL(string: "https://ko-fi.com/arunyagoojar"),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "ko-fi.com" else {
            supportFailure = "The support link is invalid."
            return
        }
        guard NSWorkspace.shared.open(url) else {
            supportFailure = "Could not open ko-fi.com in your browser."
            return
        }
    }

    private func categorySubtitle(_ category: SettingsCategory) -> String {
        switch category.id {
        case "server": return "Regions, latency, and language"
        case "stream": return "Resolution, bitrate, and stream audio"
        case "stats": return "Performance overlay and game bar"
        case "clarity": return "Upscaling and sharpening pipeline"
        case "video": return "Rendering, color, aspect, and audio"
        case "remote": return "Streaming from your own Xbox"
        case "mkb": return "Mouse, keyboard, and profiles"
        case "site": return "Xbox site appearance and behavior"
        case "advanced": return "Privacy, layout, and hidden sections"
        case "controller": return "LED, polling rate, and local co-op"
        default: return "\(category.rows.count) preferences"
        }
    }

    private func settingsDetail(_ model: SettingsModel) -> some View {
        SettingsPage {
            Text(categorySubtitle(model.selectedCategory))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.bridgeAvailable {
                warningBox("Open xbox.com/play at least once, then reopen this window to load your cloud settings.")
            }
            SettingsGroup(model.selectedCategory.title) {
                let rows = model.rows
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, def in
                    settingRow(model, def: def)
                    if index < rows.count - 1 { Divider() }
                }
            }
            Text("Stream & region settings apply when you start your next game. Overlay and video settings apply live.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.saveMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var suggestedButton: some View {
        Button {
            model.applySuggested()
        } label: {
            Label("Apply suggested settings for this Mac", systemImage: "wand.and.stars")
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.bordered)
    }

    private func warningBox(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4)))
    }

    private func settingRow(_ model: SettingsModel, def: SettingDef) -> some View {
        SettingsRow(def.label, note: def.note) {
            control(model, def: def)
                .frame(width: 168, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func control(_ model: SettingsModel, def: SettingDef) -> some View {
        switch def.kind {
        case .toggle:
            Toggle(def.label, isOn: Binding(
                get: { model.isOn(def) },
                set: { desired in model.setToggle(def, desired: desired) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

        case .option(let values, _, _):
            optionMenu(model: model, def: def, count: values.count) { index in
                Text(pickerLabel(model, def: def, index: index))
            } select: { index in
                model.setOption(def, index: index)
            }

        case .numberOption(let values, let labels, _):
            optionMenu(model: model, def: def, count: values.count) { index in
                Text(labels.indices.contains(index) ? labels[index] : "?")
            } select: { index in
                model.setOption(def, index: index)
            }

        case .serverRegion:
            optionMenu(model: model, def: def, count: model.regions.count) { index in
                Text(model.regions.indices.contains(index) ? model.regions[index].label : "?")
            } select: { index in
                model.setOption(def, index: index)
            }

        case .range(let min, let max, let step, _, let format):
            VStack(alignment: .trailing, spacing: 3) {
                Slider(value: Binding(
                    get: { model.rangeValue(def) ?? min },
                    set: { model.setRange(def, value: $0) }
                ), in: min...max, step: step)
                .accessibilityLabel(def.label)
                .accessibilityValue(model.rangeValue(def).map(format) ?? "—")
                Text(model.rangeValue(def).map(format) ?? "—")
                    .font(.system(size: 12).monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .multi(let options):
            Menu {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button {
                        model.toggleMulti(def, value: option.value)
                    } label: {
                        if model.multiSelection(def).contains(option.value) {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                Text(multiSummary(model, def: def))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(def.label)
            .accessibilityValue(multiSummary(model, def: def))

        case .ledColor:
            ledControl(model)

        case .profileLauncher(let kind):
            Button("Open…") { browser.openProfileEditor(kind) }
                .buttonStyle(.bordered)
                .help("Opens the native \(kind.title.lowercased()) manager")
                .accessibilityLabel("Open \(kind.title)")

        case .forcedMKBGames:
            Button {
                model.showForcedMKBPicker = true
            } label: {
                HStack(spacing: 6) {
                    Text("\(model.forcedNativeMKBGames.count) selected")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(def.label)
            .accessibilityValue("\(model.forcedNativeMKBGames.count) selected")

        case .pingTest:
            VStack(alignment: .trailing, spacing: 6) {
                if model.isPingingRegions {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Testing…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let best = model.bestRegionResult {
                    Text("\(best.name) · \(best.averageMs) ms")
                        .font(.system(size: 12, weight: .medium))
                    Text("best of \(best.samples) samples")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if model.bestRegionResult != nil, !model.isPingingRegions {
                        Button("Use Best") { model.useBestRegion() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(model.isPingingRegions ? "Stop" : "Test") {
                        model.isPingingRegions ? model.stopRegionPing() : model.testRegions()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(model.isPingingRegions ? "Stop region latency test" : "Test region latency")
                }
            }

        case .info(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func optionMenu(model: SettingsModel, def: SettingDef, count: Int,
                            @ViewBuilder label: @escaping (Int) -> some View,
                            select: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(0..<count, id: \.self) { index in
                Button {
                    select(index)
                } label: {
                    HStack {
                        label(index)
                        Spacer()
                        if model.optionIndex(def) == index { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let index = model.optionIndex(def) {
                    label(index)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Text(model.defaultValueLabel(def))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel(def.label)
        .accessibilityValue(model.optionIndex(def).map { pickerLabel(model, def: def, index: $0) }
                            ?? model.defaultValueLabel(def))
    }

    private func pickerLabel(_ model: SettingsModel, def: SettingDef, index: Int) -> String {
        model.optionLabel(def, index: index)
    }

    private func multiSummary(_ model: SettingsModel, def: SettingDef) -> String {
        let selection = model.multiSelection(def)
        if selection.isEmpty { return "None" }
        if let options = def.multiOptions() {
            return options.filter { selection.contains($0.value) }.map(\.label).joined(separator: ", ")
        }
        return "\(selection.count) selected"
    }

    private func ledControl(_ model: SettingsModel) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Array(LEDColor.all.enumerated()), id: \.offset) { index, color in
                    Button {
                        model.ledColorIndex = index
                    } label: {
                        if model.ledColorIndex == index {
                            Label(color.label, systemImage: "checkmark")
                        } else {
                            Text(color.label)
                        }
                    }
                }
            } label: {
                Text(LEDColor.all.indices.contains(model.ledColorIndex) ? LEDColor.all[model.ledColorIndex].label : "LED")
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            ColorPicker("Custom LED color", selection: Binding(
                get: { model.customLEDColor },
                set: { model.customLEDColor = $0 }
            ), supportsOpacity: false)
            .labelsHidden()
            .fixedSize()
            .help("Custom color")
        }
    }

}

extension SettingDef {
    func multiOptions() -> [(value: String, label: String)]? {
        if case .multi(let options) = kind { return options }
        return nil
    }
}
