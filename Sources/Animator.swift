import AppKit
import QuartzCore

/// Moves and resizes the grabbed window once per display refresh instead of once per trackpad frame.
///
/// Trackpad frames (about 67 a second) do not line up with the display's 60 or 120 Hz, so updating on
/// every frame moves the window by uneven steps. Instead, a short follower runs at the display rate
/// toward the latest target, which evens the steps out; the cursor stays on the same spot of the
/// window. Snapping, maximizing and restoring are animated the same way. Main thread only.
final class WindowAnimator: NSObject {
    /// Time constant of the follower (s): how quickly the shown frame catches up with the fingers.
    private let followTime: Double = 0.016
    /// Length of snap, maximize and restore animations (s).
    private let animationDuration: Double = 0.2

    var animatesSnapping = true

    private let mover: WindowMover
    private let eventSource: CGEventSource?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var mode = Mode.idle
    private var updates = 0

    // Moving
    private var target = CGPoint.zero
    private var shown = CGPoint.zero
    private var band = DeadBand()

    // Resizing
    private var targetFrame = CGRect.zero
    private var shownFrame = CGRect.zero
    private var appliedFrame = CGRect.zero

    private enum Mode {
        case idle
        case move(TargetWindow, grab: CGVector, releasing: Bool)
        case resize(TargetWindow, anchor: CGPoint, cursorSpot: CGPoint, releasing: Bool)
        case animate(TargetWindow, from: CGRect, to: CGRect, start: CFTimeInterval?, label: String,
                     completion: ((CGRect) -> Void)?)
    }

    init(mover: WindowMover) {
        self.mover = mover
        eventSource = CGEventSource(stateID: .hidSystemState)
        // Do not suppress real mouse events after we move the cursor.
        eventSource?.localEventsSuppressionInterval = 0
        super.init()
    }

    // MARK: Moving

    /// Starts following a newly grabbed window. Cancels anything still in flight.
    func follow(_ window: TargetWindow, grab: CGVector) {
        start(fresh: true)
        mode = .move(window, grab: grab, releasing: false)
        target = window.frame.origin
        shown = window.frame.origin
        band.reset()
        _ = band.update(shown)
    }

    /// Where the window's origin should be (CG/AX coordinates).
    func setTarget(_ origin: CGPoint) {
        target = origin
    }

    /// Animates the window being moved into `frame`.
    func snap(to frame: CGRect, completion: ((CGRect) -> Void)? = nil) {
        guard case .move(let window, _, _) = mode else { return }
        let from = CGRect(origin: rounded(shown), size: window.frame.size)
        animate(window, from: from, to: frame, label: "snapped", completion: completion, fresh: false)
    }

    // MARK: Resizing

    /// Starts resizing a window live. `anchor` stays put (0 = min edge, 1 = max edge, 0.5 = centre);
    /// the cursor stays at `cursorSpot`, a fraction of the window's size from its origin.
    func resize(_ window: TargetWindow, anchor: CGPoint, cursorSpot: CGPoint) {
        start(fresh: true)
        mode = .resize(window, anchor: anchor, cursorSpot: cursorSpot, releasing: false)
        targetFrame = window.frame
        shownFrame = window.frame
        appliedFrame = window.frame
    }

    func setTarget(frame: CGRect) {
        targetFrame = frame
    }

    // MARK: Both

    /// The fingers lifted: catch up with the last target, then stop.
    func release() {
        switch mode {
        case .move(let window, let grab, _):
            mode = .move(window, grab: grab, releasing: true)
        case .resize(let window, let anchor, let spot, _):
            mode = .resize(window, anchor: anchor, cursorSpot: spot, releasing: true)
        default:
            break
        }
    }

    /// Animates a window between two frames (maximize, restore); works from idle.
    func animate(_ window: TargetWindow, from: CGRect, to: CGRect, label: String, completion: ((CGRect) -> Void)? = nil) {
        animate(window, from: from, to: to, label: label, completion: completion, fresh: true)
    }

