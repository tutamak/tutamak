import CoreGraphics
import Foundation
import os

/// Mutes the scrolling that reaches the app underneath while four fingers are engaged.
///
/// Scroll events are not dropped; their deltas are zeroed, so the app never sees a half-finished
/// scroll sequence, only one that does not move. The event tap runs on its own thread so input
/// does not stall while the main thread is busy.
///
/// It also watches the gesture event types a pinch could leak as (zoom, rotate, swipe) but only
/// logs which ones show up while engaged; they pass through untouched. Some of these types also
/// carry the Dock's own gestures, so nothing is muted until a leak has actually been seen.
final class ScrollBlocker {
    /// Event types that carry trackpad gestures (and, for some, the Dock's).
    private static let gestureTypes: [UInt32] = [18, 29, 30, 31, 32]

    private struct Engagement {
        var engaged = false
        /// When four fingers last stopped being engaged (system uptime, the tap's clock).
        var endedAt = -Double.infinity
    }

    private let engagement = OSAllocatedUnfairLock(initialState: Engagement())
    /// Used only on the tap thread.
    private var muter = ScrollMuter()
    private var gestureTypesWhileEngaged = Set<UInt32>()
    private var tap: CFMachPort?
    /// Used only on the main thread.
    private(set) var isRunning = false

    /// Written from the gesture queue on every frame, read by the tap.
    var engaged: Bool {
        get { engagement.withLock { $0.engaged } }
        set {
            let now = ProcessInfo.processInfo.systemUptime
            engagement.withLock { state in
                if state.engaged, !newValue { state.endedAt = now }
                state.engaged = newValue
            }
        }
    }

    /// The tap cannot be created without Accessibility permission, so this returns `false`
    /// until permission is granted; the caller retries.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        let mask = Self.gestureTypes.reduce(CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)) {
            $0 | CGEventMask(1) << CGEventMask($1)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "local.tutamak.scroll"
        thread.qualityOfService = .userInteractive
        thread.start()
        isRunning = true
        logger.info("scroll blocker started")
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let state = engagement.withLock { $0 }
        if Self.gestureTypes.contains(type.rawValue) {
            if state.engaged {
                gestureTypesWhileEngaged.insert(type.rawValue)
            } else if !gestureTypesWhileEngaged.isEmpty {
                let types = gestureTypesWhileEngaged.sorted().map(String.init).joined(separator: ", ")
                logger.info("gesture event types seen while engaged: \(types, privacy: .public)")
                gestureTypesWhileEngaged.removeAll()
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let now = ProcessInfo.processInfo.systemUptime
        let wasMuting = muter.muting
        let mute = muter.shouldMute(
            engaged: state.engaged, disengagedAt: state.endedAt, phase: phase, momentum: momentum, at: now
        )
        if mute {
            if !wasMuting { logger.notice("muting scroll (phase \(phase), momentum \(momentum))") }
            if !state.engaged, ScrollMuter.startsSequence(phase: phase, momentum: momentum) {
                let ms = Int(((now - state.endedAt) * 1000).rounded())
                logger.notice("kept muting a scroll that restarted \(ms) ms after the gesture ended (phase \(phase))")
            }
            for field: CGEventField in [
                .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
                .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
            ] {
                event.setIntegerValueField(field, value: 0)
            }
            for field: CGEventField in [
                .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3,
            ] {
                event.setDoubleValueField(field, value: 0)
            }
        } else if wasMuting {
            let ms = Int(((now - state.endedAt) * 1000).rounded())
            logger.notice("scroll released \(ms) ms after the gesture ended (phase \(phase), momentum \(momentum))")
        }
        return Unmanaged.passUnretained(event)
    }
}

private let scrollTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ScrollBlocker>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}
