import AppKit
import Combine
import CryptoKit
import Foundation

// MARK: - Portable Better xCloud data

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct BetterXCloudProfileSnapshot: Codable, Equatable, Sendable {
    var sourceID: Int
    var name: String
    var data: JSONValue
}

struct BetterXCloudInputSettings: Codable, Equatable, Sendable {
    var mkbEnabled: Bool
    var nativeMkbMode: String
    var p1Slot: Int?
    var p2Slot: Int?
    var mkbP1: BetterXCloudProfileSnapshot?
    var mkbP2: BetterXCloudProfileSnapshot?
    var keyboard: BetterXCloudProfileSnapshot?
    var controllerShortcuts: BetterXCloudProfileSnapshot?
    var controllerCustomization: BetterXCloudProfileSnapshot?

    static let `default` = BetterXCloudInputSettings(
        mkbEnabled: false,
        nativeMkbMode: "default",
        p1Slot: 1,
        p2Slot: 0,
        mkbP1: nil,
        mkbP2: nil,
        keyboard: nil,
        controllerShortcuts: nil,
        controllerCustomization: nil
    )
}

// MARK: - Full input presets

struct InputPreset: Codable, Equatable, Identifiable, Sendable {
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var controller: PerPresetControllerSettings
    var betterXCloud: BetterXCloudInputSettings

    var isDefault: Bool { id == Self.defaultID }

    static let `default` = InputPreset(
        id: defaultID,
        name: "Default",
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        controller: .default,
        betterXCloud: .default
    )
}

struct CustomAdaptiveTriggerPreset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var parameters: AdaptiveTriggerCustomParameters
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, parameters: AdaptiveTriggerCustomParameters = .default, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.parameters = parameters
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

private struct PresetEnvelope<Value: Codable>: Codable {
    let schemaVersion: Int
    let kind: String
    let revision: Int
    let checksum: String
    let value: Value
}

private struct PresetTombstone: Codable, Equatable {
    let id: UUID
    let kind: String
    let revision: Int
    let deletedAt: Date
}

private struct TombstoneFile: Codable {
    let schemaVersion: Int
    var tombstones: [PresetTombstone]
}

private struct PresetIndex: Codable {
    struct Entry: Codable {
        let id: UUID
        let name: String
        let revision: Int
        let updatedAt: Date
        let file: String
    }
    let schemaVersion: Int
    let generatedAt: Date
    let presets: [Entry]
    let adaptiveTriggerPresets: [Entry]
}

enum InputPresetStorageStatus: Equatable {
    case checking
    case local(URL)
    case unavailable(String)

    var title: String {
        switch self {
        case .checking: "Checking storage…"
        case .local: "Local storage"
        case .unavailable: "Storage unavailable"
        }
    }

    var detail: String {
        switch self {
        case .checking: "Locating Xbox Cloud data"
        case .local(let url): url.path
        case .unavailable(let reason): reason
        }
    }

    var directoryURL: URL? {
        if case .local(let url) = self { return url }
        return nil
    }
}

@MainActor
final class InputPresetStore: ObservableObject {
    static let schemaVersion = 2

    @Published private(set) var presets: [InputPreset] = [.default]
    @Published private(set) var customTriggerPresets: [CustomAdaptiveTriggerPreset] = []
    @Published private(set) var storageStatus: InputPresetStorageStatus = .checking
    @Published private(set) var activePresetID: UUID = InputPreset.defaultID
    @Published var operationMessage: String?
    @Published private(set) var isBusy = false

    private weak var browser: BrowserModel?
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private var rootURL: URL?
    private var cancellables = Set<AnyCancellable>()
    private var webAutosaveTask: Task<Void, Never>?
    private var webAutosaveGeneration: UInt64 = 0
    private var webApplyTask: Task<String, Never>?
    private var webApplyGeneration: UInt64 = 0
    private var readinessRetryTask: Task<Void, Never>?
    private var suppressAutosave = false

    private var presetsURL: URL? { rootURL?.appendingPathComponent("presets", isDirectory: true) }
    private var triggersURL: URL? { rootURL?.appendingPathComponent("adaptive-trigger-presets", isDirectory: true) }
    private var tombstonesURL: URL? { rootURL?.appendingPathComponent("tombstones.json") }

