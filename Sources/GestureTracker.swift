import CoreGraphics
import Foundation

/// A finger touching the trackpad; position is in 0..1 with the origin at the bottom left.
struct TouchPoint {
    let id: Int32
    let position: CGPoint
}

/// Which way the fingers moved in a flick.
enum SwipeDirection: Equatable, CustomStringConvertible {
    case left
    case right
    case up
    case down

    var description: String {
        switch self {
        case .left: "left"
        case .right: "right"
        case .up: "up"
        case .down: "down"
        }
    }
}

/// How far the fingers sit from their centre, in trackpad-width units: the mean horizontal,
/// vertical and straight-line distance. `y` is scaled by the trackpad aspect so both axes are
/// physical distances. Differences of two spreads say how far the fingers opened or closed.
struct Spread: Equatable {
    var x: CGFloat
    var y: CGFloat
    var radial: CGFloat

    static let zero = Spread(x: 0, y: 0, radial: 0)

    init(x: CGFloat, y: CGFloat, radial: CGFloat) {
        self.x = x
        self.y = y
        self.radial = radial
    }

    init(_ points: [CGPoint], aspect: CGFloat) {
        guard !points.isEmpty else {
            self = .zero
            return
        }
        let n = CGFloat(points.count)
        let cx = points.reduce(0) { $0 + $1.x } / n
        let cy = points.reduce(0) { $0 + $1.y } / n
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        var sr: CGFloat = 0
        for p in points {
            let dx = p.x - cx
            let dy = (p.y - cy) * aspect
            sx += abs(dx)
            sy += abs(dy)
            sr += hypot(dx, dy)
        }
        self.init(x: sx / n, y: sy / n, radial: sr / n)
    }

    static func - (a: Spread, b: Spread) -> Spread {
        Spread(x: a.x - b.x, y: a.y - b.y, radial: a.radial - b.radial)
    }
}

enum GestureEvent: Equatable {
    /// A drag began.
    case began
    /// Displacement in normalized trackpad units (y grows upward).
    case moved(CGVector)
    /// The drag ended.
    case ended
    /// A quick flick: sideways is the old "switch desktop" habit, up and down the old Mission
    /// Control and App Exposé. Fires once per touch.
    case swiped(SwipeDirection)
    /// The fingers started spreading or pinching; carries their spread when they landed.
    case resizeBegan(Spread)
    /// How far the fingers have spread (positive) or pinched (negative) since they landed.
    case resized(Spread)
    case resizeEnded
    /// All fingers landed together and lifted without moving. Fires once per touch.
    case tapped
}

/// Extracts the four-finger gestures from raw touch frames. Pure and tested.
///
/// One touch does one thing, decided at the start and held until the hand lifts:
/// - **Drag:** the fingers slide together. With exactly `fingers` fingers down it arms; nothing
///   moves until they have slid `startThreshold`.
/// - **Flick:** the fingers land and immediately sweep fast, sideways (`recognizesSwipes`) or up
///   and down (`recognizesVerticalSwipes`). A start that could be a flick waits until it is ruled
///   out (not in a flick direction, too slow, or the fingers rested first); every other start
///   commits at once.
/// - **Pinch** (`recognizesPinch`): the fingers spread or close more than they slide.
/// - **Tap** (`recognizesTap`): all fingers land together and lift quickly without moving.
///
/// While dragging or resizing, the gesture ends when the finger count stays below `fingers` for
/// `releaseDebounce` seconds, or when every finger lifts; losing a finger for one frame does not
/// end it. Only a whole hand moves a drag: frames with fewer fingers (a hand lifting) move nothing. With too many fingers (a palm, a fifth finger) nothing happens until the count drops.
struct GestureTracker {
    var fingers = 4
    var startThreshold: CGFloat = 0.012
    var releaseDebounce: Double = 0.05
    /// Trackpad height / width, so horizontal and vertical distances are compared physically.
    var aspect: CGFloat = 0.66
    /// No flicks or taps right after a drag or resize ends: lifting and re-landing to carry on
    /// (the clutch) can look like either.
    var clutchWindow: Double = 0.5

