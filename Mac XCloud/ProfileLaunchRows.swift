//
//  ProfileLaunchRows.swift
//  Mac XCloud
//
//  Native entry points for Better xCloud profile managers and the bundled
//  forced-native-MKB game list.
//

import SwiftUI

struct ProfileLaunchButton: View {
    @EnvironmentObject private var browser: BrowserModel
    let kind: ProfileKind
    let title: String
    let note: String

    var body: some View {
        Button {
            browser.openProfileEditor(kind)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ForcedMKBPicker: View {
    @ObservedObject var model: SettingsModel
    @State private var search = ""

    private var games: [(String, String)] {
        let all = ForcedMKBGameList.games.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        guard !search.isEmpty else { return all }
        return all.filter { $0.value.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search games", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(games, id: \.0) { id, name in
                        Toggle(name, isOn: Binding(
                            get: { model.forcedNativeMKBGames.contains(id) },
                            set: { _ in model.toggleForcedNativeMKBGame(id) }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .padding()
        .frame(width: 420, height: 430)
    }
}

enum ForcedMKBGameList {
    static let games: [String: String] = {
        guard let url = Bundle.main.url(forResource: "native-mkb-games", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let games = root["data"] as? [String: String] else { return [:] }
        return games
    }()
}
