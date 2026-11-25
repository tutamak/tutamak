import Foundation

/// A light tick on the trackpad the fingers are on, when a dragged window catches on something:
/// its snap preview appears or moves to another zone, or one of its edges starts to hold at a
/// display edge.
///
/// It drives the trackpad's actuator through MultitouchSupport (see `MultitouchPrivate.h`), the way
/// HapticKey and other background utilities do: Tutamak is not the active app while it drags
/// another app's window. Ticks run on their own queue, off the gesture queue.
final class Haptics {
    /// The waveform: a 7 ms pulse, the lightest built-in one in every trackpad's table (6 is the
    /// strongest).
    private let waveform: Int32 = 3
    /// Ticks closer together than this are dropped, so a sweep across the snap grid stays a few
    /// distinct ticks rather than a buzz.
    private let minimumInterval: TimeInterval = 0.06

    private let queue = DispatchQueue(label: "tutamak.haptics", qos: .userInteractive)
    /// Open actuators by device ID, opened on first use and then kept open.
    private var actuators: [UInt64: CFTypeRef] = [:]
    /// Trackpads that could not tick (no actuator); left alone until the trackpads restart.
    private var silent: Set<UInt64> = []
    private var lastTick: TimeInterval = 0

    /// `device` is the trackpad the fingers are on (an `MTDeviceRef`).
    func tick(on device: UnsafeMutableRawPointer?) {
        guard let device else { return }
        let now = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            guard now - lastTick >= minimumInterval else { return }
            lastTick = now
            var id: UInt64 = 0
            guard MTDeviceGetDeviceID(device, &id) == 0, id != 0, !silent.contains(id) else { return }
            if actuate(id) { return }
            // A trackpad that reconnected (Bluetooth) needs a new actuator: open it again, once.
            close(id)
            if !actuate(id) {
                close(id)
                silent.insert(id)
                logger.notice("trackpad \(id, format: .hex) cannot tick; no haptics on it until the trackpads restart")
            }
        }
    }

    /// The trackpads restarted (one was added, removed or reconnected): start over with each.
    func reset() {
        queue.async { [self] in
            for id in Array(actuators.keys) { close(id) }
            silent.removeAll()
        }
    }

    private func actuate(_ id: UInt64) -> Bool {
        guard let actuator = actuator(for: id) else { return false }
        return MTActuatorActuate(actuator, waveform, 0, 0, 0) == 0
    }

    private func actuator(for id: UInt64) -> CFTypeRef? {
        if let open = actuators[id] { return open }
        guard let actuator = MTActuatorCreateFromDeviceID(id), MTActuatorOpen(actuator) == 0 else { return nil }
        actuators[id] = actuator
        return actuator
    }

    private func close(_ id: UInt64) {
        guard let actuator = actuators.removeValue(forKey: id) else { return }
        _ = MTActuatorClose(actuator)
    }
}