    // Flicks. Provisional thresholds; `lastDecision` records real values to tune them.

    /// Sideways flicks.
    var recognizesSwipes = true
    /// Up and down flicks. Off by default: every fast vertical drag start then waits too.
    var recognizesVerticalSwipes = false
    /// A flick covers this much of the trackpad width (a vertical flick the same physical distance)...
    var swipeDistance: CGFloat = 0.08
    /// ...within this long after the fingers land. A start that looks like a flick waits at most this long.
    var swipeWindow: Double = 0.14
    /// Travel along the flick must exceed travel across it by this factor (both physical).
    var swipeAxisRatio: CGFloat = 2
    /// A flick that lifts before reaching `swipeDistance` still counts if it covered this much.
    var swipeDistanceOnLift: CGFloat = 0.03

    // Pinches.

    var recognizesPinch = true
    /// How far the fingers must open or close (mean distance from their centre) to start resizing.
    var pinchThreshold: CGFloat = 0.007
    /// A pinch opens or closes the hand by at least this much relative to how far its centre slides
    /// (both measured physically). Opening the hand around a still thumb slides the centre too
    /// (ratio ≈0.39), while a slide barely changes the spread (logged drags stayed at or under 0.12).
    var pinchRatio: CGFloat = 0.25
    /// A start that could still be either a pinch or a slide is decided as a slide after this much travel.
    var pinchAmbiguousTravel: CGFloat = 0.08

    // Taps.

    var recognizesTap = true
    /// All fingers must land within this long of the first one...
    var tapLandingWindow: Double = 0.08
    /// ...and start lifting within this long, without sliding or spreading.
    var tapMaxDuration: Double = 0.25

    /// What a touch became and why, for tuning.
    struct Decision: Equatable {
        enum Kind: String {
            case drag, swipe, resize, tap, none
        }

        let kind: Kind
        let reason: String
        let travel: CGVector
        let spread: Spread
        let elapsed: Double
    }

    private(set) var lastDecision: Decision?

    private enum Phase { case idle, armed, deciding, dragging, resizing, consumed, blocked }

    private var phase = Phase.idle
    private var last: [Int32: CGPoint] = [:]
    private var travel = CGVector.zero
    private var startSpread = Spread.zero
    private var spreadChange = Spread.zero
    private var lowSince: Double?
    private var landedAt: Double = 0
    private var armedAt: Double = 0
    private var lastGestureEnd = -Double.infinity

    var isDragging: Bool { phase == .dragging }
    var isResizing: Bool { phase == .resizing }
    var isActive: Bool { phase != .idle }
    /// Four fingers are down and the gesture is ours, so scrolling and zooming stay muted.
    var isEngaged: Bool { [.armed, .deciding, .dragging, .resizing, .consumed].contains(phase) }

    mutating func reset() {
        phase = .idle
        last = [:]
        travel = .zero
        spreadChange = .zero
        lowSince = nil
    }

