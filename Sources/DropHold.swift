import CoreGraphics

/// Decides when a window released over the snap grid drops into its zone. Pure and tested.
///
/// Lifting the fingers is also how a long drag carries on (the clutch: lift, put them back, keep
/// sliding), and dropping the window into a zone halfway across the screen would be wrong. A hand
/// that had settled when it lifted meant to drop, so the window drops at once. A hand still sliding
/// may be about to come back, so the drop waits `clutchWait`; fingers landing in that time hold it
/// until they either drag (the drop is cancelled) or lift again (the window drops).
struct DropHold {
    /// Lifting while sliding at least this fast (trackpad widths per second) looks like the clutch.
    var clutchSpeed: CGFloat = 0.2
    /// How long a drop waits for the fingers to come back. Logged clutches landed 340–420 ms after
    /// the release.
    var clutchWait: Double = 0.6

    enum Action: Equatable {
        case drop
        /// Wait this long (s), then call `expired()`.
        case wait(Double)
        /// The fingers grabbed again; a new drag shows its own preview, anything else hides it.
        case cancel(keepPreview: Bool)
    }

    private enum Phase { case none, waiting, held }

    private var phase = Phase.none

    var isPending: Bool { phase != .none }
    var isHeld: Bool { phase == .held }

    /// The fingers lifted over a grid zone while sliding at `speed` (trackpad widths per second).
    mutating func released(speed: CGFloat) -> Action {
        if speed < clutchSpeed {
            phase = .none
            return .drop
        }
        phase = .waiting
        return .wait(clutchWait)
    }

    /// Every touch frame while a drop is pending. `engaged`: four fingers are down; `dragBegan` /
    /// `otherGesture`: they started a drag, or something else (a pinch).
    mutating func frame(engaged: Bool, dragBegan: Bool, otherGesture: Bool) -> Action? {
        guard phase != .none else { return nil }
        if dragBegan || otherGesture {
            phase = .none
            return .cancel(keepPreview: dragBegan)
        }
        if engaged {
            phase = .held
            return nil
        }
        if phase == .held {
            phase = .none
            return .drop
        }
        return nil
    }

    /// The wait ran out. Fingers that came back keep the drop on hold.
    mutating func expired() -> Action? {
        guard phase == .waiting else { return nil }
        phase = .none
        return .drop
    }

    mutating func reset() {
        phase = .none
    }
}
