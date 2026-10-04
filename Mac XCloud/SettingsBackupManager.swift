//
//  SettingsBackupManager.swift
//  Mac XCloud
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Exports every app setting to a single JSON file and restores it later.
/// Covers: Better xCloud global/stream mirrors, controller settings, LED
/// state, clarity pipeline, rumble/calibration flags, preset activation keys,
/// and all profile files (with checksum validation on import). Xbox sign-in
/// cookies and website data are intentionally not included.
@MainActor
enum SettingsBackupManager {
    static let currentSchema = 1
    private static let fileName = "Mac-XCloud-settings.json"

    struct Snapshot {
        var schema = currentSchema
        var appVersion: String
        var exportedAt: Date
        var defaults: [String: Any] = [:]
        var presets: [String: String] = [:]   // filename -> base64 JSON
    }

    /// Keys considered user settings. Migration bookkeeping keys are excluded
    /// so restoring them can never confuse first-run migrations.
    private static let defaultKeys: [String] = [
        "nativeBetterXcloudGlobal", "nativeBetterXcloudStream",
        "app.clarityPipeline", "cachedServerRegions",
        "nativeController.settings.v1",
        "controller.globalRumbleGain", "controller.streamCalibration",
        "ledColorIndex", "ledCustomR", "ledCustomG", "ledCustomB", "ledUsesCustom",
        "inputPresets.activeID", "inputPresets.autoGameProfiles", "inputPresets.gameBaseID",
        "inputPresets.games.v1",
        BrowserModel.windowFramesDefaultsKey,
        "motion.steeringCenterBank.v2",
    ] + KeyboardMouseStore.persistedKeys + GameSetupPreferences.persistedKeys
      + StreamHealthMonitor.persistedKeys + BrowserModel.fullscreenPersistedKeys

    private static let migrationKeys: Set<String> = [
        "nativeController.settingsVersion", "nativeRendererRecoveryVersion",
        "inputPresets.defaultMigrated.v2", "inputPresets.defaultWebMigrated.v2",
    ]

    // MARK: - Typed value wrapping
    //
    // JSON cannot distinguish Bool from Int/Float through NSNumber bridging
    // in Swift, so every stored value is wrapped with an explicit type tag.

