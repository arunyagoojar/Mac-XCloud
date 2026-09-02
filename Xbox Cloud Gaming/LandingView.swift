//
//  LandingView.swift
//  Xbox Cloud Gaming
//
//  Created by Arunya on 02/09/26.
//

import Combine
import GameController
import SwiftUI

enum LandingMode {
    case choose        // profile picker ("Who's playing today?")
    case signingIn     // auth window is open
    case validating    // silently verifying a restored session
}

/// Drives focus on the profile picker from a game controller: left/right on
/// the d-pad or stick moves focus, A activates. Polled (rather than handlers)
/// so any controller works without per-controller setup.
@MainActor
final class LandingFocusController: ObservableObject {
    @Published var focusIndex = 0

    private var actions: [() -> Void] = []
    private var timer: Timer?
    private var heldDirection = 0
    private var wasAPressed = false

    func bind(actions: [() -> Void], initialFocus: Int) {
        self.actions = actions
        focusIndex = min(max(initialFocus, 0), max(actions.count - 1, 0))
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollControllers() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        heldDirection = 0
        wasAPressed = false
    }

    private func pollControllers() {
        for controller in GCController.controllers() {
            guard let pad = controller.extendedGamepad else { continue }

            var direction = 0
            if pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value < -0.55 { direction = -1 }
            if pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value > 0.55 { direction = 1 }

            // Only step once per push, not continuously while held.
            if direction != 0, heldDirection == 0 {
                focusIndex = min(max(focusIndex + direction, 0), actions.count - 1)
            }
            heldDirection = direction

            if pad.buttonA.isPressed, !wasAPressed, actions.indices.contains(focusIndex) {
                actions[focusIndex]()
            }
            wasAPressed = pad.buttonA.isPressed
        }
    }
}

struct LandingView: View {
    let mode: LandingMode
    let profiles: [PlayerProfile]
    var currentProfileID: UUID? = nil
    let onPickProfile: (PlayerProfile) -> Void
    let onAddNew: () -> Void
    let onSkip: () -> Void
    var onRemoveProfile: ((PlayerProfile) -> Void)? = nil

    @StateObject private var focus = LandingFocusController()

    var body: some View {
        ZStack {
            backgroundGlow

            VStack(spacing: 0) {
                Text(mode == .validating ? "Restoring your session…" : "Who's playing today?")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 56)

                Spacer(minLength: 24)
                content
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 60)
        }
        .onAppear(perform: bindFocus)
        .onDisappear { focus.stop() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .validating:
            VStack(spacing: 18) {
                ProgressView().controlSize(.large)
                Text("Checking your Xbox session")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }

        case .signingIn:
            VStack(spacing: 18) {
                ProgressView().controlSize(.large)
                Text("Complete the sign-in in the window that just opened")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }

        case .choose:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 56) {
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                        profileCircle(profile, index: index)
                    }
                    actionCircle(id: "add-new", index: profiles.count,
                                 icon: "plus", label: "Add new", action: onAddNew)
                    actionCircle(id: "skip", index: profiles.count + 1,
                                 icon: "person.crop.circle.badge.xmark", label: "Skip sign in", action: onSkip)
                }
                .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Circles

    private func profileCircle(_ profile: PlayerProfile, index: Int) -> some View {
        let isCurrent = profile.id == currentProfileID
        let isFocused = focus.focusIndex == index

        return VStack(spacing: 16) {
            Button {
                onPickProfile(profile)
            } label: {
                avatarContent(for: profile)
                    .frame(width: avatarBase, height: avatarBase)
                    .scaleEffect(avatarScale(isCurrent: isCurrent, isFocused: isFocused))
                    .animation(.easeInOut(duration: 0.18), value: focus.focusIndex)
                    .overlay(
                        Circle()
                            .strokeBorder(focusRingColor(isFocused: isFocused), lineWidth: 3)
                            .frame(width: avatarBase, height: avatarBase)
                            .scaleEffect(avatarScale(isCurrent: isCurrent, isFocused: isFocused))
                    )
            }
            .buttonStyle(.plain)

            Text(profile.gamertag)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(isFocused ? .white : .white.opacity(0.7))
                .lineLimit(1)
                .frame(maxWidth: 180)
        }
        .contextMenu {
            Button("Remove from this Mac", role: .destructive) {
                onRemoveProfile?(profile)
            }
        }
    }

    private func actionCircle(id: String, index: Int,
                              icon: String, label: String,
                              action: @escaping () -> Void) -> some View {
        let isPrimary = id == "add-new"   // Sign-in entry sits bigger, like the current profile.
        let isFocused = focus.focusIndex == index

        return VStack(spacing: 16) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(isFocused ? 0.09 : 0.05))
                    Circle()
                        .strokeBorder(id == "add-new"
                                      ? Color(red: 0.30, green: 0.85, blue: 0.35).opacity(isFocused ? 1 : 0.45)
                                      : .white.opacity(0.15),
                                      lineWidth: id == "add-new" ? 3 : 1.5)
                    Image(systemName: icon)
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: avatarBase, height: avatarBase)
                .scaleEffect(avatarScale(isCurrent: isPrimary, isFocused: isFocused))
                .animation(.easeInOut(duration: 0.18), value: focus.focusIndex)
            }
            .buttonStyle(.plain)

            Text(label)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(isFocused ? .white : .white.opacity(0.7))
        }
    }

    private func avatarContent(for profile: PlayerProfile) -> some View {
        ZStack {
            Circle().fill(.white.opacity(0.05))
            if let urlString = profile.avatarURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 132, height: 132)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    // MARK: - Sizing

    private let avatarBase: CGFloat = 148

    /// The focused circle grows (Xbox-style), and the current profile / sign-in
    /// start from a slightly larger base than the rest.
    private func avatarScale(isCurrent: Bool, isFocused: Bool) -> CGFloat {
        (isCurrent ? 1.08 : 1.0) * (isFocused ? 1.14 : 1.0)
    }

    private func focusRingColor(isFocused: Bool) -> Color {
        isFocused ? Color(red: 0.30, green: 0.85, blue: 0.35) : .clear
    }

    // MARK: - Focus wiring

    private func bindFocus() {
        guard mode == .choose else { return }
        var actions: [() -> Void] = profiles.map { profile in { onPickProfile(profile) } }
        actions.append(onAddNew)
        actions.append(onSkip)

        let initialFocus = profiles.firstIndex { $0.id == currentProfileID } ?? 0
        focus.bind(actions: actions, initialFocus: initialFocus)
        focus.start()
    }

    // MARK: - Background

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
