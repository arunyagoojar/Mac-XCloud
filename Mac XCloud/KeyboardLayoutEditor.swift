//
//  KeyboardLayoutEditor.swift
//  Mac XCloud
//
//  The Keyboard & Mouse settings page: native keyboard & mouse for games that
//  support it, and controller layouts (built-in and the player's own) for
//  every other game, edited key by key.
//

import AppKit
import SwiftUI

struct KeyboardMouseSettingsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var store: KeyboardMouseStore
    @State private var confirmingDelete = false

    private var nativeEnabled: Binding<Bool> {
        Binding(get: { (model.globalValue("nativeMkb.mode") as? String) != "off" },
                set: { on in model.write(id: "nativeMkb.mode", scope: .global, value: on ? "default" : "off") })
    }

    var body: some View {
        SettingsPage("Keyboard & Mouse") {
            SettingsGroup("Games with Keyboard & Mouse Support",
                          footer: "Works like Xbox Cloud Gaming in Chrome or Edge: games that support keyboard and mouse get them directly.") {
                SettingsToggleRow(label: "Use keyboard & mouse", isOn: nativeEnabled)
            }
            SettingsGroup("Games Made for Controllers",
                          footer: "Your keyboard and mouse play as an Xbox controller. Keys work as soon as the game starts; click the game to use the mouse, and hold Esc to release it.") {
                SettingsToggleRow(label: "Play with keyboard & mouse", isOn: $store.controllerLayoutEnabled)
                if store.controllerLayoutEnabled {
                    Divider()
                    SettingsRow("Layout") { layoutPicker }
                    Divider()
                    SettingsSliderRow(label: "Mouse sensitivity", value: $store.mouseSensitivity,
                                      range: 0.25...3, minimumLabel: "Slow", maximumLabel: "Fast")
                }
            }
            if store.controllerLayoutEnabled {
                KeyboardLayoutEditor(store: store)
            }
            SettingsGroup("While Playing") {
                SettingsRow("Use the mouse") { Text("Click the game").foregroundStyle(.secondary) }
                Divider()
                SettingsRow("Release the mouse") { Text("Hold Esc").foregroundStyle(.secondary) }
                Divider()
                SettingsRow("Pause", note: "While the mouse is captured. In games with keyboard & mouse support, Esc goes to the game as Esc.") {
                    Text("Tap Esc").foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Delete “\(store.selectedLayout.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Layout", role: .destructive) { store.delete(store.selectedLayoutID) }
        } message: {
            Text("Games switch back to the Standard layout.")
        }
    }

    private var layoutPicker: some View {
        HStack(spacing: 6) {
            Picker("Layout", selection: $store.selectedLayoutID) {
                ForEach(BuiltInKeyboardLayouts.all) { Text($0.name).tag($0.id) }
                if !store.customLayouts.isEmpty {
                    Divider()
                    ForEach(store.customLayouts) { Text($0.name).tag($0.id) }
                }
            }
            .settingsPicker()
            Menu {
                Button("New Layout") { store.createLayout(from: store.selectedLayout) }
                if !store.isBuiltIn(store.selectedLayout) {
                    Button("Duplicate") { store.createLayout(from: store.selectedLayout) }
                    Divider()
                    Button("Delete…") { confirmingDelete = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Create, duplicate or delete layouts")
            .accessibilityLabel("Layout actions")
        }
    }
}

/// Every control of the selected layout with its keys. Built-in layouts are
/// shown read-only with a one-click way to make an editable copy.
private struct KeyboardLayoutEditor: View {
    @ObservedObject var store: KeyboardMouseStore
    @State private var capturing: CaptureSlot?
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var showMore = false

    struct CaptureSlot: Equatable {
        let control: KeyboardControl
        let slot: Int
    }

    private var layout: KeyboardLayout { store.selectedLayout }
    private var editable: Bool { !store.isBuiltIn(layout) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if editable {
                SettingsGroup(footer: notice ?? "Click a key to change it, then press the new key or mouse button. Esc cancels.") {
                    SettingsRow("Name") {
                        TextField("Name", text: Binding(get: { layout.name }, set: { store.rename(layout.id, to: $0) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: SettingsMetrics.controlWidth)
                    }
                    Divider()
                    mouseRows
                }
            } else {
                SettingsGroup {
                    SettingsRow(layout.name, note: "A built-in layout. Make a copy to change its keys.") {
                        Button("Customize…") { store.createLayout(from: layout) }.controlSize(.small)
                    }
                }
            }
            ForEach(primarySections, id: \.self) { section in
                bindingsGroup(section)
            }
            SettingsGroup {
                SettingsDisclosure("More Controls", isExpanded: $showMore) {
                    ForEach(Array(secondarySections.enumerated()), id: \.element) { index, section in
                        if index > 0 { Divider() }
                        Text(section.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8).padding(.bottom, 2)
                        ForEach(Array(controls(in: section).enumerated()), id: \.element) { rowIndex, control in
                            if rowIndex > 0 { Divider() }
                            bindingRow(control)
                        }
                    }
                }
            }
        }
        .onChange(of: layout.id) { _ in capturing = nil }
    }

    private var primarySections: [KeyboardControl.Section] { [.movement, .buttons, .shouldersAndTriggers] }
    private var secondarySections: [KeyboardControl.Section] { [.camera, .dpad, .system] }

    private func controls(in section: KeyboardControl.Section) -> [KeyboardControl] {
        KeyboardControl.allCases.filter { $0.section == section }
    }

    private func bindingsGroup(_ section: KeyboardControl.Section) -> some View {
        SettingsGroup(section.rawValue) {
            ForEach(Array(controls(in: section).enumerated()), id: \.element) { index, control in
                if index > 0 { Divider() }
                bindingRow(control)
            }
        }
    }

    @ViewBuilder private var mouseRows: some View {
        SettingsRow("Mouse moves") {
            Picker("Mouse moves", selection: Binding(get: { layout.mouseLook }, set: { value in
                var copy = layout; copy.mouseLook = value; store.update(copy)
            })) {
                ForEach(MouseLookStick.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .settingsPicker()
        }
        Divider()
        SettingsToggleRow(label: "Invert vertical mouse", isOn: Binding(get: { layout.invertMouseY }, set: { value in
            var copy = layout; copy.invertMouseY = value; store.update(copy)
        }))
    }

    private func bindingRow(_ control: KeyboardControl) -> some View {
        SettingsRow(control.title) {
            HStack(spacing: 6) {
                ForEach(0..<KeyboardLayout.inputsPerControl, id: \.self) { slot in
                    keySlot(control, slot)
                }
            }
        }
    }

    @ViewBuilder private func keySlot(_ control: KeyboardControl, _ slot: Int) -> some View {
        let inputs = layout.inputs(for: control)
        let input = inputs.indices.contains(slot) ? inputs[slot] : nil
        // An empty second slot only appears once the first is used.
        if input != nil || slot <= inputs.count {
            KeyCap(input: input,
                   capturing: capturing == CaptureSlot(control: control, slot: slot),
                   editable: editable,
                   onBegin: { capturing = CaptureSlot(control: control, slot: slot) },
                   onCapture: { bind($0, to: control, slot: slot) },
                   onCancel: { if capturing == CaptureSlot(control: control, slot: slot) { capturing = nil } },
                   onClear: {
                       var copy = layout; copy.unbind(control, slot: slot); store.update(copy)
                   })
        } else {
            Color.clear.frame(width: KeyCap.width, height: KeyCap.height)
        }
    }

    private func bind(_ input: String, to control: KeyboardControl, slot: Int) {
        var copy = layout
        let movedFrom = copy.bind(input, to: control, slot: slot)
        store.update(copy)
        capturing = nil
        if let movedFrom {
            show("\(KeyboardInputName.displayName(input)) moved here from \(movedFrom.title).")
        }
    }

    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { notice = nil }
        }
    }
}

/// One key binding, drawn as a key cap. Clicking an editable cap listens for
/// the next key, mouse button or scroll; Escape or clicking away cancels.
private struct KeyCap: View {
    static let width: CGFloat = 104
    static let height: CGFloat = 24

    let input: String?
    let capturing: Bool
    let editable: Bool
    let onBegin: () -> Void
    let onCapture: (String) -> Void
    let onCancel: () -> Void
    let onClear: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(input == nil && !capturing ? Color.clear : SettingsPalette.well)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(capturing ? Color.accentColor : Color.secondary.opacity(input == nil ? 0.35 : 0.22),
                              style: StrokeStyle(lineWidth: capturing ? 1.5 : 1, dash: input == nil && !capturing ? [3, 2] : []))
            Text(label)
                .font(.system(size: 11.5, weight: input == nil || capturing ? .regular : .medium))
                .foregroundStyle(capturing || input == nil ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 6)
            if editable {
                KeyCaptureRepresentable(capturing: capturing, onBegin: onBegin, onCapture: onCapture, onCancel: onCancel)
            }
            if editable, hovering, input != nil, !capturing {
                HStack {
                    Spacer()
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    .help("Remove this key")
                    .accessibilityLabel("Remove \(label)")
                }
            }
        }
        .frame(width: Self.width, height: Self.height)
        .onHover { hovering = $0 }
        .contextMenu {
            if editable, input != nil { Button("Remove", action: onClear) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(input == nil ? "Not set" : label)
        .accessibilityHint(editable ? "Click, then press a key to change" : "")
    }

    private var label: String {
        if capturing { return "Press a key…" }
        if let input { return KeyboardInputName.displayName(input) }
        return editable ? "Add" : "—"
    }
}

/// Transparent AppKit layer over a key cap that takes key and mouse events
/// while capturing.
private struct KeyCaptureRepresentable: NSViewRepresentable {
    let capturing: Bool
    let onBegin: () -> Void
    let onCapture: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureView { KeyCaptureView() }

    func updateNSView(_ view: KeyCaptureView, context: Context) {
        view.onBegin = onBegin
        view.onCapture = onCapture
        view.onCancel = onCancel
        if view.isCapturing != capturing {
            view.isCapturing = capturing
            if capturing, view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        }
    }
}

final class KeyCaptureView: NSView {
    var isCapturing = false
    var onBegin: (() -> Void)?
    var onCapture: ((String) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isCapturing {
            capture("Mouse0")
        } else {
            window?.makeFirstResponder(self)
            onBegin?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isCapturing else { return super.rightMouseDown(with: event) }
        capture("Mouse2")
    }

    override func otherMouseDown(with event: NSEvent) {
        guard isCapturing else { return super.otherMouseDown(with: event) }
        // Button 2 is the wheel; 3 and 4 are the side buttons (back, forward).
        switch event.buttonNumber {
        case 3: capture("Mouse3")
        case 4: capture("Mouse4")
        default: capture("Mouse1")
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard isCapturing, abs(event.scrollingDeltaY) >= 1 else { return super.scrollWheel(with: event) }
        capture(event.scrollingDeltaY > 0 ? "ScrollUp" : "ScrollDown")
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else { return super.keyDown(with: event) }
        if event.keyCode == 0x35 { finishCancelled(); return }
        guard !event.isARepeat else { return }
        if event.modifierFlags.contains(.command) { NSSound.beep(); return }
        if let code = KeyboardInputName.code(forKeyCode: event.keyCode) { capture(code) } else { NSSound.beep() }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isCapturing else { return super.flagsChanged(with: event) }
        // Shift, Control and Option bind on their own, on press.
        let flags: [UInt16: NSEvent.ModifierFlags] = [0x38: .shift, 0x3C: .shift, 0x3B: .control,
                                                      0x3E: .control, 0x3A: .option, 0x3D: .option]
        if let flag = flags[event.keyCode], event.modifierFlags.contains(flag),
           let code = KeyboardInputName.code(forKeyCode: event.keyCode) {
            capture(code)
        }
    }

    override func resignFirstResponder() -> Bool {
        if isCapturing { isCapturing = false; onCancel?() }
        return super.resignFirstResponder()
    }

    private func capture(_ code: String) {
        isCapturing = false
        onCapture?(code)
        window?.makeFirstResponder(nil)
    }

    private func finishCancelled() {
        isCapturing = false
        onCancel?()
        window?.makeFirstResponder(nil)
    }
}