    private static func wrap(_ object: Any) -> [String: Any]? {
        if let data = object as? Data {
            return ["t": "data", "v": data.base64EncodedString()]
        }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return ["t": "bool", "v": number.boolValue]
            }
            let type = String(cString: number.objCType)
            if type == "f" || type == "d" {
                return ["t": "double", "v": number.doubleValue]
            }
            return ["t": "int", "v": number.intValue]
        }
        if object is String {
            return ["t": "string", "v": object]
        }
        if let dict = object as? [String: String] {
            return ["t": "stringDict", "v": dict]
        }
        if let array = object as? [String] {
            return ["t": "stringArray", "v": array]
        }
        return nil
    }

    private static func unwrap(_ wrapped: Any) -> Any? {
        guard let dict = wrapped as? [String: Any], let type = dict["t"] as? String else { return nil }
        switch type {
        case "data":
            guard let text = dict["v"] as? String, let data = Data(base64Encoded: text) else { return nil }
            return data
        case "bool": return dict["v"] as? Bool
        case "double": return dict["v"] as? Double
        case "int": return dict["v"] as? Int
        case "string": return dict["v"] as? String
        case "stringDict": return dict["v"] as? [String: String]
        case "stringArray": return dict["v"] as? [String]
        default: return nil
        }
    }

    // MARK: - Export

    static func buildSnapshot(browser: BrowserModel) -> Snapshot {
        var snapshot = Snapshot(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            exportedAt: .now
        )
        let defaults = UserDefaults.standard
        for key in defaultKeys {
            guard let raw = defaults.object(forKey: key) else { continue }
            if let wrapped = wrap(raw), JSONSerialization.isValidJSONObject(wrapped) {
                snapshot.defaults[key] = wrapped
            }
        }
        if let presetsDir = browser.inputPresets.storageRootURL?
            .appendingPathComponent("presets", isDirectory: true) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: presetsDir.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".json") {
                if let data = try? Data(contentsOf: presetsDir.appendingPathComponent(name)) {
                    snapshot.presets[name] = data.base64EncodedString()
                }
            }
        }
        return snapshot
    }

    static func encode(_ snapshot: Snapshot) throws -> Data {
        let root: [String: Any] = [
            "schema": snapshot.schema,
            "appVersion": snapshot.appVersion,
            "exportedAt": ISO8601DateFormatter().string(from: snapshot.exportedAt),
            "defaults": snapshot.defaults,
            "presets": snapshot.presets,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func presentExport(browser: BrowserModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshot = buildSnapshot(browser: browser)
            try encode(snapshot).write(to: url, options: .atomic)
            browser.settingsModel.saveMessage = "Exported all settings to \(url.lastPathComponent)."
        } catch {
            browser.settingsModel.saveMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Import

    static func decode(_ data: Data) throws -> Snapshot {
        guard data.count <= 10_000_000 else { throw CocoaError(.fileReadTooLarge) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = root["schema"] as? Int, (1...currentSchema).contains(schema) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var snapshot = Snapshot(
            schema: schema,
            appVersion: root["appVersion"] as? String ?? "",
            exportedAt: ISO8601DateFormatter().date(from: root["exportedAt"] as? String ?? "") ?? .now
        )
        snapshot.defaults = root["defaults"] as? [String: Any] ?? [:]
        snapshot.presets = root["presets"] as? [String: String] ?? [:]
        return snapshot
    }

    /// Validates preset files before touching live storage; invalid entries
    /// are dropped, never fatal, so a partially corrupt bundle still restores
    /// everything usable.
    static func validatablePresets(in snapshot: Snapshot, browser: BrowserModel) -> [(name: String, data: Data)] {
        var result: [(String, Data)] = []
        for (name, encoded) in snapshot.presets.sorted(by: { $0.key < $1.key }) {
            // Reject path separators in filenames: they must be plain names.
            guard name.hasSuffix(".json"), !name.contains("/"), !name.contains("\\"), !name.contains(".."),
                  let data = Data(base64Encoded: encoded), data.count <= 2_000_000,
                  browser.inputPresets.backupValidate(data) else { continue }
            result.append((name, data))
        }
        return result
    }

    static func presentImport(browser: BrowserModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 10_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let snapshot = try decode(Data(contentsOf: url))
            apply(snapshot, browser: browser)
        } catch {
            browser.settingsModel.saveMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    static func apply(_ snapshot: Snapshot, browser: BrowserModel) {
        let defaults = UserDefaults.standard
        for (key, wrapped) in snapshot.defaults where defaultKeys.contains(key) && !migrationKeys.contains(key) {
            guard let value = unwrap(wrapped) else { continue }
            defaults.set(value, forKey: key)
        }
        let presetFiles = validatablePresets(in: snapshot, browser: browser)
        let skipped = snapshot.presets.count - presetFiles.count
        if let root = browser.inputPresets.storageRootURL?
            .appendingPathComponent("presets", isDirectory: true) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (name, data) in presetFiles {
                try? data.write(to: root.appendingPathComponent(name), options: .atomic)
            }
        }
        // Reload every affected subsystem so the UI reflects the import.
        browser.keyboardMouse.reloadFromDefaults()
        browser.streamHealth.noticesEnabled = defaults.object(forKey: StreamHealthMonitor.persistedKeys[0]) as? Bool ?? true
        browser.fullscreenForGames = defaults.bool(forKey: BrowserModel.fullscreenPersistedKeys[0])
        browser.controllerFeatures.reloadSettings()
        browser.inputPresets.reloadFromDisk()
        browser.settingsModel.load()
        let source = snapshot.appVersion.isEmpty ? "a backup" : "a backup from Mac Xcloud \(snapshot.appVersion)"
        let dropped = skipped > 0 ? " \(skipped) unreadable profile file(s) were skipped." : ""
        browser.settingsModel.saveMessage = "Imported settings from \(source) — reloading the Xbox page…\(dropped)"
        browser.reload()
    }
}
