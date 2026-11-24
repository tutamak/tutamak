/// Decides whether a scroll event should be muted. Pure and tested.
///
/// With macOS's four-finger gestures off, a four-finger slide reaches the app underneath
/// as an ordinary scroll. macOS sends scrolls as phased sequences: mayBegin/began → changed… → ended,
/// then momentum events once the fingers lift. If four fingers engage at any point of a sequence,
/// the rest of the sequence and its momentum are muted too; muting ends when a new sequence
/// (or a mouse wheel) starts.
///
/// A sequence that starts within `tailWindow` of the four fingers letting go is not new, though:
/// as a fast hand lifts, macOS restarts the scroll (mayBegin or began, logged up to ~100 ms after
/// the gesture was decided), and when a flick opens Mission Control the Dock sends the scroll again.
/// Those restarts carry the hand's momentum, hundreds to thousands of points, so they stay muted
/// with it. The cost of a wider window: a real scroll whose first event falls inside it stays
/// muted to its end, because nothing later in its sequence releases the mute.
struct ScrollMuter {
    /// `scrollPhase` values (same as NSEvent.Phase).
    static let phaseBegan: Int64 = 1
    static let phaseMayBegin: Int64 = 128

    /// Muting is released this many seconds after the last muted event, no matter what.
    var timeout: Double = 3
    /// A sequence starting this soon after the four fingers let go is the gesture's tail.
    /// A hand cannot lift and start a new scroll this fast.
    var tailWindow: Double = 0.3

    private(set) var muting = false
    private var lastMuted: Double = 0

    /// Whether the event starts a scroll sequence (or is a mouse wheel, which has no phase).
    static func startsSequence(phase: Int64, momentum: Int64) -> Bool {
        phase == phaseBegan || phase == phaseMayBegin || (phase == 0 && momentum == 0)
    }

    /// `disengagedAt`: when four fingers last stopped being engaged (same clock as `time`).
    mutating func shouldMute(engaged: Bool, disengagedAt: Double, phase: Int64, momentum: Int64, at time: Double) -> Bool {
        if engaged {
            muting = true
        } else if muting {
            let startsNew = Self.startsSequence(phase: phase, momentum: momentum) && time - disengagedAt >= tailWindow
            if startsNew || time - lastMuted > timeout {
                muting = false
            }
        }
        if muting { lastMuted = time }
        return muting
    }
}
