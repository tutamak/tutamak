import CoreGraphics
import Foundation
import os

/// The setup's practice: what the fingers on the trackpad are doing, for the setup to draw, and
/// which gestures have been performed. While it is on, `GestureController` hands it every frame
/// and every gesture and does nothing else: no window moves, no shortcut is posted.
///
/// Written on the gesture queue and read by the drawing on each display frame. Nothing here is
/// observed, so a touch frame redraws nothing by itself; only a finished gesture reaches the main
/// queue (`onGesture`).
///
/// The touch window (`TouchWindow.swift`) draws its fingers from one too, fed only `touches`.
final class PracticeFeed {
    struct State {
        /// The fingers on the trackpad now, keyed by the id the trackpad gives each, in trackpad
        /// units with y down. The ids let the drawing follow one finger from frame to frame.
        var fingers: [Int32: CGPoint] = [:]
        /// Where four fingers landed, for their trail while they slide.
        var landed: [Int32: CGPoint]?
        /// When a finger last touched (system uptime).
        var lastTouch = -Double.infinity
        /// The practice window, in units of the drawn display: slid by drags, scaled by pinches,
        /// filled by taps.
        var offset = CGVector.zero
        var scale: CGFloat = 1
        var maximized = false
        /// Desktop (0 or 1) and Mission Control (0 or 1), with where they came from and when, so
        /// the drawing can slide between them.
        var desktop: CGFloat = 0
        var desktopFrom: CGFloat = 0
        var overview: CGFloat = 0
        var overviewFrom: CGFloat = 0
        var changedAt = -Double.infinity
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    /// Called on the main queue when a gesture has been performed.
    var onGesture: (GestureDemo) -> Void = { _ in }

    // Used only on the gesture queue.
    private var dragged: CGFloat = 0
    private var scaleAtStart: CGFloat = 1

    var state: State { lock.withLock { $0 } }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// The fingers touching now, by id, in trackpad units with y down.
    func touches(_ points: [Int32: CGPoint]) {
        let now = self.now
        lock.withLock { s in
            s.fingers = points
            if !points.isEmpty { s.lastTouch = now }
            if points.count == 4 {
                if s.landed == nil { s.landed = points }
            } else {
                s.landed = nil
            }
        }
    }

    func handle(_ event: GestureEvent) {
        switch event {
        case .began:
            dragged = 0
        case .moved(let d):
            dragged += hypot(d.dx, d.dy)
            lock.withLock { s in
                s.maximized = false
                // Trackpad y grows upward, the drawing's downward.
                s.offset.dx = min(max(s.offset.dx + d.dx * 1.3, -0.1), 0.46)
                s.offset.dy = min(max(s.offset.dy - d.dy * 1.3, -0.15), 0.3)
            }
        case .ended:
            if dragged > 0.04 { report(.slide) }
        case .resizeBegan:
            scaleAtStart = state.scale
        case .resized(let spread):
            lock.withLock { s in
                s.maximized = false
                s.scale = min(max(scaleAtStart * (1 + spread.radial * 6), 0.55), 1.6)
            }
        case .resizeEnded:
            report(.pinch)
        case .tapped:
            lock.withLock { $0.maximized.toggle() }
            report(.tap)
        case .swiped(let direction):
            let now = self.now
            lock.withLock { s in
                s.desktopFrom = s.desktop
                s.overviewFrom = s.overview
                switch direction {
                case .left: s.desktop = 1
                case .right: s.desktop = 0
                case .up: s.overview = 1
                case .down: s.overview = 0
                }
                s.changedAt = now
            }
            report(direction == .up || direction == .down ? .flickUp : .flick)
        }
    }

    /// Back to the start: the window where it was, the first desktop.
    func reset() {
        lock.withLock { $0 = State() }
    }

