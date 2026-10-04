//
//  GameLibrary.swift
//  Mac XCloud
//
//  The games played on this Mac, newest first, with what the public Xbox
//  catalog says about them (genre, keyboard & mouse support, box art). It
//  feeds the Dock menu, Spotlight, Shortcuts and the game setup suggestion.
//

import AppKit
import Combine
@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

struct RecentGame: Codable, Identifiable, Equatable, Sendable {
    /// Xbox product ID (e.g. 9NR1R1XWLCNB).
    var id: String
    var title: String
    var lastPlayed: Date
    /// Catalog genre ("Racing & flying", "Shooter"…); nil until looked up.
    var category: String?
    /// The game supports keyboard & mouse on Xbox.
    var keyboardMouse: Bool?
    var catalogCheckedAt: Date?
}

@MainActor
final class GameLibrary: ObservableObject {
    static let maximumGames = 12
    private static let storageKey = "games.recent.v1"
    static let persistedKeys = [storageKey]

    @Published private(set) var recent: [RecentGame] = []
    /// Called after the list changes (Spotlight and Shortcuts follow it).
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private var lookups: [String: Task<RecentGame?, Never>] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let games = try? JSONDecoder().decode([RecentGame].self, from: data) {
            recent = games
        } else {
            seedFromHistory()
        }
    }

    /// First run of this version: start from the games that already have a
    /// game profile, the last played first. Titles come from the catalog.
    private func seedFromHistory() {
        var ids: [String] = []
        if let last = defaults.string(forKey: "xcg.lastPlayedGameID.v1") { ids.append(last.uppercased()) }
        let linked = (defaults.dictionary(forKey: "inputPresets.games.v1") ?? [:]).keys.map { $0.uppercased() }.sorted()
        for id in linked where !ids.contains(id) { ids.append(id) }
        let start = Date().addingTimeInterval(-60)
        recent = ids.filter(Self.isProductID).prefix(Self.maximumGames).enumerated().map { offset, id in
            RecentGame(id: id, title: "", lastPlayed: start.addingTimeInterval(-Double(offset)))
        }
        guard !recent.isEmpty else { return }
        save()
        Task { @MainActor in
            for game in recent { _ = await details(for: game.id) }
        }
    }

    func game(_ id: String) -> RecentGame? { recent.first { $0.id == id } }

    /// Records a game that just started streaming.
    func notePlayed(id: String, title: String) {
        let id = id.uppercased()
        guard Self.isProductID(id) else { return }
        var game = game(id) ?? RecentGame(id: id, title: title, lastPlayed: Date())
        if !title.isEmpty { game.title = title }
        game.lastPlayed = Date()
        recent.removeAll { $0.id == id }
        recent.insert(game, at: 0)
        if recent.count > Self.maximumGames { recent.removeLast(recent.count - Self.maximumGames) }
        save()
        if game.catalogCheckedAt == nil { Task { _ = await details(for: id) } }
    }

    /// The game with its catalog details, looked up once and remembered.
    func details(for id: String) async -> RecentGame? {
        if let known = game(id), known.catalogCheckedAt != nil { return known }
        if let running = lookups[id] { return await running.value }
        let task = Task<RecentGame?, Never> { @MainActor in
            defer { lookups[id] = nil }
            guard let info = await Self.catalogInfo(for: id) else { return game(id) }
            await Self.cacheArtwork(id: id, from: info.artwork)
            guard var game = game(id) else {
                return RecentGame(id: id, title: info.title, lastPlayed: Date(), category: info.category,
                                  keyboardMouse: info.keyboardMouse, catalogCheckedAt: Date())
            }
            if game.title.isEmpty { game.title = info.title }
            game.category = info.category
            game.keyboardMouse = info.keyboardMouse
            game.catalogCheckedAt = Date()
            if let index = recent.firstIndex(where: { $0.id == id }) { recent[index] = game }
            save()
            return game
        }
        lookups[id] = task
        return await task.value
    }

    static func isProductID(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return value.count >= 8 && value.count <= 20 && value.uppercased().unicodeScalars.allSatisfy(allowed.contains)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(recent) { defaults.set(data, forKey: Self.storageKey) }
        indexInSpotlight()
        onChange?()
    }

    // MARK: Catalog

    struct CatalogInfo: Sendable {
        var title: String
        var category: String?
        var keyboardMouse: Bool
        var artwork: URL?
    }

    /// Microsoft's public product catalog (no sign-in, no personal data).
    nonisolated static func catalogInfo(for id: String) async -> CatalogInfo? {
        var components = URLComponents(string: "https://displaycatalog.mp.microsoft.com/v7.0/products")!
        components.queryItems = [URLQueryItem(name: "bigIds", value: id), URLQueryItem(name: "market", value: "US"),
                                 URLQueryItem(name: "languages", value: "en-us")]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let product = (root["Products"] as? [[String: Any]])?.first else { return nil }
        let localized = (product["LocalizedProperties"] as? [[String: Any]])?.first ?? [:]
        let properties = product["Properties"] as? [String: Any] ?? [:]
        let attributes = (properties["Attributes"] as? [[String: Any]] ?? []).compactMap { $0["Name"] as? String }
        let images = localized["Images"] as? [[String: Any]] ?? []
        let preferred = ["BoxArt", "Poster", "Tile"]
        let art = preferred.lazy.compactMap { purpose in images.first { ($0["ImagePurpose"] as? String) == purpose } }.first
        var artwork: URL?
        if var uri = art?["Uri"] as? String {
            if uri.hasPrefix("//") { uri = "https:" + uri }
            artwork = URL(string: uri)
        }
        return CatalogInfo(title: localized["ProductTitle"] as? String ?? "",
                           category: properties["Category"] as? String,
                           keyboardMouse: attributes.contains("ConsoleKeyboardMouse"),
                           artwork: artwork)
    }

    // MARK: Artwork

    nonisolated static var artworkDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Xbox Cloud data/artwork", isDirectory: true)
    }

    nonisolated static func artworkURL(for id: String) -> URL? {
        guard let url = artworkDirectory?.appendingPathComponent("\(id).png"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Keeps a small square copy of the box art for Spotlight and Shortcuts.
    nonisolated private static func cacheArtwork(id: String, from source: URL?) async {
        guard let source, let directory = artworkDirectory else { return }
        var request = URLComponents(url: source, resolvingAgainstBaseURL: false)
        request?.queryItems = [URLQueryItem(name: "w", value: "256"), URLQueryItem(name: "h", value: "256")]
        guard let url = request?.url ?? Optional(source),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return }
        let side: CGFloat = 256
        let thumbnail = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let size = image.size
            let scale = max(side / max(size.width, 1), side / max(size.height, 1))
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            image.draw(in: NSRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
            return true
        }
        guard let tiff = thumbnail.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(id).png"), options: .atomic)
    }

    // MARK: Spotlight

    nonisolated static func spotlightID(_ id: String) -> String { "game:\(id)" }

    /// Recent games appear in Spotlight; choosing one starts it.
    private func indexInSpotlight() {
        let items = recent.map { game -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = game.title.isEmpty ? game.id : game.title
            attributes.displayName = attributes.title
            attributes.contentDescription = "Play in Mac Xcloud"
            attributes.keywords = ["xbox", "cloud", "play", "game"] + (game.category.map { [$0] } ?? [])
            if let art = Self.artworkURL(for: game.id) { attributes.thumbnailURL = art }
            attributes.lastUsedDate = game.lastPlayed
            return CSSearchableItem(uniqueIdentifier: Self.spotlightID(game.id), domainIdentifier: "games", attributeSet: attributes)
        }
        Task { @MainActor in
            let index = CSSearchableIndex.default()
            try? await index.deleteSearchableItems(withDomainIdentifiers: ["games"])
            if !items.isEmpty { try? await index.indexSearchableItems(items) }
        }
    }

    /// The product ID behind a Spotlight result, if it is one of ours.
    nonisolated static func gameID(fromSpotlight activity: NSUserActivity) -> String? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              identifier.hasPrefix("game:") else { return nil }
        return String(identifier.dropFirst("game:".count))
    }
}
