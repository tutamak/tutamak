import CoreGraphics

/// When a window edge reaches a display edge (including below the menu bar, above the Dock,
/// and where two displays meet), absorbs movement for a while: the edge sticks there, gives way
/// after being pushed `strength` further, and lets go at once when pulled back. Pure and tested.
///
/// An edge already resting on a line (say, pulling a snapped window away) meets no resistance;
/// resistance starts only when an edge approaches a line and touches it.
struct EdgeResistance {
    /// How far past the edge the window must be pushed to break through (pt).
    var strength: CGFloat = 50

    private var x = Axis()
    private var y = Axis()

    var isHolding: Bool { x.isHolding || y.isHolding }

    mutating func reset() {
        x = Axis()
        y = Axis()
    }

    /// - Parameters:
    ///   - delta: the requested movement (pt).
    ///   - frame: the window's current frame (CG/AX coordinates).
    ///   - visibleFrames: the displays' visible areas (CG/AX coordinates).
    /// - Returns: the movement to apply.
    mutating func apply(_ delta: CGVector, frame: CGRect, visibleFrames: [CGRect]) -> CGVector {
        // Vertical lines only from displays that overlap the window vertically; horizontal ones likewise.
        let xLines = visibleFrames
            .filter { $0.minY < frame.maxY && $0.maxY > frame.minY }
            .flatMap { [$0.minX, $0.maxX] }
        let yLines = visibleFrames
            .filter { $0.minX < frame.maxX && $0.maxX > frame.minX }
            .flatMap { [$0.minY, $0.maxY] }
        return CGVector(
            dx: x.step(edges: [frame.minX, frame.maxX], delta: delta.dx, lines: xLines, strength: strength),
            dy: y.step(edges: [frame.minY, frame.maxY], delta: delta.dy, lines: yLines, strength: strength)
        )
    }

    /// One axis.
    struct Axis {
        private var direction: CGFloat = 0
        private var absorbed: CGFloat = 0
        private(set) var isHolding = false

        /// An edge this close to a line already counts as on it (floating-point slack).
        private static let onLine: CGFloat = 0.01

        mutating func step(edges: [CGFloat], delta: CGFloat, lines: [CGFloat], strength: CGFloat) -> CGFloat {
            guard delta != 0 else { return 0 }
            if isHolding { return absorb(delta, strength) }

            // The nearest line reached in this step.
            var nearest: CGFloat?
            for edge in edges {
                for line in lines {
                    let gap = line - edge
                    guard abs(gap) > Self.onLine, (gap > 0) == (delta > 0), abs(gap) <= abs(delta) else { continue }
                    if nearest.map({ abs(gap) < abs($0) }) ?? true { nearest = gap }
                }
            }
            guard let gap = nearest else { return delta }

            isHolding = true
            direction = delta > 0 ? 1 : -1
            absorbed = 0
            return gap + absorb(delta - gap, strength)
        }

        private mutating func absorb(_ delta: CGFloat, _ strength: CGFloat) -> CGFloat {
            let total = absorbed + delta * direction
            if total < 0 {
                // Pulled back: leave the line; the excess applies in the opposite direction.
                isHolding = false
                return total * direction
            }
            if total > strength {
                // Broke through: the absorbed part is spent; the excess applies forward.
                isHolding = false
                return (total - strength) * direction
            }
            absorbed = total
            return 0
        }
    }
}