    mutating func process(_ touches: [TouchPoint], at time: Double) -> [GestureEvent] {
        var current: [Int32: CGPoint] = [:]
        for t in touches { current[t.id] = t.position }
        let previous = last
        last = current
        let n = current.count
        let pastClutch = time - lastGestureEnd > clutchWindow

        switch phase {
        case .idle:
            if previous.isEmpty, n > 0 { landedAt = time }
            if n == fingers {
                phase = .armed
                armedAt = time
                travel = .zero
                startSpread = Spread(Array(current.values), aspect: aspect)
                spreadChange = .zero
            } else if n > fingers {
                phase = .blocked
            }
            return []

        case .blocked:
            if n < fingers { phase = .idle }
            return []

        case .consumed:
            // A flick or tap already fired; ignore the rest until the hand is off.
            if n <= 1 { phase = .idle }
            return []

        case .armed:
            if n > fingers {
                record(.none, "more than \(fingers) fingers", at: time)
                phase = .blocked
                return []
            }
            if n < fingers { return liftWhileArmed(at: time, pastClutch: pastClutch) }
            accumulate(from: previous, to: current)
            spreadChange = Spread(Array(current.values), aspect: aspect) - startSpread
            let pinch = abs(spreadChange.radial)
            let moved = length(travel)
            // The spread is physical (y scaled by the aspect), so compare it with the physical slide.
            let pinchLike = recognizesPinch && pinch >= pinchRatio * hypot(travel.dx, travel.dy * aspect)
            if pinchLike, pinch >= pinchThreshold {
                return startResize(at: time)
            }
            guard moved >= startThreshold else { return [] }
            // The fingers are opening or closing while their centre slides: wait until it is
            // clearly one or the other. Ordinary slides are not pinch-like and go on at once.
            if pinchLike, moved < pinchAmbiguousTravel { return [] }
            let flicks = recognizesSwipes || recognizesVerticalSwipes
            guard flicks, pastClutch else {
                return startDrag(at: time, reason: flicks ? "clutch" : "flicks off")
            }
            phase = .deciding
            return decide(at: time)

        case .deciding:
            if n > fingers {
                phase = .blocked
                return []
            }
            if n < fingers { return decideOnLift(at: time) }
            accumulate(from: previous, to: current)
            spreadChange = Spread(Array(current.values), aspect: aspect) - startSpread
            return decide(at: time)

        case .dragging:
            var events: [GestureEvent] = []
            // Only a whole hand moves the window. With fewer fingers the hand is lifting (or one
            // slipped for a frame), and the fingers left behind roll and shift as they leave: that
            // moved a window held at a display edge off it, a few points, after the user had let go.
            if n >= fingers, let d = Geometry.averageDelta(from: previous, to: current), d.dx != 0 || d.dy != 0 {
                events.append(.moved(d))
            }
            if releaseCheck(count: n, at: time) {
                finishGesture(at: time)
                events.append(.ended)
            }
            return events

        case .resizing:
            var events: [GestureEvent] = []
            // The spread only means something with the same number of fingers it started with.
            if n == fingers {
                let change = Spread(Array(current.values), aspect: aspect) - startSpread
                if change != spreadChange {
                    spreadChange = change
                    events.append(.resized(change))
                }
            }
            if releaseCheck(count: n, at: time) {
                finishGesture(at: time)
                events.append(.resizeEnded)
            }
            return events
        }
    }

    // MARK: Deciding

    private enum Axis { case horizontal, vertical }

    private var isHorizontal: Bool {
        abs(travel.dx) >= swipeAxisRatio * abs(travel.dy) * aspect
    }

    private var isVertical: Bool {
        abs(travel.dy) * aspect >= swipeAxisRatio * abs(travel.dx)
    }

    /// The flick the travel so far could still become, if that kind of flick is on.
    private var flickAxis: Axis? {
        if recognizesSwipes, isHorizontal { return .horizontal }
        if recognizesVerticalSwipes, isVertical { return .vertical }
        return nil
    }

    /// How far the fingers went along a flick axis, in trackpad widths. Sideways keeps the overall
    /// length (what the logged flicks were tuned on); up and down is scaled to a physical distance,
    /// so a vertical flick needs as much finger travel as a sideways one.
    private func flickDistance(_ axis: Axis?) -> CGFloat {
        axis == .vertical ? abs(travel.dy) * aspect : length(travel)
    }

    /// Why a start was not a flick: its direction is not one whose flick is on.
    private var notAFlickDirection: String {
        switch (recognizesSwipes, recognizesVerticalSwipes) {
        case (true, true): "diagonal"
        case (false, true): "not vertical"
        default: "not horizontal"
        }
    }

