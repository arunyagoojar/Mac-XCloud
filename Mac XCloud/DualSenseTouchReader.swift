import Foundation
import IOKit.hid
import GameController

/// Read-only input reports; never seize the controller or write output effects.
@MainActor final class DualSenseTouchReader {
    private var manager: IOHIDManager?
    private var lastReport = -Double.infinity
    private var points: [ControllerTouchPoint] = []
    func start() {
        guard manager == nil else { return }
        let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = [0x0ce6, 0x0df2].map { product in
            [kIOHIDVendorIDKey: 0x054c, kIOHIDProductIDKey: product,
             kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 5]
        }
        IOHIDManagerSetDeviceMatchingMultiple(hid, matches as CFArray)
        IOHIDManagerRegisterInputReportCallback(hid, { context, result, _, type, _, bytes, count in
            guard let context, result == kIOReturnSuccess, type == kIOHIDReportTypeInput else { return }
            MainActor.assumeIsolated {
                let reader = Unmanaged<DualSenseTouchReader>.fromOpaque(context).takeUnretainedValue()
                guard let manager = reader.manager, let devices = IOHIDManagerCopyDevices(manager), CFSetGetCount(devices) == 1,
                      GCController.controllers().count == 1,
                      let decoded = DualSenseTouchPacket.decode(Array(UnsafeBufferPointer(start: bytes, count: count))) else { return }
                reader.points = decoded
                reader.lastReport = ProcessInfo.processInfo.systemUptime
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }
        manager = hid
    }
    func stop() {
        guard let manager else { return }
        IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil; points = []; lastReport = -.infinity
    }
    var hasReports: Bool { !points.isEmpty }
    var reportTime: Double { lastReport }
    deinit {
        if let manager {
            IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
    func point(_ index: Int) -> ControllerTouchPoint? {
        guard ProcessInfo.processInfo.systemUptime - lastReport < 0.1, points.indices.contains(index) else { return nil }
        return points[index]
    }
}