    private func animate(
        _ window: TargetWindow, from: CGRect, to: CGRect, label: String, completion: ((CGRect) -> Void)?, fresh: Bool
    ) {
        if fresh { start(fresh: true) }
        guard animatesSnapping else {
            mover.setFrame(window, to, completion: completion)
            finish(outcome: label)
            return
        }
        mode = .animate(window, from: from, to: to, start: nil, label: label, completion: completion)
        startLink()
    }

    // MARK: Display link

    /// Begins a new piece of work; whatever was in flight is logged as interrupted.
    private func start(fresh: Bool) {
        if case .idle = mode {} else { logStats(outcome: "interrupted") }
        if fresh {
            updates = 0
            mover.resetStats()
        }
        startLink()
    }

    private func startLink() {
        lastTick = nil
        if link != nil { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = max(0.001, now - (lastTick ?? now - link.duration))
        lastTick = now
        let k = 1 - exp(-dt / followTime)

        switch mode {
        case .idle:
            stopLink()

        case .move(let window, let grab, let releasing):
            shown.x += (target.x - shown.x) * k
            shown.y += (target.y - shown.y) * k
            let settled = hypot(target.x - shown.x, target.y - shown.y) < 0.5
            if releasing, settled {
                shown = target
                place(window, at: rounded(target), cursor: CGPoint(x: target.x + grab.dx, y: target.y + grab.dy))
                finish(outcome: "released")
            } else if let origin = band.update(shown) ?? (settled ? band.settle(target) : nil) {
                place(window, at: origin, cursor: CGPoint(x: origin.x + grab.dx, y: origin.y + grab.dy))
            }

        case .resize(let window, let anchor, let spot, let releasing):
            shownFrame = approach(shownFrame, targetFrame, k)
            if releasing, difference(shownFrame, targetFrame) < 0.5 {
                mover.setFrame(window, rounded(targetFrame), anchor: anchor)
                finish(outcome: "resized")
                return
            }
            let frame = rounded(shownFrame)
            guard difference(frame, appliedFrame) >= 1 else { return }
            appliedFrame = frame
            mover.resize(window.element, to: frame, anchor: anchor)
            updates += 1
            postCursor(CGPoint(x: frame.minX + spot.x * frame.width, y: frame.minY + spot.y * frame.height))

        case .animate(let window, let from, let to, let start, let label, let completion):
            let begin = start ?? now
            if start == nil {
                mode = .animate(window, from: from, to: to, start: now, label: label, completion: completion)
            }
            let progress = min(1, (now - begin) / animationDuration)
            if progress >= 1 {
                mover.setFrame(window, to, completion: completion)
                finish(outcome: label)
                return
            }
            let e = 1 - pow(1 - progress, 3) // ease out
            mover.resize(window.element, to: rounded(interpolate(from, to, e)))
            updates += 1
        }
    }

    private func place(_ window: TargetWindow, at origin: CGPoint, cursor: CGPoint) {
        mover.move(window.element, to: origin)
        updates += 1
        postCursor(cursor)
    }

    private func postCursor(_ point: CGPoint) {
        CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func finish(outcome: String) {
        logStats(outcome: outcome)
        mode = .idle
        stopLink()
    }

    private func logStats(outcome: String) {
        let slowest = mover.slowestCall() * 1000
        logger.notice("\(outcome, privacy: .public): \(self.updates) window updates, slowest AX call \(slowest, format: .fixed(precision: 1)) ms")
    }

    // MARK: Math

    private func rounded(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x.rounded(), y: p.y.rounded())
    }

    private func rounded(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
    }

    private func interpolate(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    private func approach(_ a: CGRect, _ b: CGRect, _ k: CGFloat) -> CGRect {
        interpolate(a, b, k)
    }

    /// The largest difference between the two frames' origins and sizes.
    private func difference(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }
}
