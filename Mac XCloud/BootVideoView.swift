//
//  BootVideoView.swift
//  Mac XCloud
//

import AVFoundation
import CryptoKit
import SwiftUI

/// Plays the Mac XCloud boot animation stored in Assets.xcassets as a data
/// asset. AVPlayer needs a file URL, so the data is written once to a cache
/// file whose name embeds a content hash — swapping the asset in the catalog
/// can never be shadowed by a stale cache entry.
///
/// When the video ends the player fades to black and `onEnded` fires; the
/// splash view itself stays mounted (the caller overlays a spinner) until the
/// page behind it is ready, then everything fades away together.
struct BootVideoView: NSViewRepresentable {
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEnded: onEnded)
    }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        guard let dataAsset = NSDataAsset(name: "macx animation"),
              let url = Self.cachedURL(for: dataAsset.data) else {
            context.coordinator.finish(fading: false, in: view)
            return view
        }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        view.playerLayer.player = player
        context.coordinator.observe(item: item, in: view)
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
        guard let directory else { return nil }
        let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("MacXBootAnimation-\(hash).mp4")
        // Remove cache files from previous asset revisions.
        let stale = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("MacXBootAnimation-") && directory.appendingPathComponent($0).path != url.path }
        for name in stale {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        // Also clear the unhashed name used by pre-1.3.8 builds.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("MacXBootAnimation.mp4"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("XboxCloudGamingBoot.mp4"))
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
        private let onEnded: () -> Void
        private var observer: NSObjectProtocol?
        private var hasFinished = false

        init(onEnded: @escaping () -> Void) {
            self.onEnded = onEnded
        }

        func observe(item: AVPlayerItem, in view: PlayerContainerView) {
            observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(fading: true, in: view) }
            }
        }

        /// Fades the video out onto the container's black background, then
        /// releases the player so the last frame can never reappear.
        func finish(fading: Bool, in view: PlayerContainerView) {
            guard !hasFinished else { return }
            hasFinished = true
            let layer = view.playerLayer
            layer.player?.pause()
            if fading {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = 0.45
                fade.isRemovedOnCompletion = false
                fade.fillMode = .forwards
                CATransaction.begin()
                CATransaction.setCompletionBlock { layer.player = nil }
                layer.add(fade, forKey: "bootVideoFadeOut")
                layer.opacity = 0
                CATransaction.commit()
            } else {
                layer.player = nil
                layer.opacity = 0
            }
            onEnded()
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
        // Letterbox: keep the whole video visible, centered, on a black field.
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
