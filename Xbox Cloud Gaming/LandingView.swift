//
//  LandingView.swift
//  Xbox Cloud Gaming
//
//  Created by Arunya on 02/09/26.
//

import SwiftUI

struct LandingView: View {
    let isSigningIn: Bool
    let onSignIn: () -> Void

    var body: some View {
        ZStack {
            backgroundGlow

            VStack(spacing: 24) {
                Spacer()

                xboxMark

                VStack(spacing: 8) {
                    Text("Xbox Cloud Gaming")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Hundreds of console games, streamed straight to your Mac — no downloads, no installs.")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 430)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: onSignIn) {
                    HStack(spacing: 8) {
                        if isSigningIn {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                        }
                        Text(isSigningIn ? "Waiting for sign-in…" : "Sign in with Microsoft")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 260, height: 46)
                    .background(
                        Capsule().fill(
                            LinearGradient(colors: [Color(red: 0.11, green: 0.60, blue: 0.24),
                                                    Color(red: 0.05, green: 0.40, blue: 0.16)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                    )
                    .shadow(color: Color(red: 0.1, green: 0.6, blue: 0.25).opacity(0.45), radius: 18, y: 6)
                }
                .buttonStyle(.plain)
                .disabled(isSigningIn)
                .keyboardShortcut(.defaultAction)

                Text("A separate sign-in window will open.\nYour session stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(40)
        }
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

    private var xboxMark: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.68, blue: 0.27),
                                              Color(red: 0.06, green: 0.38, blue: 0.16)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 104, height: 104)
                .shadow(color: Color(red: 0.1, green: 0.6, blue: 0.25).opacity(0.55), radius: 26, y: 8)
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}

#Preview {
    LandingView(isSigningIn: false, onSignIn: {})
        .frame(width: 1024, height: 640)
}