    /// Commits as soon as the answer is clear; returns no events while still undecided.
    private mutating func decide(at time: Double) -> [GestureEvent] {
        let elapsed = time - armedAt
        let axis = flickAxis
        // Wait for a little travel before judging direction; the first frames wobble.
        if length(travel) >= swipeDistance / 3, axis == nil { return startDrag(at: time, reason: notAFlickDirection) }
        let distance = flickDistance(axis)
        if distance >= swipeDistance, let axis {
            return elapsed <= swipeWindow ? swipe(axis, at: time, reason: "fast flick") : startDrag(at: time, reason: "too slow")
        }
        if elapsed > swipeWindow { return startDrag(at: time, reason: "too slow") }
        if elapsed >= swipeWindow / 2, distance < swipeDistance / 4 { return startDrag(at: time, reason: "slow start") }
        return []
    }

    /// The fingers lifted before a decision: a short fast flick still counts, anything else is nothing.
    private mutating func decideOnLift(at time: Double) -> [GestureEvent] {
        if let axis = flickAxis, flickDistance(axis) >= swipeDistanceOnLift, time - armedAt <= swipeWindow {
            return swipe(axis, at: time, reason: "flick lifted early")
        }
        record(.none, "lifted while deciding", at: time)
        phase = .idle
        return []
    }

    /// The fingers lifted before sliding or spreading: a tap if it was quick, together and still.
    private mutating func liftWhileArmed(at time: Double, pastClutch: Bool) -> [GestureEvent] {
        let isTap = recognizesTap && pastClutch
            && armedAt - landedAt <= tapLandingWindow
            && time - armedAt <= tapMaxDuration
            && length(travel) < startThreshold
            && abs(spreadChange.radial) < pinchThreshold / 2
        if isTap {
            record(.tap, "tap", at: time)
            phase = .consumed
            return [.tapped]
        }
        // Logged so a touch that did nothing shows why: a spread short of `pinchThreshold`, a slide
        // short of `startThreshold`, or a finger that lifted early.
        record(.none, "lifted before sliding or spreading", at: time)
        phase = .idle
        return []
    }

    private mutating func swipe(_ axis: Axis, at time: Double, reason: String) -> [GestureEvent] {
        record(.swipe, reason, at: time)
        phase = .consumed
        switch axis {
        case .horizontal: return [.swiped(travel.dx < 0 ? .left : .right)]
        case .vertical: return [.swiped(travel.dy > 0 ? .up : .down)]
        }
    }

    private mutating func startDrag(at time: Double, reason: String) -> [GestureEvent] {
        record(.drag, reason, at: time)
        phase = .dragging
        lowSince = nil
        return [.began, .moved(travel)]
    }

    private mutating func startResize(at time: Double) -> [GestureEvent] {
        record(.resize, spreadChange.radial > 0 ? "spread" : "pinch", at: time)
        phase = .resizing
        lowSince = nil
        return [.resizeBegan(startSpread), .resized(spreadChange)]
    }

    // MARK: Helpers

    /// Whether a drag or resize should end: every finger lifted, or too few for long enough.
    private mutating func releaseCheck(count n: Int, at time: Double) -> Bool {
        if n == 0 { return true }
        guard n < fingers else {
            lowSince = nil
            return false
        }
        let since = lowSince ?? time
        lowSince = since
        return time - since >= releaseDebounce
    }

    private mutating func record(_ kind: Decision.Kind, _ reason: String, at time: Double) {
        lastDecision = Decision(kind: kind, reason: reason, travel: travel, spread: spreadChange, elapsed: time - armedAt)
    }

    private mutating func accumulate(from previous: [Int32: CGPoint], to current: [Int32: CGPoint]) {
        guard let d = Geometry.averageDelta(from: previous, to: current) else { return }
        travel.dx += d.dx
        travel.dy += d.dy
    }

    private func length(_ v: CGVector) -> CGFloat { hypot(v.dx, v.dy) }

    private mutating func finishGesture(at time: Double) {
        phase = .idle
        travel = .zero
        lowSince = nil
        lastGestureEnd = time
    }
}
