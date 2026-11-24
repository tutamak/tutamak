import Foundation
import IOKit

/// A Swift copy of one finger. It is copied because the C memory is invalid once the callback returns.
struct RawTouch {
    let id: Int32
    let state: Int32
    let x: Float
    let y: Float
    let size: Float
}

/// Reads raw finger frames from the trackpads through MultitouchSupport.
final class Multitouch {
    static let shared = Multitouch()

    /// Called on the framework's own thread; it must return quickly.
    var onFrame: ((UnsafeMutableRawPointer, [RawTouch], Double) -> Void)?

    private(set) var devices: [UnsafeMutableRawPointer] = []
    private var deviceList: CFMutableArray?

    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var onDevicesChanged: (() -> Void)?

    /// Calls `handler` on the main queue whenever a trackpad appears or disappears.
    /// A Bluetooth trackpad that reconnects comes back as a new device object, and the old one
    /// we started never sends another frame, so the devices must be started again.
    func observeDevices(_ handler: @escaping () -> Void) {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        onDevicesChanged = handler
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching("AppleMultitouchDevice"), deviceNotificationCallback, refcon, &iterator
            )
            guard result == KERN_SUCCESS else { continue }
            iterators.append(iterator)
            // Draining arms the notification; the devices present now were already started.
            Self.drain(iterator)
        }
    }

    fileprivate static func drain(_ iterator: io_iterator_t) {
        var object = IOIteratorNext(iterator)
        while object != 0 {
            IOObjectRelease(object)
            object = IOIteratorNext(iterator)
        }
    }

    fileprivate func devicesChanged() {
        onDevicesChanged?()
    }

    /// (Re)starts the connected trackpads and returns how many there are.
    @discardableResult
    func start() -> Int {
        stop()
        // Like Karabiner, we do not take ownership: a small leak on rescan is better
        // than crashing on a device that was released too early.
        guard let list = MTDeviceCreateList()?.takeUnretainedValue() else { return 0 }
        deviceList = list
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            MTRegisterContactFrameCallback(device, contactFrameCallback)
            MTDeviceStart(device, 0)
            devices.append(device)
        }
        return devices.count
    }

    func stop() {
        for device in devices {
            MTUnregisterContactFrameCallback(device, contactFrameCallback)
            MTDeviceStop(device, 0)
        }
        devices = []
        deviceList = nil
    }

    func isBuiltIn(_ device: UnsafeMutableRawPointer) -> Bool {
        MTDeviceIsBuiltIn(device)
    }
}

private let deviceNotificationCallback: IOServiceMatchingCallback = { refcon, iterator in
    Multitouch.drain(iterator)
    guard let refcon else { return }
    Unmanaged<Multitouch>.fromOpaque(refcon).takeUnretainedValue().devicesChanged()
}

private let contactFrameCallback: MTContactCallbackFunction = { device, fingers, count, timestamp, _ in
    guard let device else { return 0 }
    var touches: [RawTouch] = []
    if let fingers, count > 0 {
        touches.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let f = fingers[i]
            touches.append(RawTouch(
                id: Int32(f.identifier),
                state: Int32(f.state),
                x: f.normalized.position.x,
                y: f.normalized.position.y,
                size: f.size
            ))
        }
    }
    Multitouch.shared.onFrame?(device, touches, timestamp)
    return 0
}
