//
//  LandingView.swift
//  Xbox Cloud Gaming
//
//  Created by Arunya on 02/09/26.
//

import SwiftUI

enum LandingMode {
    case choose        // profile picker ("Who's playing today?")
    case signingIn     // auth window is open
    case validating    // silently verifying a restored session
}

struct LandingView: View {
    let mode: LandingMode
    let profiles: [PlayerProfile]
    let onPickProfile: (PlayerProfile) -> Void
    let onAddNew: () -> Void
    let onSkip: () -> Void
    var onRemoveProfile: ((PlayerProfile) -> Void)? = nil

    @State private var hoveredProfileID: UUID?
    @State private var hoveredAction: String?

    var body: some View {
        ZStack {
            backgroundGlow

            VStack(spacing: 0) {
                Text(mode == .validating ? "Restoring your session…" : "Who's playing today?")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 64)

                Spacer()

                content
                    .padding(.bottom, 90)
            }
            .padding(.horizontal, 60)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .validating:
            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                Text("Checking your Xbox session")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }

        case .signingIn:
            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                Text("Complete the sign-in in the window that just opened")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }

        case .choose:
            HStack(alignment: .center, spacing: 64) {
                ForEach(profiles) { profile in
                    profileCircle(profile)
                }

                actionCircle(id: "add-new",
                             ringColor: Color(red: 0.30, green: 0.85, blue: 0.35),
                             background: Color.white.opacity(0.08)) {
                    Image(systemName: "plus")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.white)
                } label: {
                    Text("Add new")
                } action: {
                    onAddNew()
                }

                actionCircle(id: "skip",
                             ringColor: .clear,
                             background: Color.white.opacity(0.16)) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.white)
                } label: {
                    Text("Skip sign in")
                } action: {
                    onSkip()
                }
            }
        }
    }

    private func profileCircle(_ profile: PlayerProfile) -> some View {
        let isHovered = hoveredProfileID == profile.id
        return VStack(spacing: 14) {
            Button {
                onPickProfile(profile)
            } label: {
                circleShape(size: 150)
                    .background(circleFill(color: Color.white.opacity(0.16)))
                    .overlay {
                        if let urlString = profile.avatarURL, let url = URL(string: urlString) {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 52))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .frame(width: 138, height: 138)
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 52))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .overlay(
                        Circle().strokeBorder(
                            isHovered ? Color(red: 0.30, green: 0.85, blue: 0.35) : .clear,
                            lineWidth: 3
                        )
                    )
                    .scaleEffect(isHovered ? 1.05 : 1)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .buttonStyle(.plain)
            .onHover { hoveredProfileID = $0 ? profile.id : nil }
            .contextMenu {
                Button("Remove from this Mac", role: .destructive) {
                    onRemoveProfile?(profile)
                }
            }

            Text(profile.gamertag)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 170)
        }
    }

    private func actionCircle(id: String,
                              ringColor: Color,
                              background: Color,
                              @ViewBuilder icon: () -> some View,
                              @ViewBuilder label: () -> some View,
                              action: @escaping () -> Void) -> some View {
        let isHovered = hoveredAction == id
        return VStack(spacing: 14) {
            Button(action: action) {
                circleShape(size: 150)
                    .background(circleFill(color: background))
                    .overlay(Circle().strokeBorder(ringColor, lineWidth: 3).opacity(id == "add-new" ? 1 : 0))
                    .overlay(
                        Circle().strokeBorder(
                            isHovered ? Color.white.opacity(0.7) : .clear,
                            lineWidth: 3
                        )
                    )
                    .overlay { icon() }
                    .scaleEffect(isHovered ? 1.05 : 1)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .buttonStyle(.plain)
            .onHover { hoveredAction = $0 ? id : nil }

            label()
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private func circleShape(size: CGFloat) -> some View {
        Circle()
            .frame(width: size, height: size)
    }

    private func circleFill(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 138, height: 138)
    }

    private var backgroundGlow: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.015, green: 0.035, blue: 0.02), Color.black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.10, green: 0.55, blue: 0.22).opacity(0.50), .clear],
                                     center: .center, startRadius: 0, endRadius: 380))
                .frame(width: 760, height: 760)
                .offset(x: -200, y: -190)
                .blur(radius: 24)

            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.05, green: 0.32, blue: 0.42).opacity(0.38), .clear],
                                     center: .center, startRadius: 0, endRadius: 310))
                .frame(width: 620, height: 620)
                .offset(x: 240, y: 260)
                .blur(radius: 30)

            Circle()
                .strokeBorder(.white.opacity(0.05), lineWidth: 1)
                .frame(width: 460, height: 460)
                .offset(x: 40, y: -40)
        }
        .clipped()
    }
}

#Preview {
    LandingView(mode: .choose,
                profiles: [PlayerProfile(id: UUID(), gamertag: "Arunya", avatarURL: nil)],
                onPickProfile: { _ in },
                onAddNew: {},
                onSkip: {})
        .frame(width: 1024, height: 640)
}