    init(browser: BrowserModel, fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        self.browser = browser
        self.fileManager = fileManager
        self.defaults = defaults
        if let raw = defaults.string(forKey: "inputPresets.activeID"), let id = UUID(uuidString: raw) {
            activePresetID = id
        }
        reloadFromDisk()
        browser.controllerFeatures.$settings
            .dropFirst()
            .debounce(for: .milliseconds(700), scheduler: RunLoop.main)
            .sink { [weak self] settings in self?.autosaveActivePreset(controller: settings.perPreset) }
            .store(in: &cancellables)
    }

    var activePreset: InputPreset { presets.first(where: { $0.id == activePresetID }) ?? .default }

    func reloadFromDisk() {
        invalidateAsyncOperations()
        storageStatus = .checking
        do {
            let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Xbox Cloud data", isDirectory: true)
            rootURL = base
            try createLayout(at: base)
            storageStatus = .local(base)
            let decoder = decoder()
            var loadedPresets: [InputPreset] = []
            var loadedTriggers: [CustomAdaptiveTriggerPreset] = []
            if let presetsURL {
                for url in try jsonFiles(in: presetsURL) {
                    do {
                        let envelope = try decoder.decode(PresetEnvelope<InputPreset>.self, from: Data(contentsOf: url))
                        guard envelope.schemaVersion <= Self.schemaVersion,
                              envelope.kind == "input-preset",
                              try checksum(for: envelope.value) == envelope.checksum else { continue }
                        loadedPresets.append(envelope.value)
                    } catch { operationMessage = "Skipped unreadable file: \(url.lastPathComponent)" }
                }
            }
            if let triggersURL {
                for url in try jsonFiles(in: triggersURL) {
                    do {
                        let envelope = try decoder.decode(PresetEnvelope<CustomAdaptiveTriggerPreset>.self, from: Data(contentsOf: url))
                        guard envelope.schemaVersion <= Self.schemaVersion,
                              envelope.kind == "adaptive-trigger-preset",
                              try checksum(for: envelope.value) == envelope.checksum else { continue }
                        loadedTriggers.append(envelope.value)
                    } catch { operationMessage = "Skipped unreadable file: \(url.lastPathComponent)" }
                }
            }
            let defaultURL = presetURL(for: InputPreset.defaultID)
            let migrationKey = "inputPresets.defaultMigrated.v2"
            var savedDefault = loadedPresets.first(where: \.isDefault) ?? .default
            let shouldMigrateDefault = !fileManager.fileExists(atPath: defaultURL.path) && !defaults.bool(forKey: migrationKey)
            if shouldMigrateDefault, let browser {
                savedDefault.controller = browser.controllerFeatures.settings.perPreset
                savedDefault.updatedAt = .now
            }
            presets = [savedDefault] + loadedPresets.filter { !$0.isDefault }
            customTriggerPresets = loadedTriggers
            sortPresets()
            sortTriggerPresets()
            if !fileManager.fileExists(atPath: defaultURL.path) { try write(savedDefault) }
            try writeIndex()
            if shouldMigrateDefault { defaults.set(true, forKey: migrationKey) }
            if !presets.contains(where: { $0.id == activePresetID }) { setActive(InputPreset.defaultID) }
            applyActiveNativePreset()
        } catch {
            rootURL = nil
            storageStatus = .unavailable(error.localizedDescription)
            presets = [.default]
            customTriggerPresets = []
        }
    }


    private func applyActiveNativePreset() {
        guard let browser, let preset = presets.first(where: { $0.id == activePresetID }) else { return }
        suppressAutosave = true
        browser.controllerFeatures.updateSettings { $0.apply(preset.controller) }
        suppressAutosave = false
    }

    func createPreset(named proposedName: String) async {
        guard let browser else { return }
        let name = uniqueName(from: proposedName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "New Preset")
        isBusy = true
        defer { isBusy = false }
        do {
            let now = Date()
            let preset = InputPreset(
                id: UUID(), name: name, createdAt: now, updatedAt: now,
                controller: browser.controllerFeatures.settings.perPreset,
                betterXCloud: try await captureBetterXCloudSettings()
            )
            try write(preset)
            presets.append(preset)
            sortPresets()
            try writeIndex()
            await applyPreset(id: preset.id)
            operationMessage = "Created and selected \(name)"
        } catch { operationMessage = "Could not create preset: \(error.localizedDescription)" }
    }

