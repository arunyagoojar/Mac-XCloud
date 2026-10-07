//
//  MacIntegration.swift
//  Mac XCloud
//
//  Mac Xcloud in the rest of macOS: "Play Forza Horizon 6 in Mac Xcloud"
//  from Shortcuts, Siri and Spotlight, and recent games in the Dock menu.
//

import AppIntents
import AppKit

// MARK: - Shortcuts, Siri and Spotlight actions

@available(macOS 13.0, *)
struct GameEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Game"
    static var defaultQuery = GameEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        if let art = GameLibrary.artworkURL(for: id) {
            return DisplayRepresentation(title: "\(title)", subtitle: "Xbox Cloud Gaming", image: .init(url: art))
        }
        return DisplayRepresentation(title: "\(title)", subtitle: "Xbox Cloud Gaming")
    }

    init(_ game: RecentGame) {
        id = game.id
        title = game.title.isEmpty ? game.id : game.title
    }
}

/// The games Shortcuts and Siri can start: the ones played on this Mac.
@available(macOS 13.0, *)
struct GameEntityQuery: EntityStringQuery {
    @MainActor private var games: [RecentGame] { BrowserModel.current?.gameLibrary.recent ?? [] }

    func entities(for identifiers: [String]) async throws -> [GameEntity] {
        let games = await MainActor.run { self.games }
        return games.filter { identifiers.contains($0.id) }.map(GameEntity.init)
    }

    func entities(matching string: String) async throws -> [GameEntity] {
        let games = await MainActor.run { self.games }
        let needle = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return games.filter {
            $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle)
        }.map(GameEntity.init)
    }

    func suggestedEntities() async throws -> [GameEntity] {
        await MainActor.run { games.map(GameEntity.init) }
    }
}

@available(macOS 13.0, *)
struct PlayGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Game"
    static var description = IntentDescription("Starts a game you've played in Mac Xcloud.")
    static var openAppWhenRun = true

    @Parameter(title: "Game")
    var game: GameEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$game)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        BrowserModel.current?.play(gameID: game.id)
        return .result()
    }
}

@available(macOS 13.0, *)
struct ResumeLastGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Last Game"
    static var description = IntentDescription("Starts the game you played last in Mac Xcloud.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        BrowserModel.current?.resumeLastGame()
        return .result()
    }
}

@available(macOS 13.0, *)
struct MacXcloudShortcuts: AppShortcutsProvider {
    /// shortTitle and systemImageName are what Spotlight and the Shortcuts
    /// app display from macOS 14 on; providing them also avoids the
    /// `AppShortcut` deprecation. `systemImageName` must be a literal, so the
    /// values are written inline.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayGameIntent(), phrases: [
            "Play \(\.$game) in \(.applicationName)",
            "Start \(\.$game) in \(.applicationName)",
            "Play \(\.$game) with \(.applicationName)",
        ], shortTitle: "Play Game", systemImageName: "gamecontroller")
        AppShortcut(intent: ResumeLastGameIntent(), phrases: [
            "Resume my game in \(.applicationName)",
            "Continue playing in \(.applicationName)",
        ], shortTitle: "Resume Last Game", systemImageName: "arrow.counterclockwise.circle")
    }
}

/// Keeps the spoken "Play <game>" phrases in step with the recent games.
@MainActor
enum AppShortcutsSync {
    static func refresh() {
        if #available(macOS 13.0, *) { MacXcloudShortcuts.updateAppShortcutParameters() }
    }
}

// MARK: - Dock menu

@MainActor
final class DockMenuBuilder: NSObject {
    private weak var browser: BrowserModel?

    init(browser: BrowserModel) {
        self.browser = browser
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        guard let browser else { return menu }
        let games = browser.gameLibrary.recent.prefix(6)
        if games.isEmpty {
            let empty = NSMenuItem(title: "Games you play appear here", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Recent Games", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for game in games {
                let item = NSMenuItem(title: game.title.isEmpty ? game.id : game.title, action: #selector(play(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = game.id
                if let art = GameLibrary.artworkURL(for: game.id), let image = NSImage(contentsOf: art) {
                    image.size = NSSize(width: 16, height: 16)
                    item.image = image
                }
                if browser.isStreaming && browser.currentGameID.uppercased() == game.id { item.state = .on }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let home = NSMenuItem(title: "Xbox Cloud Gaming Home", action: #selector(goHome), keyEquivalent: "")
        home.target = self
        menu.addItem(home)
        return menu
    }

    @objc private func play(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        browser?.play(gameID: id)
    }

    @objc private func goHome() {
        browser?.openMainWindow()
        browser?.loadHome()
    }
}
