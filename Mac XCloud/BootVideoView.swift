//
//  BootVideoView.swift
//  Mac XCloud
//

import AVFoundation
import SwiftUI

/// Plays the Xbox boot animation stored in Assets.xcassets as a data asset.
/// AVPlayer needs a file URL, so the data is written once to a cache file.
struct BootVideoView: NSViewRepresentable {
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinished: onFinished)
    }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        guard let dataAsset = NSDataAsset(name: "Xbox Series X boot animation - Larry Hryb, formerly known as Xbox's Major Nelson (1080p)"),
              let url = Self.cachedURL(for: dataAsset.data) else {
            context.coordinator.finish()
            return view
        }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        view.playerLayer.player = player
        context.coordinator.observe(item: item)
        player.play()
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {}

    static func dismantleNSView(_ nsView: PlayerContainerView, coordinator: Coordinator) {
        nsView.playerLayer.player?.pause()
        nsView.playerLayer.player = nil
        coordinator.stopObserving()
    }

    private static func cachedURL(for data: Data) -> URL? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let url = directory?.appendingPathComponent("XboxCloudGamingBoot.mp4") else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return nil
            }
        }
        return url
    }

    @MainActor
    final class Coordinator: NSObject {
        private let onFinished: () -> Void
        private var observer: NSObjectProtocol?
        private var hasFinished = false

        init(onFinished: @escaping () -> Void) {
            self.onFinished = onFinished
        }

        func observe(item: AVPlayerItem) {
            observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
        }

        func finish() {
            guard !hasFinished else { return }
            hasFinished = true
            onFinished()
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}

final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
