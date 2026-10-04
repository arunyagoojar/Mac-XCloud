//
//  GameSetupKind.swift
//  Mac XCloud
//
//  Which setup suits a new game, and what it changes. The banner that
//  offers it is in GameSetup.swift.
//

import Foundation

enum GameSetupKind: String, Equatable {
    case racing, shooter

    /// A setup for the catalog genre, if there is a sensible one.
    static func suggested(category: String?, title: String) -> GameSetupKind? {
        let genre = (category ?? "").lowercased()
        let name = title.lowercased()
        if genre.contains("racing") {
            // "Racing & flying" also holds flight games; a wheel suits only cars.
            let flying = ["flight", "pilot", "sky", "ace combat", "air "].contains { name.contains($0) }
            return flying ? nil : .racing
        }
        if genre.contains("shooter") { return .shooter }
        return nil
    }

    var symbol: String {
        switch self {
        case .racing: return "steeringwheel"
        case .shooter: return "scope"
        }
    }

    var summary: String {
        switch self {
        case .racing: return "Steer by turning the controller, with pedal-feel triggers."
        case .shooter: return "Aim by moving the controller, with a crisp trigger break."
        }
    }

    var purpose: String {
        switch self {
        case .racing: return "racing"
        case .shooter: return "aiming"
        }
    }

    /// The setup itself: only what this kind of game needs changes.
    func apply(to settings: inout ControllerSettings) {
        var e = settings.enhancements ?? ControllerEnhancements()
        switch self {
        case .racing:
            e.setGyroMode(.steering)
            settings.adaptiveTriggers.select(.brake, for: .left)
            settings.adaptiveTriggers.select(.accelerator, for: .right)
        case .shooter:
            e.setGyroMode(.aiming)
            e.gyroActivation = .always
            settings.adaptiveTriggers.select(.softSpring, for: .left)
            settings.adaptiveTriggers.select(.pistol, for: .right)
        }
        settings.enhancements = e
    }
}

struct GameSetupOffer: Equatable, Identifiable {
    let id = UUID()
    let gameID: String
    let title: String
    let kind: GameSetupKind
}

enum GameSetupPreferences {
    private static let key = "games.setupSuggestions.v1"
    static var suggestionsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static let persistedKeys = [key]
}
