//
//  GameSetup.swift
//  Mac XCloud
//
//  One-click setup for a new game. The first time a racing game or a shooter
//  starts, a small banner offers the controller setup that suits it, saved to
//  that game's profile only. Not Now dismisses it for that game; Don't
//  Suggest Again turns suggestions off (Settings › Game Profiles).
//

import SwiftUI

/// The banner at the top of the game window.
struct GameSetupBanner: View {
    let offer: GameSetupOffer
    let onSetUp: () -> Void
    let onNotNow: () -> Void
    let onNever: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: SettingsSymbol.available(offer.kind.symbol))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(LinearGradient(colors: [Color.accentColor.opacity(0.8), Color.accentColor], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up \(offer.title) for \(offer.kind.purpose)?")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(offer.kind.summary + " Saved for this game only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 360, alignment: .leading)
            Menu {
                Button("Don't Suggest Setups", action: onNever)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More options")
            Button("Not Now", action: onNotNow)
                .keyboardShortcut(.cancelAction)
            Button("Set Up", action: onSetUp)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .environment(\.colorScheme, .dark)
        .padding(.top, 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Game setup suggestion")
    }
}