    private func report(_ demo: GestureDemo) {
        let onGesture = self.onGesture
        DispatchQueue.main.async { onGesture(demo) }
    }
}

extension SceneFrame {
    /// The practice drawn as it is now: the real fingers, the window as the gestures left it.
    static func live(_ s: PracticeFeed.State, now: Double) -> SceneFrame {
        var f = SceneFrame()
        let ids = s.fingers.keys.sorted()
        f.fingers = ids.map { s.fingers[$0]! }
        f.fingerOpacity = s.fingers.isEmpty ? 0 : 1
        f.trailStarts = s.landed.map { landed in ids.map { landed[$0] ?? s.fingers[$0]! } }
        let base = restingWindow
        let size = CGSize(width: base.width * s.scale, height: base.height * s.scale)
        let centre = CGPoint(x: base.midX + s.offset.dx, y: base.midY + s.offset.dy)
        // Kept on the drawn display: when it grows, it is pushed back from the edges rather than cut off.
        let w = min(size.width, 1), h = min(size.height, 1)
        let x = min(max(centre.x - w / 2, 0), 1 - w), y = min(max(centre.y - h / 2, 0), 1 - h)
        f.window = s.maximized ? CGRect(x: 0, y: 0, width: 1, height: 1) : CGRect(x: x, y: y, width: w, height: h)
        let p = ease(seg(now - s.changedAt, 0, 0.45))
        f.desktop = s.desktopFrom + (s.desktop - s.desktopFrom) * p
        f.overview = s.overviewFrom + (s.overview - s.overviewFrom) * p
        f.pointer = CGPoint(x: 0.4, y: 0.12)
        return f
    }
}

/// Eases the live drawing from one display frame to the next. Trackpad frames do not arrive in
/// step with the display, so drawn as they come, the fingers would move in uneven steps. Here
/// each finger, followed by its id, glides toward where the trackpad last put it (a 30 ms
/// exponential follow). It lands from a slightly larger dot, settling in; it lifts by fading and
/// shrinking at once, smoothly, over a quarter of a second, and its trail fades with it. Nothing
/// grows or flashes as it goes. The window glides the same way, so a pinch grows it smoothly and
/// a tap fills the screen rather than jumping.
///
/// Used only from the drawing's timeline, on the main thread.
final class LiveSmoother {
    private struct Dot {
        var position: CGPoint
        var target: CGPoint
        /// 0 (not there) to 1 (fully down): rises as it lands, falls as it lifts.
        var presence: Double
        var touching: Bool
        /// Where its slide started, kept while it fades so the trail fades rather than vanishes.
        var trailStart: CGPoint?
    }

    /// Seconds for the follow to close about two thirds of the gap.
    static let follow = 0.03
    static let windowFollow = 0.06
    static let landing = 0.12
    static let lifting = 0.25

    private var dots: [Int32: Dot] = [:]
    private var window: CGRect?
    private var last: Double?

    func frame(for s: PracticeFeed.State, now: Double) -> SceneFrame {
        let dt = min(max(now - (last ?? now), 0), 0.05)
        last = now
        var f = SceneFrame.live(s, now: now)

        for (id, p) in s.fingers {
            if dots[id] == nil || dots[id]?.touching == false {
                // A new touch, or a finger landing again where one was still fading.
                let presence = dots[id]?.presence ?? 0
                dots[id] = Dot(position: dots[id]?.position ?? p, target: p, presence: presence, touching: true)
            } else {
                dots[id]?.target = p
            }
            dots[id]?.trailStart = s.landed?[id]
        }
        let follow = 1 - exp(-dt / Self.follow)
        for (id, var dot) in dots {
            if s.fingers[id] == nil { dot.touching = false }
            if dot.touching {
                dot.position.x += (dot.target.x - dot.position.x) * follow
                dot.position.y += (dot.target.y - dot.position.y) * follow
                dot.presence = min(1, dot.presence + dt / Self.landing)
            } else {
                dot.presence = max(0, dot.presence - dt / Self.lifting)
            }
            dots[id] = !dot.touching && dot.presence == 0 ? nil : dot
        }

        let ordered = dots.sorted { $0.key < $1.key }.map(\.value)
        f.fingers = ordered.map(\.position)
        f.fingerOpacities = ordered.map { dot in
            // Landing: out of the gate at once, easing into place. Lifting: a smoothstep, so the
            // fade starts gently and ends gently, with no pop at either end.
            let p = dot.presence
            return dot.touching ? 1 - pow(1 - p, 3) : p * p * (3 - 2 * p)
        }
        f.fingerScales = ordered.map { dot in
            let p = dot.presence
            return dot.touching ? 1 + 0.3 * (1 - p) : 0.55 + 0.45 * (p * p * (3 - 2 * p))
        }
        f.fingerOpacity = f.fingerOpacities?.max() ?? 0
        f.trailStarts = ordered.contains { $0.trailStart != nil } ? ordered.map { $0.trailStart ?? $0.position } : nil

        let target = f.window
        let k = 1 - exp(-dt / Self.windowFollow)
        let current = window ?? target
        window = SceneFrame.mix(current, target, k)
        f.window = window!
        return f
    }
}
