//
//  SettingsWindow.swift
//  Xbox Cloud Gaming
//
//  The native macOS settings window: categories on the left, settings on the
//  right, frosted-transparent background. Mouse/keyboard first; controller
//  navigation layered on top.
//

import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject private var browser: BrowserModel
    @ObservedObject var model: SettingsModel

    var body: some View {
        content(model)
            .onAppear {
                browser.isSettingsWindowOpen = true
                model.load()
                bindController()
            }
            .onDisappear {
                browser.isSettingsWindowOpen = false
                unbindController()
            }
            .frame(minWidth: 760, minHeight: 540)
            .background(.ultraThinMaterial)
    }

    private func content(_ model: SettingsModel) -> some View {
        NavigationSplitView {
            sidebar(model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            detail(model)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
    }

    // MARK: - Sidebar

    private func sidebar(_ model: SettingsModel) -> some View {
        List(selection: Binding(
            get: { model.selectedCategoryId },
            set: { id in
                if let id { model.selectCategory(id) }
            }
        )) {
            ForEach(SettingsCategory.all) { category in
                Label(category.title, systemImage: category.icon)
                    .tag(category.id)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Better xCloud engine v6.7.12")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("MIT License · redphx/better-xcloud")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    // MARK: - Detail

    private func detail(_ model: SettingsModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !model.bridgeAvailable {
                    warningBox("Open xbox.com/play at least once, then reopen this window to load your cloud settings.")
                }

                suggestedButton

                let rows = model.rows
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, def in
                    settingRow(model, def: def, index: index)
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }

                Text("Stream & region settings apply when you start your next game. Overlay and video settings apply live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
                    .padding(.horizontal, 16)

                if let message = model.saveMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.top, 4)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .sheet(isPresented: Binding(get: { model.showForcedMKBPicker }, set: { model.showForcedMKBPicker = $0 })) {
            ForcedMKBPicker(model: model)
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
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func warningBox(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4)))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func settingRow(_ model: SettingsModel, def: SettingDef, index: Int) -> some View {
        let isFocused = model.pane == .rows && model.rowFocus == index

        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(def.label)
                    .font(.system(size: 13, weight: isFocused ? .semibold : .regular))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = def.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            control(model, def: def)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? Color.accentColor.opacity(0.14) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5)
                .padding(.horizontal, 4)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                model.pane = .rows
                model.rowFocus = index
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private func control(_ model: SettingsModel, def: SettingDef) -> some View {
        switch def.kind {
        case .toggle:
            Toggle("", isOn: Binding(
                get: { model.isOn(def) },
                set: { _ in model.toggle(def) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

        case .option(let values, let labels, _):
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
            HStack(spacing: 10) {
                if let value = model.rangeValue(def) {
                    Text(format(value))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(minWidth: 64, alignment: .trailing)
                        .lineLimit(1)
                }
                Slider(
                    value: Binding(
                        get: { model.rangeValue(def) ?? min },
                        set: { model.setRange(def, value: $0) }
                    ),
                    in: min...max,
                    step: step
                )
                .frame(width: 170)
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
            .fixedSize()

        case .ledColor:
            ledControl(model)

        case .profileLauncher(let kind):
            ProfileLaunchButton(kind: kind,
                                title: kind.title,
                                note: "Opens the native \(kind.title.lowercased()) manager")

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

        case .pingTest:
            PingTestControl(model: model)

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
                        if model.optionIndex(def) == index {
                            Image(systemName: "checkmark")
                        }
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
        .fixedSize()
    }

    private func pickerLabel(_ model: SettingsModel, def: SettingDef, index: Int) -> String {
        model.optionLabel(def, index: index)
    }

    private func multiSummary(_ model: SettingsModel, def: SettingDef) -> String {
        let selection = model.multiSelection(def)
        if selection.isEmpty { return "None" }
        if let options = def.multiOptions() {
            let labels = options.filter { selection.contains($0.value) }.map(\.label)
            return labels.joined(separator: ", ")
        }
        return "\(selection.count) selected"
    }

    private func ledControl(_ model: SettingsModel) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(LEDColor.all.enumerated()), id: \.offset) { index, color in
                Circle()
                    .fill(Color(red: color.red, green: color.green, blue: color.blue))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Circle().strokeBorder(
                            model.ledColorIndex == index ? Color.primary : Color.primary.opacity(0.25),
                            lineWidth: model.ledColorIndex == index ? 2 : 1
                        )
                        .padding(-3)
                    )
                    .onTapGesture {
                        model.ledColorIndex = index
                    }
                    .help(color.label)
            }

            ColorPicker("", selection: Binding(
                get: { model.customLEDColor },
                set: { model.customLEDColor = $0 }
            ), supportsOpacity: false)
            .labelsHidden()
            .fixedSize()
            .help("Custom color")
        }
    }

    // MARK: - Controller wiring

    private func bindController() {
        browser.controllerInput.onNavigate = { model.moveFocus($0) }
        browser.controllerInput.onAdjust = { model.adjustFocused($0) }
        browser.controllerInput.onActivate = { model.activateFocused() }
        browser.controllerInput.onCancel = { model.closeWindow() }
        browser.controllerInput.onSwitchCategory = { delta in
            let count = SettingsCategory.all.count
            let currentIndex = SettingsCategory.all.firstIndex { $0.id == model.selectedCategoryId } ?? 0
            let newIndex = ((currentIndex + delta) % count + count) % count
            model.selectCategory(SettingsCategory.all[newIndex].id)
        }
    }

    private func unbindController() {
        browser.controllerInput.onNavigate = nil
        browser.controllerInput.onAdjust = nil
        browser.controllerInput.onActivate = nil
        browser.controllerInput.onCancel = nil
        browser.controllerInput.onSwitchCategory = nil
    }
}

extension SettingDef {
    func multiOptions() -> [(value: String, label: String)]? {
        if case .multi(let options) = kind { return options }
        return nil
    }
}
