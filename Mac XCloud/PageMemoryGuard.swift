//
//  PageMemoryGuard.swift
//  Mac XCloud
//
//  WebKit ends the Xbox page when its process passes a fixed memory limit
//  (8 GB on an 8 GB Mac), and the game stops with "The Xbox web process
//  stopped unexpectedly". During some streams the page's memory climbs by
//  about 160 MB every second from the moment the video starts: graphics
//  memory WebKit holds for the page's video renderer, which it cannot give
//  back under memory pressure. That reaches the limit about 90 seconds in.
//  A healthy stream stays under a gigabyte and does not grow.
//
//  The watch below notices the climb within seconds, long before the limit,
//  so the app can switch the sharpening renderer to a lighter one while the
//  game keeps running.
//

import Darwin
import Foundation

/// Decides, from footprint readings, whether the page is racing toward
/// WebKit's memory limit. Pure, so the contract tests drive it.
struct PageMemoryWatch {
    struct Reading: Equatable {
        var time: TimeInterval
        var megabytes: Double
    }

    /// Below this footprint (MB) nothing is judged: a stream normally sits
    /// between 400 and 900 MB.
    var floorMB: Double = 1500
    /// Growth (MB/s) that only a leak produces. A page that is loading or
    /// starting a stream grows in short bursts, never for seconds on end.
    var leakRateMBps: Double = 40
    /// How long the growth must last.
    var window: TimeInterval = 8

    private(set) var readings: [Reading] = []

    mutating func reset() { readings.removeAll() }

    /// Adds a reading; true when the page has grown at leak speed over the
    /// whole window and is past the floor.
    mutating func add(_ megabytes: Double, at time: TimeInterval) -> Bool {
        guard megabytes.isFinite, time.isFinite else { return false }
        readings.append(Reading(time: time, megabytes: megabytes))
        readings.removeAll { $0.time < time - window }
        guard megabytes >= floorMB, let first = readings.first, time - first.time >= window * 0.75 else { return false }
        // Every step must climb: a single jump (a scene loading) is not a leak.
        let steady = zip(readings, readings.dropFirst()).allSatisfy { $1.megabytes > $0.megabytes }
        return steady && (megabytes - first.megabytes) / (time - first.time) >= leakRateMBps
    }

    /// The lighter Better xCloud renderer to switch to: WebGPU → WebGL,
    /// WebGL → the plain video element. nil when already plain.
    static func lighterRenderer(than renderer: String) -> String? {
        switch renderer {
        case "webgpu": return "webgl2"
        case "webgl2": return "default"
        default: return nil
        }
    }

    /// The app's Sharpening choice for a renderer and Better xCloud's
    /// processing ("cas" or "usm").
    static func pipeline(renderer: String, processing: String) -> String {
        switch renderer {
        case "webgpu": return processing == "usm" ? "webgpu-usm" : "webgpu-cas"
        case "webgl2": return processing == "usm" ? "webgl-usm" : "webgl-cas"
        default: return "native"
        }
    }
}

enum PageProcess {
    /// The memory macOS charges a process (the figure WebKit's limit uses),
    /// in MB; nil if the process is gone.
    static func footprintMB(pid: pid_t) -> Double? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : nil
    }
}
