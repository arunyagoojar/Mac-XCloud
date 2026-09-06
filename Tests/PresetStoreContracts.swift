import AppKit
import Combine
import Foundation

@MainActor
final class TestControllerFeatures {
    @Published var settings = ControllerSettings.default
    func updateSettings(_ update: (inout ControllerSettings) -> Void) { var copy = settings; update(&copy); settings = copy }
    func resetMacros() {}
}

@MainActor
final class TestStatusController { func refreshMenu() {} }

@MainActor
final class BrowserModel {
    let controllerFeatures = TestControllerFeatures()
    var statusController: TestStatusController?
    func callAsyncJS(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        throw CocoaError(.fileReadUnknown)
    }
}

final class IsolatedFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask, appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
        root
    }
}

@main
struct PresetStoreContracts {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "MacXcloud.PresetTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let files = IsolatedFileManager(root: root)
        let browser = BrowserModel()
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label); checks += 1; print("PASS: \(label)")
        }
        let store = InputPresetStore(browser: browser, fileManager: files, defaults: defaults)
        browser.controllerFeatures.updateSettings { $0.adaptiveTriggers.leftPreset = .bowAndArrow }
        await store.createPreset(named: "Racing")
        check(store.presets.count == 2, "New profile can save with the web bridge unavailable")
        let racing = store.activePresetID
        check(store.activePreset.controller.adaptiveTriggers.leftPreset == .bowAndArrow, "New profile captures native settings")
        check(store.operationMessage?.contains("not captured") == true, "Offline save discloses retained web selections")
        browser.controllerFeatures.updateSettings { $0.adaptiveTriggers.leftPreset = .braking }
        await store.applyPreset(id: InputPreset.defaultID)
        check(store.presets.first { $0.id == racing }?.controller.adaptiveTriggers.leftPreset == .braking, "Switch flushes outgoing native edit before debounce")
        check(store.activePreset.controller.adaptiveTriggers.leftPreset == .bowAndArrow, "Switch does not copy outgoing setting into Default")
        store.renamePreset(id: racing, name: "Driving")
        check(store.presets.first { $0.id == racing }?.controller.adaptiveTriggers.leftPreset == .braking, "Rename preserves inactive profile data")
        store.renamePreset(id: InputPreset.defaultID, name: "Wrong")
        await store.deletePreset(id: InputPreset.defaultID)
        check(store.presets.contains { $0.isDefault && $0.name == "Default" }, "Default cannot be renamed or deleted")
        browser.controllerFeatures.updateSettings { $0.haptics.intensityMultiplier = 0.8 }
        await store.updatePreset(id: racing)
        check(store.presets.first { $0.id == racing }?.controller.haptics.intensityMultiplier == 0.8, "Explicit offline update saves native settings")
        let trigger = store.createTriggerPreset(named: "Pulse", parameters: .default)!
        check(store.customTriggerPresets.contains { $0.id == trigger }, "Custom trigger library saves separately")
        store.reloadFromDisk()
        check(store.presets.count == 2 && store.customTriggerPresets.count == 1, "Written checksummed files reload intact")
        store.deleteTriggerPreset(id: trigger)
        await store.deletePreset(id: racing)
        check(store.presets.count == 1 && store.customTriggerPresets.isEmpty, "Custom records can be deleted without affecting Default")
        let portable = try store.exportPresetData(id: InputPreset.defaultID)
        let imported = try store.importPresetData(portable)
        check(imported != InputPreset.defaultID && store.presets.count == 2, "Import creates a new profile without overwriting Default")
        do { _ = try store.importPresetData(Data("{}".utf8)); preconditionFailure("Corrupt import accepted") }
        catch { check(store.presets.count == 2, "Invalid import does not mutate storage") }
        await store.noteGame(id: "game-a", playing: true)
        await store.applyPreset(id: imported)
        await store.noteGame(id: "", playing: false)
        check(store.activePresetID == InputPreset.defaultID, "Leaving a game restores the previous global profile")
        await store.noteGame(id: "game-a", playing: true)
        check(store.activePresetID == imported, "Returning to a game restores its selected profile")
        await store.noteGame(id: "", playing: true)
        check(store.currentGameID == "game-a", "Missing title metadata cannot erase the game association")
        await store.noteGame(id: "", playing: false)
        await store.deletePreset(id: imported)
        let baselineRange = browser.controllerFeatures.settings.enhancements?.steeringRangeDegrees
        await store.noteGame(id: "independent-a", title: "Forza Horizon 6", playing: true)
        let gameA = store.activePresetID
        check(gameA != InputPreset.defaultID && store.activePreset.name.contains("Forza"), "New game gets its own named profile")
        browser.controllerFeatures.updateSettings { settings in
            var e = settings.enhancements ?? ControllerEnhancements(); e.steeringRangeDegrees = 72; settings.enhancements = e
        }
        await store.noteGame(id: "independent-b", title: "Another Game", playing: true)
        let gameB = store.activePresetID
        check(gameA != gameB && browser.controllerFeatures.settings.enhancements?.steeringRangeDegrees == baselineRange,
              "Second game inherits global settings, not the previous game's steering")
        browser.controllerFeatures.updateSettings { settings in
            var e = settings.enhancements ?? ControllerEnhancements(); e.steeringRangeDegrees = 24; settings.enhancements = e
        }
        await store.noteGame(id: "independent-a", title: "Forza Horizon 6", playing: true)
        check(store.activePresetID == gameA && browser.controllerFeatures.settings.enhancements?.steeringRangeDegrees == 72,
              "Returning restores game-specific tuning without manual save")
        await store.noteGame(id: "", playing: false)
        check(store.activePresetID == InputPreset.defaultID && browser.controllerFeatures.settings.enhancements?.steeringRangeDegrees == baselineRange,
              "Global settings remain independent after game tuning")
        await store.noteGame(id: "", title: "A Title Only", playing: true)
        let titleProfile = store.activePresetID
        check(store.currentGameID == "title:a title only", "Game title provides a fallback identity")
        await store.noteGame(id: "stable-id", title: "A Title Only", playing: true)
        check(store.currentGameID == "stable-id" && store.activePresetID == titleProfile, "Late stable ID keeps the title's existing profile")
        let restartedBrowser = BrowserModel()
        let restartedStore = InputPresetStore(browser: restartedBrowser, fileManager: files, defaults: defaults)
        check(restartedStore.activePresetID == InputPreset.defaultID, "Relaunch returns to global settings until the game is detected")
        await store.noteGame(id: "", playing: false)
        check(InputPresetStore.gameKey(id: "", title: "Xbox Cloud Gaming") == "", "Generic website titles cannot become game identities")
        store.autoGameProfiles = false
        let countBeforeDisabled = store.presets.count
        await store.noteGame(id: "disabled-game", title: "Disabled Game", playing: true)
        check(store.presets.count == countBeforeDisabled && store.activePresetID == InputPreset.defaultID, "Disabling game recall prevents automatic profile creation")
        await store.noteGame(id: "", playing: false)
        store.autoGameProfiles = true
        let saved = root.appendingPathComponent("Xbox Cloud data/presets/default.json")
        let data = try Data(contentsOf: saved)
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        envelope["checksum"] = "invalid"
        let damaged = try JSONSerialization.data(withJSONObject: envelope)
        try damaged.write(to: saved)
        store.reloadFromDisk()
        browser.controllerFeatures.updateSettings { $0.led.brightness = 0.3 }
        await store.saveCurrentAsDefault()
        check(try Data(contentsOf: saved) == damaged, "Unreadable Default is not silently overwritten")
        print("\(checks) isolated preset-store checks passed; no real application data touched.")
    }
}
