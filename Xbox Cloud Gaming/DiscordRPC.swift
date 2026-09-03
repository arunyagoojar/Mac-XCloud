//
//  DiscordRPC.swift
//  Xbox Cloud Gaming
//
//  Minimal Discord Rich Presence client over Discord's local IPC socket.
//  Requires a Discord application ID (create a free app at
//  discord.com/developers/applications and run:
//  defaults write cc.eu.arunya.Xbox-Cloud-Gaming discordClientId "YOUR_ID")
//

import AppKit

@MainActor
final class DiscordRPC {
    static let shared = DiscordRPC()

    private var writeHandle: FileHandle?
    private var connected = false
    private var lastActivityKey: String?
    private var startedAt: Date?

    private var clientID: String {
        UserDefaults.standard.string(forKey: "discordClientId") ?? ""
    }

    func update(playing: Bool, title: String) {
        let id = clientID
        guard !id.isEmpty else { return }

        if playing {
            let key = title
            if connected && key == lastActivityKey { return }
            if !connectIfNeeded() { return }
            if startedAt == nil { startedAt = Date() }
            lastActivityKey = key
            let activity: [String: Any] = [
                "details": title.isEmpty ? "Playing" : title,
                "state": "Xbox Cloud Gaming on macOS",
                "timestamps": ["start": Int(startedAt!.timeIntervalSince1970)],
                "assets": ["large_text": "Xbox Cloud Gaming"],
                "instance": 1
            ]
            sendFrame(op: 1, payload: [
                "cmd": "SET_ACTIVITY",
                "args": ["pid": ProcessInfo.processInfo.processIdentifier, "activity": activity],
                "nonce": UUID().uuidString
            ])
        } else if connected, lastActivityKey != nil {
            lastActivityKey = nil
            startedAt = nil
            sendFrame(op: 1, payload: [
                "cmd": "SET_ACTIVITY",
                "args": ["pid": ProcessInfo.processInfo.processIdentifier, "activity": NSNull()],
                "nonce": UUID().uuidString
            ])
        }
    }

    private func connectIfNeeded() -> Bool {
        if connected, writeHandle != nil { return true }
        for path in candidateSocketPaths() {
            guard FileManager.default.fileExists(atPath: path),
                  let handle = FileHandle(forWritingAtPath: path) else { continue }
            writeHandle = handle
            connected = true
            sendFrame(op: 0, payload: [
                "v": 1,
                "client_id": clientID,
                "nonce": UUID().uuidString
            ])
            return true
        }
        return false
    }

    private func candidateSocketPaths() -> [String] {
        var paths: [String] = []
        for base in ["/tmp",
                     NSHomeDirectory() + "/Library/Application Support/discord",
                     NSHomeDirectory() + "/Library/Containers/com.hnc.Discord/Data/tmp",
                     NSHomeDirectory() + "/Library/Containers/com.discord.Discord/Data/tmp"] {
            paths += (0...9).map { "\(base)/discord-ipc-\($0)" }
        }
        return paths
    }

    private func sendFrame(op: Int, payload: [String: Any]) {
        guard let handle = writeHandle else { return }
        var payloadData = Data()
        if JSONSerialization.isValidJSONObject(payload),
           let json = try? JSONSerialization.data(withJSONObject: payload) {
            payloadData = json
        }
        var frame = Data()
        var opLE = UInt32(op).littleEndian
        var lengthLE = UInt32(payloadData.count).littleEndian
        withUnsafeBytes(of: &opLE) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &lengthLE) { frame.append(contentsOf: $0) }
        frame.append(payloadData)
        do {
            try handle.write(contentsOf: frame)
        } catch {
            connected = false
            writeHandle = nil
        }
    }
}
