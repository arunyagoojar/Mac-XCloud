//
//  LoadingViews.swift
//  Mac XCloud
//
//  Reusable presentation and state types for browser loading.
//

import AppKit
import SwiftUI

/// The user-visible lifecycle of the browser surface.
enum BrowserLoadPhase: Equatable {
    /// The first page has not presented usable content yet.
    case initialLoading

    /// The browser is displaying usable content and is idle.
    case ready

    /// Usable content exists while a later navigation is in progress.
    case subsequentLoading

    /// Navigation stopped because of a persistent failure.
    case failed(BrowserLoadFailure)

    var isLoading: Bool {
        switch self {
        case .initialLoading, .subsequentLoading:
            return true
        case .ready, .failed:
            return false
        }
    }
}

/// Stable, display-ready information captured when a browser navigation fails.
/// Keeping strings and metadata here prevents an ephemeral `Error` from being
/// lost while the failure presentation remains on screen.
struct BrowserLoadFailure: Equatable, Identifiable {
    let id: UUID
    let title: String
    let message: String
    let recoverySuggestion: String?
    let technicalDetails: String?
    let failingURL: URL?
    let errorDomain: String?
    let errorCode: Int?

    init(
        id: UUID = UUID(),
        title: String = "Unable to Connect",
        message: String,
        recoverySuggestion: String? = "Check your internet connection, then try again.",
        technicalDetails: String? = nil,
        failingURL: URL? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.technicalDetails = technicalDetails
        self.failingURL = failingURL
        self.errorDomain = errorDomain
        self.errorCode = errorCode
    }

    init(
        error: any Error,
        title: String = "Unable to Connect",
        recoverySuggestion: String? = "Check your internet connection, then try again.",
        failingURL: URL? = nil
    ) {
        let nsError = error as NSError
        self.init(
            title: title,
            message: nsError.localizedDescription,
            recoverySuggestion: recoverySuggestion,
            technicalDetails: nsError.localizedFailureReason,
            failingURL: failingURL,
            errorDomain: nsError.domain,
            errorCode: nsError.code
        )
    }
}

/// Persistent full-window error state with recovery actions.
struct ConnectionIssueView: View {
    let failure: BrowserLoadFailure
    let onRetry: () -> Void
    let onQuit: (() -> Void)?
    @State private var showDetails = false

    init(
        failure: BrowserLoadFailure,
        onRetry: @escaping () -> Void,
        onQuit: (() -> Void)? = nil
    ) {
        self.failure = failure
        self.onRetry = onRetry
        self.onQuit = onQuit
    }

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.055, blue: 0.035)

            RadialGradient(
                colors: [Color(red: 0.04, green: 0.32, blue: 0.10).opacity(0.42), .clear],
                center: .top,
                startRadius: 20,
                endRadius: 520
            )

            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white, Color.green)
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text(failure.title)
                            .font(.system(size: 25, weight: .semibold, design: .rounded))

                        Text(failure.message)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        if let recoverySuggestion = failure.recoverySuggestion,
                           !recoverySuggestion.isEmpty {
                            Text(recoverySuggestion)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if hasDetails {
                        VStack(spacing: 10) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { showDetails.toggle() }
                            } label: {
                                Label(showDetails ? "Hide Details" : "Show Details",
                                      systemImage: showDetails ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            if showDetails { detailsPanel.transition(.opacity) }
                        }
                    }

                    HStack(spacing: 12) {
                        if let onQuit {
                            Button("Quit", action: onQuit)
                                .buttonStyle(.bordered)
                                .keyboardShortcut("q", modifiers: .command)
                        }

                        Button("Retry", action: onRetry)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 40)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea()
        // The backdrop is always dark; keep the text legible in Light Mode.
        .environment(\.colorScheme, .dark)
    }

    private var hasDetails: Bool {
        failure.failingURL != nil
            || failure.technicalDetails?.isEmpty == false
            || failure.errorDomain != nil
            || failure.errorCode != nil
    }

    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Connection details")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let url = failure.failingURL {
                detailRow(label: "Address", value: url.absoluteString)
            }

            if let technicalDetails = failure.technicalDetails,
               !technicalDetails.isEmpty {
                detailRow(label: "Details", value: technicalDetails)
            }

            if failure.errorDomain != nil || failure.errorCode != nil {
                let domain = failure.errorDomain ?? "Unknown"
                let code = failure.errorCode.map(String.init) ?? "Unknown"
                detailRow(label: "Error", value: "\(domain) (\(code))")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1))
        }
        .textSelection(.enabled)
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(verbatim: value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A lightweight navigation-progress badge intended for a bottom-right overlay.
struct MinimalLoadingIndicator: View {
    var label = "Loading"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)

            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.13))
        }
        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