    func saveCurrentAsDefault() async { await updatePreset(id: InputPreset.defaultID) }

    func renamePreset(id: UUID, name proposedName: String) {
        guard id != InputPreset.defaultID, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            operationMessage = "Preset name cannot be empty"
            return
        }
        var preset = presets[index]
        preset.name = uniqueName(from: trimmed, excluding: id)
        preset.updatedAt = .now
        do {
            try write(preset)
            presets[index] = preset
            sortPresets()
            try writeIndex()
            operationMessage = "Renamed preset to \(preset.name)"
        } catch { operationMessage = "Could not rename preset: \(error.localizedDescription)" }
    }

    func updatePreset(id: UUID) async {
        guard let browser, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            var preset = presets[index]
            preset.controller = browser.controllerFeatures.settings.perPreset
            preset.betterXCloud = try await captureBetterXCloudSettings()
            preset.updatedAt = .now
            try write(preset)
            presets[index] = preset
            sortPresets()
            try writeIndex()
            operationMessage = preset.isDefault ? "Saved current settings as Default" : "Updated \(preset.name)"
        } catch { operationMessage = "Could not update preset: \(error.localizedDescription)" }
    }

    func duplicatePreset(id: UUID) {
        guard let source = presets.first(where: { $0.id == id }) else { return }
        var copy = source
        copy.id = UUID()
        copy.name = uniqueName(from: source.name + " Copy")
        copy.createdAt = .now
        copy.updatedAt = .now
        do {
            try write(copy)
            presets.append(copy)
            sortPresets()
            try writeIndex()
            operationMessage = "Duplicated \(source.name)"
        } catch { operationMessage = "Could not duplicate preset: \(error.localizedDescription)" }
    }

    func deletePreset(id: UUID) async {
        guard id != InputPreset.defaultID, let preset = presets.first(where: { $0.id == id }) else { return }
        do {
            let revision = inputRevision(at: presetURL(for: id)) + 1
            try recordTombstone(id: id, kind: "input-preset", revision: revision)
            try removeLocal(presetURL(for: id))
            presets.removeAll { $0.id == id }
            try writeIndex()
            if activePresetID == id { await applyPreset(id: InputPreset.defaultID) }
            operationMessage = "Deleted \(preset.name)"
        } catch { operationMessage = "Could not delete preset: \(error.localizedDescription)" }
    }

    func applyPreset(id: UUID) async {
        guard let browser, let preset = presets.first(where: { $0.id == id }) else { return }
        cancelPendingWebAutosave()
        webApplyTask?.cancel()
        webApplyTask = nil
        readinessRetryTask?.cancel()
        readinessRetryTask = nil
        webApplyGeneration &+= 1
        let generation = webApplyGeneration
        browser.controllerFeatures.resetMacros()
        isBusy = true
        suppressAutosave = true

        // Preserve hardware-specific calibration while applying only portable settings.
        setActive(id)
        browser.controllerFeatures.updateSettings { $0.apply(preset.controller) }
        let task = Task { [weak self] in
            await self?.applyWebSettings(for: preset, generation: generation)
                ?? " · Better xCloud settings will apply when the page is ready"
        }
        webApplyTask = task
        let webMessage = await task.value
        guard generation == webApplyGeneration, activePresetID == id else { return }
        webApplyTask = nil
        suppressAutosave = false
        isBusy = false
        operationMessage = "Selected \(preset.name)\(webMessage)"
        browser.statusController?.refreshMenu()
    }

    func retryActiveWebSettings() {
        cancelPendingWebAutosave()
        readinessRetryTask?.cancel()
        let expectedID = activePresetID
        let expectedGeneration = webApplyGeneration
        readinessRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self,
                  self.activePresetID == expectedID,
                  self.webApplyGeneration == expectedGeneration else { return }
            if let currentApply = self.webApplyTask {
                _ = await currentApply.value
                guard !Task.isCancelled, self.activePresetID == expectedID else { return }
            }
            await self.retryActiveWebSettingsNow(id: expectedID)
        }
    }

    private func retryActiveWebSettingsNow(id: UUID) async {
        guard var preset = presets.first(where: { $0.id == id }), activePresetID == id else { return }
        // On the first migration, capture the user's existing web choices before
        // applying Default. Mark migration complete only after both writes succeed.
        if preset.isDefault, !defaults.bool(forKey: "inputPresets.defaultWebMigrated.v2"),
           let web = try? await captureBetterXCloudSettings(),
           activePresetID == id,
           let index = presets.firstIndex(where: \.isDefault) {
            var migrated = presets[index]
            migrated.betterXCloud = web
            migrated.updatedAt = .now
            do {
                try write(migrated)
                let old = presets[index]
                presets[index] = migrated
                do { try writeIndex() }
                catch { presets[index] = old; throw error }
                defaults.set(true, forKey: "inputPresets.defaultWebMigrated.v2")
                preset = migrated
            } catch {
                operationMessage = "Default web settings migration will retry"
                return
            }
        }
        guard activePresetID == id else { return }
        webApplyTask?.cancel()
        webApplyGeneration &+= 1
        let generation = webApplyGeneration
        let task = Task { [weak self] in
            await self?.applyWebSettings(for: preset, generation: generation)
                ?? " · Better xCloud settings will apply when the page is ready"
        }
        webApplyTask = task
        let message = await task.value
        guard generation == webApplyGeneration, activePresetID == id else { return }
        webApplyTask = nil
        if !message.isEmpty { operationMessage = "Selected \(preset.name)\(message)" }
    }

    private func applyWebSettings(for preset: InputPreset, generation: UInt64) async -> String {
        guard let browser else { return " · Better xCloud settings will apply when the page is ready" }
        do {
            let object = try jsonObject(preset.betterXCloud)
            guard !Task.isCancelled, generation == webApplyGeneration, activePresetID == preset.id else { return "" }
            let token = "\(generation)-\(preset.id.uuidString)"
            let result = try await browser.callAsyncJS(
                "return JSON.stringify(await BxCBridge.applyInputPresetSettings(bundle, presetName, applyToken));",
                arguments: ["bundle": object, "presetName": preset.name, "applyToken": token]
            )
            guard !Task.isCancelled, generation == webApplyGeneration, activePresetID == preset.id else { return "" }
            if let text = result as? String,
               let data = text.data(using: .utf8),
               let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let warnings = response["warnings"] as? [String], !warnings.isEmpty {
                return " · " + warnings.joined(separator: "; ")
            }
            return ""
        } catch {
            return Task.isCancelled ? "" : " · Better xCloud settings will apply when the page is ready"
        }
    }

    func revealStorage() {
        guard let rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([rootURL])
    }


    // MARK: - Adaptive trigger preset CRUD

    func createTriggerPreset(named proposedName: String, parameters: AdaptiveTriggerCustomParameters) -> UUID? {
        let name = uniqueTriggerName(from: proposedName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Custom Trigger")
        let preset = CustomAdaptiveTriggerPreset(name: name, parameters: parameters.clamped)
        do {
            try write(preset)
            customTriggerPresets.append(preset)
            sortTriggerPresets()
            try writeIndex()
            operationMessage = "Created \(name)"
            return preset.id
        } catch { operationMessage = "Could not create trigger preset: \(error.localizedDescription)"; return nil }
    }

    func saveTriggerPreset(_ preset: CustomAdaptiveTriggerPreset) {
        guard let index = customTriggerPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        var updated = preset
        updated.name = uniqueTriggerName(from: preset.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Custom Trigger", excluding: preset.id)
        updated.parameters = updated.parameters.clamped
        updated.updatedAt = .now
        do {
            try write(updated)
            customTriggerPresets[index] = updated
            sortTriggerPresets()
            try writeIndex()
            operationMessage = "Saved \(updated.name)"
        } catch { operationMessage = "Could not save trigger preset: \(error.localizedDescription)" }
    }

    func duplicateTriggerPreset(id: UUID) -> UUID? {
        guard var copy = customTriggerPresets.first(where: { $0.id == id }) else { return nil }
        copy.id = UUID()
        copy.name = uniqueTriggerName(from: copy.name + " Copy")
        copy.createdAt = .now
        copy.updatedAt = .now
        do {
            try write(copy)
            customTriggerPresets.append(copy)
            sortTriggerPresets()
            try writeIndex()
            return copy.id
        } catch { operationMessage = "Could not duplicate trigger preset: \(error.localizedDescription)"; return nil }
    }

    func deleteTriggerPreset(id: UUID) {
        guard let preset = customTriggerPresets.first(where: { $0.id == id }) else { return }
        do {
            let revision = triggerRevision(at: triggerURL(for: id)) + 1
            try recordTombstone(id: id, kind: "adaptive-trigger-preset", revision: revision)
            try removeLocal(triggerURL(for: id))
            customTriggerPresets.removeAll { $0.id == id }
            try writeIndex()
            operationMessage = "Deleted \(preset.name)"
        } catch { operationMessage = "Could not delete trigger preset: \(error.localizedDescription)" }
    }

    // MARK: - Autosave

    private func autosaveActivePreset(controller: PerPresetControllerSettings) {
        guard !suppressAutosave, let index = presets.firstIndex(where: { $0.id == activePresetID }) else { return }
        var preset = presets[index]
        guard preset.controller != controller else { return }
        preset.controller = controller
        preset.updatedAt = .now
        do {
            try write(preset)
            presets[index] = preset
            try writeIndex()
            operationMessage = "Autosaved \(preset.name)"
        } catch { operationMessage = "Autosave failed: \(error.localizedDescription)" }

        // Web preferences live outside the native settings publisher. Capture
        // them after native changes when the bridge is available, without ever
        // serializing live ControllerInputSnapshot values.
        scheduleWebAutosave(for: preset.id)
    }

    func noteBetterXCloudInputChanged(for intendedPresetID: UUID? = nil) {
        let id = intendedPresetID ?? activePresetID
        guard activePresetID == id else { return }
        scheduleWebAutosave(for: id)
    }

    private func scheduleWebAutosave(for id: UUID) {
        guard !suppressAutosave, activePresetID == id else { return }
        webAutosaveTask?.cancel()
        webAutosaveGeneration &+= 1
        let generation = webAutosaveGeneration
        webAutosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.autosaveWebState(for: id, generation: generation)
        }
    }

    private func cancelPendingWebAutosave() {
        webAutosaveTask?.cancel()
        webAutosaveTask = nil
        webAutosaveGeneration &+= 1
    }

    func invalidateWebOperationsForNavigation() {
        cancelPendingWebAutosave()
        webApplyTask?.cancel()
        webApplyTask = nil
        readinessRetryTask?.cancel()
        readinessRetryTask = nil
        webApplyGeneration &+= 1
        suppressAutosave = false
        isBusy = false
    }

    private func invalidateAsyncOperations() {
        invalidateWebOperationsForNavigation()
    }

    private func autosaveWebState(for id: UUID, generation: UInt64) async {
        guard !suppressAutosave, activePresetID == id, webAutosaveGeneration == generation else { return }
        do {
            let web = try await captureBetterXCloudSettings()
            guard !Task.isCancelled,
                  !suppressAutosave,
                  activePresetID == id,
                  webAutosaveGeneration == generation,
                  let index = presets.firstIndex(where: { $0.id == id }),
                  presets[index].betterXCloud != web else { return }
            presets[index].betterXCloud = web
            presets[index].updatedAt = .now
            try write(presets[index])
            try writeIndex()
        } catch {
            // Navigation can make WebKit unavailable; the next settings change or
            // explicit save retries capture without disturbing local native data.
        }
    }

    // MARK: - Storage

    private func captureBetterXCloudSettings() async throws -> BetterXCloudInputSettings {
        guard let browser else { throw CocoaError(.coderInvalidValue) }
        let result = try await browser.callAsyncJS("return JSON.stringify(await BxCBridge.captureInputPresetSettings());")
        guard let text = result as? String, let data = text.data(using: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return try decoder().decode(BetterXCloudInputSettings.self, from: data)
    }

    private func createLayout(at root: URL) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("presets", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("adaptive-trigger-presets", isDirectory: true), withIntermediateDirectories: true)
    }

    private func jsonFiles(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
    }

    private func write(_ preset: InputPreset) throws {
        let revision = max(inputRevision(at: presetURL(for: preset.id)),
                           tombstoneRevision(id: preset.id, kind: "input-preset")) + 1
        let envelope = PresetEnvelope(schemaVersion: Self.schemaVersion, kind: "input-preset", revision: revision, checksum: try checksum(for: preset), value: preset)
        try writeData(encoded(envelope), to: presetURL(for: preset.id))
    }

    private func write(_ preset: CustomAdaptiveTriggerPreset) throws {
        let revision = max(triggerRevision(at: triggerURL(for: preset.id)),
                           tombstoneRevision(id: preset.id, kind: "adaptive-trigger-preset")) + 1
        let envelope = PresetEnvelope(schemaVersion: Self.schemaVersion, kind: "adaptive-trigger-preset", revision: revision, checksum: try checksum(for: preset), value: preset)
        try writeData(encoded(envelope), to: triggerURL(for: preset.id))
    }

    private func writeIndex() throws {
        guard let rootURL else { return }
        let entries = presets.map { PresetIndex.Entry(id: $0.id, name: $0.name, revision: inputRevision(at: presetURL(for: $0.id)), updatedAt: $0.updatedAt, file: $0.isDefault ? "default.json" : "\($0.id.uuidString.lowercased()).json") }
        let triggers = customTriggerPresets.map { PresetIndex.Entry(id: $0.id, name: $0.name, revision: triggerRevision(at: triggerURL(for: $0.id)), updatedAt: $0.updatedAt, file: "\($0.id.uuidString.lowercased()).json") }
        try writeData(encoded(PresetIndex(schemaVersion: Self.schemaVersion, generatedAt: .now, presets: entries, adaptiveTriggerPresets: triggers)), to: rootURL.appendingPathComponent("index.json"))
    }

    private func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private func removeLocal(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func writeIfChanged(_ data: Data, to url: URL) throws {
        if fileManager.fileExists(atPath: url.path), (try? Data(contentsOf: url)) == data { return }
        try writeData(data, to: url)
    }

    private func loadTombstones(at root: URL) -> [PresetTombstone] {
        let url = root.appendingPathComponent("tombstones.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let file = try? decoder().decode(TombstoneFile.self, from: data),
              file.schemaVersion <= Self.schemaVersion else { return [] }
        return file.tombstones
    }

    private func tombstoneRevision(id: UUID, kind: String) -> Int {
        guard let rootURL else { return 0 }
        return loadTombstones(at: rootURL)
            .filter { $0.id == id && $0.kind == kind }
            .map(\.revision).max() ?? 0
    }

    private func recordTombstone(id: UUID, kind: String, revision: Int) throws {
        guard let rootURL, let tombstonesURL else { return }
        var all = loadTombstones(at: rootURL)
        all.removeAll { $0.id == id && $0.kind == kind }
        all.append(PresetTombstone(id: id, kind: kind, revision: revision, deletedAt: .now))
        try writeData(encoded(TombstoneFile(schemaVersion: Self.schemaVersion, tombstones: all)), to: tombstonesURL)
    }

    private func inputRevision(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url), let envelope = try? decoder().decode(PresetEnvelope<InputPreset>.self, from: data) else { return 0 }
        return envelope.revision
    }

    private func triggerRevision(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url), let envelope = try? decoder().decode(PresetEnvelope<CustomAdaptiveTriggerPreset>.self, from: data) else { return 0 }
        return envelope.revision
    }

    private func presetURL(for id: UUID) -> URL {
        let name = id == InputPreset.defaultID ? "default.json" : "\(id.uuidString.lowercased()).json"
        return presetsURL!.appendingPathComponent(name)
    }

    private func triggerURL(for id: UUID) -> URL { triggersURL!.appendingPathComponent("\(id.uuidString.lowercased()).json") }

    private func checksum<T: Encodable>(for value: T) throws -> String {
        SHA256.hash(data: try encoded(value)).map { String(format: "%02x", $0) }.joined()
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: encoded(value)) }

    private func setActive(_ id: UUID) {
        activePresetID = id
        defaults.set(id.uuidString, forKey: "inputPresets.activeID")
    }

    private func sortPresets() {
        presets = presets.filter(\.isDefault) + presets.filter { !$0.isDefault }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sortTriggerPresets() {
        customTriggerPresets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uniqueName(from base: String, excluding id: UUID? = nil) -> String {
        unique(base, used: Set(presets.filter { $0.id != id }.map { $0.name.lowercased() }))
    }

    private func uniqueTriggerName(from base: String, excluding id: UUID? = nil) -> String {
        unique(base, used: Set(customTriggerPresets.filter { $0.id != id }.map { $0.name.lowercased() }))
    }

    private func unique(_ base: String, used: Set<String>) -> String {
        guard used.contains(base.lowercased()) else { return base }
        var number = 2
        while used.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
