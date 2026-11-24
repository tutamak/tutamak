import CoreGraphics
import Foundation

/// A One Euro filter (Casiez, Roussel, Vogel, CHI 2012) for the natural jitter of fingers and sensor.
/// It smooths heavily when slow, so jitter disappears, and lightly when fast, so no lag is felt.
/// Both axes share one cutoff (driven by speed) so a diagonal move does not lag differently per axis.
/// Pure and tested.
struct PointerSmoother {
    /// Cutoff frequency at rest (Hz). Lower means less jitter but more lag on slow moves.
    var minCutoff: Double = 1.5
    /// How much the cutoff opens up with speed (Hz per pt/s). Higher means less lag when fast.
    var beta: Double = 0.02
    /// Cutoff frequency of the speed estimate (Hz).
    var derivativeCutoff: Double = 1.0

    private var value: CGPoint?
    private var velocity = CGVector.zero
    private var lastTime: Double?

    mutating func reset() {
        value = nil
        velocity = .zero
        lastTime = nil
    }

    /// `point` is the raw position (pt), `time` is in seconds. Returns the smoothed position.
    mutating func filter(_ point: CGPoint, at time: Double) -> CGPoint {
        guard let previous = value, let last = lastTime else {
            value = point
            lastTime = time
            return point
        }
        var dt = time - last
        if !(dt > 0) || dt > 0.5 { dt = 1.0 / 120 }
        lastTime = time

        let rawVelocity = CGVector(dx: (point.x - previous.x) / dt, dy: (point.y - previous.y) / dt)
        let ad = Self.alpha(cutoff: derivativeCutoff, dt: dt)
        velocity.dx += ad * (rawVelocity.dx - velocity.dx)
        velocity.dy += ad * (rawVelocity.dy - velocity.dy)

        let cutoff = minCutoff + beta * Double(hypot(velocity.dx, velocity.dy))
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let next = CGPoint(x: previous.x + a * (point.x - previous.x), y: previous.y + a * (point.y - previous.y))
        value = next
        return next
    }

    private static func alpha(cutoff: Double, dt: Double) -> CGFloat {
        let tau = 1 / (2 * Double.pi * cutoff)
        return CGFloat(1 / (1 + tau / dt))
    }
}

/// Window positions are rounded to whole points; a value hovering between two points would move
/// the window one pixel every frame. This band yields a new position only once it has moved
/// at least `width` from the last applied one. Pure and tested.
struct DeadBand {
    var width: CGFloat = 1
    private var last: CGPoint?

    mutating func reset() { last = nil }

    /// The new (rounded) position to apply, or nil if it does not need to change.
    mutating func update(_ point: CGPoint) -> CGPoint? {
        if let last, abs(point.x - last.x) < width, abs(point.y - last.y) < width { return nil }
        let rounded = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        last = rounded
        return rounded
    }

    /// The follower has come to rest at `target`: put the window there if it rounds elsewhere.
    ///
    /// An exponential follow never quite closes its gap, so one that ends less than `width` from
    /// the last applied point leaves the window a point short of its target until release, when
    /// it jumps. That was seen at a display edge: the window was held a point inside the edge, then
    /// jumped onto it on release. A target at least three quarters of `width` away is applied;
    /// nearer ones are not, so fingers resting on a half point do not flip between two points.
    mutating func settle(_ target: CGPoint) -> CGPoint? {
        let rounded = CGPoint(x: target.x.rounded(), y: target.y.rounded())
        guard let last, rounded != last else { return nil }
        guard abs(target.x - last.x) >= 0.75 * width || abs(target.y - last.y) >= 0.75 * width else { return nil }
        self.last = rounded
        return rounded
    }
}
