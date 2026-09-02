//
//  SettingsWindow.swift
//  Xbox Cloud Gaming
//
//  The native macOS settings window: categories on the left, settings on the
//  right, frosted-transparent background, fully controller-navigable.
//

import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject private var browser: BrowserModel
    @State private var model: SettingsModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                EmptyView()
            }
        }
        .onAppear {
            if model == nil {
                let newModel = SettingsModel(browser: browser)
                model = newModel
                browser.settingsModel = newModel
                browser.isSettingsWindowOpen = true
                newModel.load()
                bindController()
            }
        }
        .onDisappear {
            browser.isSettingsWindowOpen = false
            unbindController()
        }
        .frame(minWidth: 740, minHeight: 520)
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
            }
            .padding(.vertical, 12)
        }
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
        .onTapGesture {
            model.pane = .rows
            model.rowFocus = index
            if case .toggle = def.kind { model.toggle(def) }
        }
    }

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

        case .option, .steps, .serverRegion:
            HStack(spacing: 8) {
                if let index = model.optionIndex(def) {
                    Text(model.optionLabel(def, index: index))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                } else {
                    Text(model.defaultValueLabel(def))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.left.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }

        case .ledColor:
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
            }
        }
    }

    // MARK: - Controller wiring

    private func bindController() {
        browser.controllerInput.onNavigate = { model?.moveFocus($0) }
        browser.controllerInput.onAdjust = { model?.adjustFocused($0) }
        browser.controllerInput.onActivate = { model?.activateFocused() }
        browser.controllerInput.onCancel = { model?.closeWindow() }
        browser.controllerInput.onSwitchCategory = { delta in
            guard let model else { return }
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
